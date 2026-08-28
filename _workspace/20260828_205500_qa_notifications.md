# QA :: 알림 시스템(PRD §5.10 NT-01~08) 경계 정합성 종합 검증

- 일시: 2026-08-28
- 대상: 마이그레이션 44~48, `supabase/functions/push-dispatch/index.ts`,
  `lib/models/{app_notification,notification_settings,push_device_token}.dart`,
  `lib/core/notifications/*`, `lib/core/repositories/notification_repository.dart`,
  `lib/features/notifications/**`
- 정본: `docs/PRD.md` §5.10, `docs/TRD.md` §3.10·§4.1-N·§6-N, `docs/ARCHITECTURE.md` §5.6·§7.4.1
- 검증자: qa-integration-tester

## 0. 요약

| 항목 | 결과 |
|---|---|
| `flutter analyze lib` | ✅ No issues found |
| `flutter test` | ✅ All tests passed (196) |
| 마이그레이션 44~48 적용 | ✅ 5건 전부 원격 적용 확인 |
| 트리거 존재 | ✅ `runs_04_notifications` · `tier_change_history_02_notify` · `profiles_02_level_notify` · `notifications_guard` |
| RLS | ✅ 9개 정책 스펙대로 |

**CONFIRMED 3건 / SUSPECTED 3건 / 문서 정합 2건.**
CONFIRMED 3건은 전부 **푸시가 실제로 나가기 시작하는 순간** 드러나는 결함이라
FCM 연결 전에 반드시 고쳐야 한다. 알림함(인앱) 경로만 놓고 보면 정합하다.

---

## 1. CONFIRMED

### C-1 (치명) `claim_push_batch` / `mark_push_result` 의 쓰기를 `notifications_guard` 가 되돌린다

- 책임 레이어: **backend**
- 위치: `supabase/migrations/20260828190300_47_push_dispatch.sql:64,71,77,84,118`
  ↔ `supabase/migrations/20260828190000_44_notifications_core.sql:165-181`

44-5 가드는 UPDATE 시 `is_server_write()` 가 아니면 `sent_at` / `send_error` /
`send_attempts` 를 **전부 old 값으로 되돌린다.** 그런데 47번의 네 UPDATE 와
`mark_push_result` 는 `set_config('runnit.server_write','on',true)` 를 하지 않는다.
`is_server_write()` 는 세션 GUC만 보므로 SECURITY DEFINER·service_role 여부와 무관하다.

**재현 (원격 DB에서 실제 실행, 결과 확인 후 행 삭제):**

```sql
-- server_write 미설정 상태의 UPDATE
update public.notifications set sent_at = now(), send_error='qa',
       send_attempts = send_attempts + 1 where id = v_id;
-- 결과 → sent_at = null, send_attempts = 0, send_error = null   ← 전부 되돌아감
-- 같은 UPDATE 를 server_write='on' 으로 감싸면
-- 결과 → sent_at = 2026-08-28 08:49:09+00, send_attempts = 1, send_error = 'qa'
```

**영향**
1. `sent_at` 이 영원히 null → `notifications_pending_idx` 대기열에서 절대 빠지지 않는다.
   `dispatch_pending_pushes` 는 **매분** 같은 행을 다시 claim 하고, Edge Function 이
   FCM 에 다시 보낸다 → **사용자에게 같은 푸시가 1분마다 무한 반복.**
   dedupe_key 는 알림함 insert 만 막지 발송은 막지 못한다.
2. `send_attempts` 가 늘지 않아 `send_attempts >= 3` 만료 경로가 죽는다.
3. `push_enabled=false` / `no_token` / `expired` 큐 배출 UPDATE 3건도 같은 이유로 무효 →
   **마스터 스위치를 끈 사용자에게도 푸시가 나간다**(NT-08 위반).

**수정 방향**: `claim_push_batch` 본문 진입 직후 / `mark_push_result` 에
`perform set_config('runnit.server_write','on',true)` 를 두고 반환 직전에 되돌린다.
`mark_push_result` 는 `language sql` 이라 `set_config` 를 넣으려면 plpgsql 로 바꾸거나,
가드 함수가 `sent_at`/`send_error`/`send_attempts` 되돌림을 하지 않도록
"클라이언트는 애초에 이 컬럼에 도달할 수 없다"는 근거로 완화한다. **전자를 권장** —
가드는 두 겹 방어선이라는 44번의 설계 의도를 유지해야 한다.

---

### C-2 (높음) FCM data payload 에 `type` 이 없어 포그라운드 성취 중복 억제가 동작하지 않는다

- 책임 레이어: **backend(Edge Function) + mobile**
- 위치: `supabase/functions/push-dispatch/index.ts:142-146`
  ↔ `lib/core/notifications/push_messaging.dart:110,114`
  ↔ `supabase/migrations/20260828190300_47_push_dispatch.sql:48-56`

클라이언트는 `notificationTypeFromWire(message.data['type'])` 로 종류를 판정해
`isAchievement` 면 인앱 배너를 생략한다. 그런데
- `claim_push_batch` 의 `returns table (...)` 에 **`type` 컬럼이 없고**,
- `enqueue_notification` 은 payload 에 `route` 만 주입할 뿐 `type` 을 넣지 않으며,
- Edge Function 의 `data` 는 `notification_id` + `row.payload` 전개가 전부다.

따라서 `message.data['type']` 은 **항상 undefined** → `type = null` →
`type?.isAchievement ?? false` 가 false →

**영향**
1. NT-01 티어 승급·NT-06 뱃지/레벨 푸시가 포그라운드에서 **인앱 배너로도 뜨고**,
   몇 초 뒤 `AchievementCelebrationHost` 가 풀페이지 축하를 또 띄운다.
   ARCHITECTURE §7.4.1 "소비 지점은 하나"가 깨진다 — 검증 항목 8번 **fail**.
2. 딥링크 폴백이 전부 `_fallbackFor(null)` → `Routes.notifications` 로 떨어진다.
   route 화이트리스트를 통과 못 한 알림(C-3)은 종류별 목적지가 아니라 **알림함**으로 간다.

**수정 방향**: `claim_push_batch` 의 반환 테이블에 `type public.notification_type` 을
추가하고(→ `select c.id, c.user_id, c.type, ...`), Edge Function 이
`data.type = row.type` 을 명시적으로 넣는다. `payload` 에 `type` 을 섞는 방식은
"payload 는 서버 표시값"이라는 규약과 섞이므로 권장하지 않는다.

---

### C-3 (높음) 서버가 발행하는 `payload.route` 4종이 실제 라우터에 없다 — 1종은 화이트리스트를 통과해 라우팅 예외

- 책임 레이어: **backend(문구·route 소유) + mobile(화이트리스트)**
- 위치: 45/46/48 의 `enqueue_notification(..., p_route, ...)` 인자
  ↔ `lib/core/router/app_router.dart:27-39`
  ↔ `lib/core/notifications/notification_deep_link.dart:25-49`

실제 라우트는 `/home`, `/tracking`, `/history`, `/history/run/:runId`, `/profile`,
`/notifications`, `/notifications/settings` 뿐이다.

| 발행처 | route | 화이트리스트 | 실제 결과 |
|---|---|---|---|
| 45-3 NT-01 (`45:116`) | `/home` | 통과 | ✅ |
| 45-5 NT-02 (`45:250`) | `/home` | 통과 | ✅ |
| 46-1 NT-03 A/B (`46:122,130`) | `/home`, `/profile` | 통과 | ✅ |
| 46-1 NT-03 C (`46:138`) | `/ranking` | **거부** | 폴백(홈 의도였으나 C-2 로 알림함) |
| 46-2 NT-04 (`46:329`) | `/ranking` | **거부** | 폴백 |
| 46-3·48 NT-05 (`46:460,486,536`) | `/ranking` | **거부** | 폴백 |
| 45-5 NT-06 러닝 유래 (`45:326`) | `/runs/{run_id}` | **거부** | 폴백 → 러닝 상세로 못 간다 |
| 48-1 NT-06 레벨 단독 (`48:46`) | `/profile/badges` | **통과** ⚠️ | **go_router 에 없는 경로 → 예외/에러 화면** |

가장 나쁜 것이 마지막 줄이다. `_isAllowed` 는 `route.startsWith('$prefix/')` 로 판정하므로
`/profile/badges` 가 `/profile/` 접두에 걸려 **통과**한다. 그 뒤 `context.go('/profile/badges')`
는 매칭 라우트가 없어 `GoException: no routes for location` 으로 떨어진다 —
화이트리스트가 막으려던 바로 그 실패다. 도달 경로는 **러닝 없는 레벨업**
(XP-3 뱃지 verified/revoked 변경, XP-4 `tier_change_history` INSERT — 48번 헤더가
스스로 열거한 경로)이라 실재한다.

**수정 방향 (backend 쪽 1줄씩)**
- `/ranking` → `/home` (티어 카드 + 주간 랭킹이 홈에 있다. 2026-08-21 4탭 개편)
- `/runs/{id}` → `/history/run/{id}`
- `/profile/badges` → `/history` (뱃지 탭. `_fallbackFor(badgeLevel)` 와 같은 목적지)

**mobile 쪽 보강(권장)**: `_isAllowed` 를 접두 매칭이 아니라
`appRouter.configuration.findMatch(route)` 성공 여부로 판정한다. 접두 매칭은
"라우터에 없는 경로를 걸러낸다"는 이 클래스의 목적을 구조적으로 달성하지 못한다.

---

## 2. SUSPECTED

### S-1 `enqueue_notification` 이 `server_write` 를 **무조건 'off'** 로 되돌린다

`44:556`. 호출 시점에 바깥이 이미 `'on'` 이었다면 그 영역을 조기 종료시킨다.
현재 3개 호출 지점(`45-3`/`45-4`/`45-5`)은 모두 바깥 함수가 `'off'` 상태이거나
직후에 스스로 `'off'` 를 세팅하므로 **지금은 사고가 나지 않는다.** 다만 이 파일의
관례상 향후 서버 쓰기 영역 안에서 알림을 발행하면 조용히 깨진다.
→ 진입 시 `current_setting` 을 저장해 복원하는 형태를 권장(재현 사례 없음, 예방).

### S-2 `NotificationSettings.columnOf(points)` 가 존재하지 않는 컬럼명을 돌려준다

`lib/models/notification_settings.dart:118`. `'points'` 컬럼은 44번이 의도적으로
만들지 않았으므로 `_upsertColumn` 이 호출되면 PostgREST 42703 에러다.
설정 화면은 `configurableTypes`(= `isMvp`) 만 순회하므로 **현재 도달 경로가 없다.**
→ `columnOf(points)` 에서 `ArgumentError` 를 던지거나 `null` 반환으로 바꿔
"조용히 잘못된 컬럼을 보내는" 경로를 없애는 편이 안전하다.

### S-3 `runnit-rank-notify` 의 UTC 13시 슬롯은 항상 no-op

`46:574` 의 `'0 23,0-13 * * *'` 중 UTC 13:00 = KST 22:00 인데
`_batch_hours_ok` 는 `between 8 and 21` 이라 즉시 0 을 반환한다.
알림은 안 나가지만 `refresh_leaderboards_and_notify` 가 리더보드 전체 갱신은 수행한다
(5분 주기 `runnit-leaderboard` 와 중복이라 무해). 의도가 "08~22시"라면
게이트를 `between 8 and 22` 로, "08~21시"라면 cron 을 `0 23,0-12 * * *` 로 맞춘다.

---

## 3. PASS (경계별)

### 3.1 모델 ↔ 마이그레이션 44 컬럼 — ✅ pass
원격 `information_schema.columns` 실조회 대조. `@JsonSerializable(fieldRename: snake)`
가 3개 모델 전부에 붙어 있어 camelCase↔snake_case 자동 변환이 성립한다.
nullable 도 일치: `read_at`/`device_id`/`app_version`/`updated_at` 만 nullable,
`payload` 는 not null default `'{}'` ↔ Dart `@Default({})`.
`notifications.dedupe_key`/`sent_at`/`send_error`/`send_attempts` 와
`notification_settings.created_at` 은 Dart 필드가 없지만 json_serializable 이
미지 키를 무시하므로 무해하다(TRD §4.1-N 의 "대응 필드 없음"과 일치).

### 3.2 enum 3계층 — ✅ pass
Postgres `notification_type` 7라벨(`tier_promotion`/`tier_proximity`/`season_ending`/
`rank_change`/`weekend_push`/`badge_level`/`points`)과 `device_platform` 2라벨을
원격에서 조회해 `lib/models/enums.dart` 의 `@JsonValue` ·
`lib/core/api/wire_enums.dart` 의 `.wire` 와 **글자 단위로 대조 — 전부 일치.**
`notificationTypeFromWire` 는 미지 라벨에 null 을 돌려주므로 구버전 앱 방어도 성립한다.

### 3.3 RPC 계약 — ✅ pass
- `mark_notifications_read(p_ids uuid[] default null)` ↔ 클라이언트
  `params: {'p_ids': ids}` / `{'p_ids': null}` (`supabase_notification_repository.dart:78,90`). 일치.
- `register_push_token(p_token, p_platform, p_device_id, p_app_version)` ↔
  클라이언트 4개 인자명·순서 일치(`:156-163`). `p_platform` 은 `platform.wire` 문자열로
  보내고 Postgres 가 `device_platform` 으로 캐스팅한다.
- `notification_settings` 부분 upsert는 RPC 가 아니라 PostgREST upsert
  (`onConflict: 'user_id'`). PostgREST 는 payload 에 실린 컬럼만
  `ON CONFLICT DO UPDATE SET` 에 넣으므로 lost update 방지 의도대로 동작한다.
  insert/update RLS 정책이 둘 다 있어 행 부재/존재 양쪽 경로가 열려 있다.

### 3.4 RLS — ✅ pass
원격 `pg_policies` 9행 확인. `notifications` 는 select/update 만(insert·delete 정책 없음),
`push_tokens` 는 4종 전권, `notification_settings` 는 select/insert/update.
클라이언트 코드가 시도하는 쓰기는 ①`read_at`(RPC 경유) ②설정 upsert ③토큰 등록(RPC)
④`push_tokens` 본인 행 delete 뿐이며, **RLS 가 막는 쓰기를 시도하는 코드는 없다.**
리포지토리에 알림 행 생성 메서드가 아예 없는 것도 확인(`notification_repository.dart`).

### 3.5 트리거 체이닝 — ✅ pass (48-1 수정 반영 확인)
- 순서: `runs_01_recompute_stats` → `02_challenge_progress` → `03_evaluate_badges`
  → `04_notifications`. 원격 `pg_trigger` 조회로 4개 다 존재·활성 확인.
- **backend 가 잡은 결함 재확인**: 45번 `trg_level_up_notify` 가 `profiles` 트리거에서
  `new.user_id` 를 참조한 건(`profiles` PK 는 `id`) — 48-1 에서 `new.id` 로 수정됐고,
  **원격 `pg_proc.prosrc` 조회로 `new.user_id` 부재 / `new.id,` 존재를 확인했다.**
  수정 전이었다면 러닝 없는 레벨업 경로가 `record "new" has no field "user_id"` 로
  터져 러닝 삭제·뱃지 변경 트랜잭션 전체를 롤백시켰을 것이다.
- 러닝 플래그(`is_flagged=true` UPDATE) 시: `runs_04` 가 다시 돌지만
  NT-02 는 `coalesce(new.is_flagged,false)=false` 조건에 막히고(`45:232`),
  NT-06 은 `badge_level:run:{id}` dedupe 키가 막는다. **중복 발행 없음.**
- 러닝 DELETE: `runs_04` 는 `after insert or update` 라 발화하지 않고,
  `runs_01` 의 DELETE 분기는 `notify_run_id` 를 심지 않는다. XP 하락은 레벨을
  올리지 않으므로 `trg_level_up_notify` 도 조기 반환한다. **트랜잭션 안 깨진다.**
- 세션 변수 정리: `runs_04` 말미에 `notify_level`/`notify_run_id` 를 비운다(`45:342-343`)
  — 한 트랜잭션 다건 업로드 시 누수 없음.

### 3.6 배치 ↔ 규칙 — ✅ pass (S-3 제외)
원격 `cron.job` 9건 확인.

| 잡 | 스케줄(UTC) | KST | gamification 문서 조건 |
|---|---|---|---|
| `runnit-notify-season-ending` | `0 0 * * *` | 매일 09:00 | ✅ |
| `runnit-rank-notify` | `0 23,0-13 * * *` | 매시 08~22 | ⚠️ S-3 |
| `runnit-weekend-push-sat` | `0 1 * * 6` | 토 10:00 | ✅ |
| `runnit-weekend-push-sun` | `0 9 * * 0` | 일 18:00 | ✅ |
| `runnit-push-dispatch` | `* * * * *` | 매분 | ✅ |

- **NT-04 체이닝 확인**: cron 이 부르는 것은 `notify_rank_changes()` 가 아니라
  `refresh_leaderboards_and_notify()` 이고, 그 함수가
  `refresh_all_leaderboards(p_at)` → `notify_rank_changes(p_at)` 를 **같은 트랜잭션·같은
  `p_at`** 으로 연달아 호출한다(`46:367-377`). 별도 주기가 아니다 — **검증 항목 6 pass.**
  기존 5분 주기 `runnit-leaderboard` 는 화면 신선도용으로 남아 있고 멱등이라 무해.
- dedupe_key 규약: `tier_promotion:{season}:{tier}` / `tier_proximity:{season}:{tier}` /
  `season_ending:{season}:d{14|3}` / `rank_change:{week}:{dir}:{n}` /
  `weekend_push:{week}:{sat|sun}` / `badge_level:run:{run_id}` / `badge_level:level:{lv}`.
  44번 주석·gamification 문서와 일치. NT-04 만 순번 `n` 으로 상한을 unique 제약에
  위임하는 구조이며 `v_n`/`v_total` 카운트와 키 생성이 정합하다.
- 발송 상한: down 3 / up 2 / 주 합계 4(`46:285,287`), NT-05 주 2건(슬롯 키),
  NT-03 시즌 2건 — 문서 조건표와 일치.
- 48-2 수정 확인: NT-05 변형 B 의 `participant_count = 0` → "상위 100%" 문구 사고를
  `v_pc >= 5` 게이트로 차단(`48:154-162`). 원격 함수 본문도 48 버전.

### 3.7 알림함 필터 함정 — ✅ pass
`notification_providers.dart:17-21` 이 "알림함을 `isEnabled` 로 거르지 않는다"를
명시적으로 문서화했고, `notification_inbox_page.dart` 어디에서도
`NotificationSettings` 를 읽지 않는다. 목록은 서버가 준 행을 그대로 그린다.
설정 화면만 `rawFlag`(마스터 무시)로 그려 마스터를 껐다 켤 때 개별 토글이 복원된다
(`notification_settings_page.dart:155`). **backend 가 경고한 함정에 빠지지 않았다.**

### 3.8 큐 공존 — ⚠️ 설계는 pass, 런타임은 **fail (C-2)**
설계 자체는 정합하다: `NotificationTypeX.isAchievement` 가 NT-01·NT-06 만 true 이고
`_onForeground` 가 그 종류의 배너를 생략하며, `NotificationDeepLink` 는
`user_badge_id` 가 있어도 축하를 띄우지 않고 이동만 한다.
45번도 레벨업 합성 `user_badges` 행을 만들지 않아 XP 순환을 피했다.
**그러나 `data.type` 이 실제로 도착하지 않아 이 분기가 죽어 있다(C-2).**

### 3.9 문서 정합 — 대체로 pass
- ARCHITECTURE §5.6 / §5 표(트리거 4종) / TRD §3.10 · §4.1-N · §6-N 은 실제 구현과 일치.
- TRD §2 푸시 행이 `firebase_core`/`firebase_messaging` + 마이그레이션 44~48 로
  갱신됐고 `pubspec.yaml:89-90` 과 일치.
- **D-1** `docs/TRD.md` §4.1-N `dedupe_key` 예시가 `rank_change:2026-W35:down` 인데
  실제는 순번이 붙은 `rank_change:2026-W35:down:2` 다(44:139 주석은 정확).
  → TRD 예시에 순번을 추가할 것.
- **D-2** ARCHITECTURE/TRD 어디에도 **종류별 `payload.route` 목적지 표가 없다.**
  C-3 같은 결함이 문서 검토로 잡히지 않은 원인이다. §6-N 에 "종류 → route →
  실제 go_router 경로" 3열 표를 추가하고, 라우트 개편 시 같이 고치도록 못 박을 것.
- **NT-05 문구(이미 인지된 건)**: PRD §5.10 NT-05 의 `"10위까지 2.1km"` 예시를
  구현은 "앞사람까지 N km · 상위 N%"(RK-04 격차 우선)로 바꿨다. 46번 헤더에 근거가
  기록돼 있고 PRD §5.4.1 확정 트레이드오프와 정합하나, **PRD 본문 예시는 아직 그대로다.**
  → PRD §5.10 NT-05 행 문구를 갱신하거나 각주를 다는 편이 낫다(사용자 확인 필요).

---

## 4. 미해결 목록 (우선순위)

| # | 심각도 | 책임 | 내용 |
|---|---|---|---|
| C-1 | 치명 | backend | `claim_push_batch`·`mark_push_result` 에 `server_write` 미설정 → 발송 상태가 저장되지 않아 푸시 무한 재발송 + 마스터 스위치 무력화 |
| C-2 | 높음 | backend + mobile | FCM data 에 `type` 미포함 → 성취 푸시 포그라운드 이중 축하, 딥링크 폴백 오작동 |
| C-3 | 높음 | backend (+ mobile 보강) | `/ranking`·`/runs/{id}`·`/profile/badges` 가 실제 라우터에 없음. `/profile/badges` 는 화이트리스트를 통과해 라우팅 예외 |
| S-1 | 중 | backend | `enqueue_notification` 의 무조건 `server_write='off'` 복원 없음(예방) |
| S-2 | 낮 | mobile | `columnOf(points)` 가 미존재 컬럼명 반환(현재 도달 불가) |
| S-3 | 낮 | backend | `runnit-rank-notify` UTC 13시 슬롯이 시간대 게이트에 막혀 항상 no-op |
| D-1 | 낮 | backend | TRD §4.1-N dedupe_key 예시에 NT-04 순번 누락 |
| D-2 | 중 | backend | 문서에 종류별 route 목적지 표 부재 — C-3 재발 방지 필요 |
| PRD | — | 리더 확인 | PRD §5.10 NT-05 예시 문구("10위까지")와 구현(격차 우선) 불일치 — 구현 쪽이 §5.4.1 정합 |
