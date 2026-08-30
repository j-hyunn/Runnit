# 알림 시스템(NT-01~08) 백엔드 구현

> **2026-08-28 후속**: QA 통합 검증(`_workspace/20260828_205500_qa_notifications.md`)의
> CONFIRMED 3건을 마이그레이션 **49 · 50**으로 수정했다. §7 참조. 아래 본문은 44~48
> 시점의 기록이며, route 값과 발송 워커 서술은 §7이 갱신본이다.

- 작성: backend-engineer / 2026-08-28
- 정본 입력: `_workspace/20260828_164428_architect_notifications.md`(데이터 모델·계약),
  `_workspace/20260828_181500_gamification_notification-rules.md`(판정 규칙),
  PRD §5.10·§5.3·§5.4·§8.2·§8.5, ARCHITECTURE §5·§7.3·§7.4, TRD §3.10·§4.1-N
- 적용 마이그레이션: **44 · 45 · 46 · 47 · 48** + QA 후속 **49 · 50**
  (전부 라이브 반영 완료, 비파괴)
- 갱신 문서: `docs/TRD.md` §2 · **§6-N 신설**(§6-N.7 route 정본표 포함) ·
  §4.1-N · §14(#12 보강, #23·#24 신설),
  `docs/ARCHITECTURE.md` §5.1 · §5.5 · **§5.6 신설** · §12-#6 · §13
  (§5.6.1 딥링크 목적지 표는 flutter-ui-designer가 추가)
- 신규 소스: `supabase/functions/push-dispatch/index.ts` (**미배포**)

---

## 0. 한 문단 요약

알림 조건 판정·문구 작성·발송 상한을 **전부 Postgres에** 넣었다. 티어·성취
계열(NT-01/02/06)은 트리거로 러닝 저장과 같은 트랜잭션에서, 랭킹·시즌
계열(NT-03/04/05)은 pg_cron 배치로 발화한다. 상한은 count 쿼리가 아니라
`unique (user_id, dedupe_key)` 제약이 강제한다. FCM 호출만은 Postgres가 RS256 서명을
할 수 없어 **Edge Function 하나를 원칙의 명시적 예외로** 도입했고, 그 함수에는 제품
판정을 넣지 않았다.

---

## 1. 적용 마이그레이션

| # | 파일 | 내용 |
|---|---|---|
| 44 | `20260828190000_44_notifications_core.sql` | enum 2종(`notification_type`·`device_platform`), 테이블 3종(`notifications`·`notification_settings`·`push_tokens`), 인덱스·RLS·가드 트리거, realtime publication 등록, `leaderboard_entries.notified_rank`/`notified_at`, 판정 헬퍼 9종, **`enqueue_notification()`(발행 단일 진입점)**, 클라이언트 RPC 2종 |
| 45 | `..._45_notifications_triggers.sql` | NT-01(`tier_change_history_02_notify`), NT-02·NT-06 묶음(`runs_04_notifications`), 레벨업(`profiles_02_level_notify`), `trg_runs_recompute_stats` 확장(트랜잭션 컨텍스트 심기) |
| 46 | `..._46_notifications_batches.sql` | NT-03 `notify_season_ending()`, NT-04 `notify_rank_changes()` + `refresh_leaderboards_and_notify()`, NT-05 `notify_weekend_push()`, pg_cron 4잡 |
| 47 | `..._47_push_dispatch.sql` | `pg_net`, `claim_push_batch()`·`mark_push_result()`·`prune_push_token()`, `dispatch_pending_pushes()`(Vault 경유), cron 매분 |
| 48 | `..._48_notifications_fixes.sql` | 스모크 테스트로 잡은 결함 2건 수정(§5) |
| **49** | `..._49_push_dispatch_guard_and_type.sql` | QA C-1(발송 워커 `server_write` 누락) · C-2(FCM `data.type` 누락) · S-1(`server_write` 복원식) · S-3(cron 무의미 슬롯). §7.1·§7.2 |
| **50** | `..._50_notification_routes.sql` | QA C-3 route 3종 정정 + 기존 행 백필. §7.3 |

전부 **신규 테이블·컬럼·함수 추가**이며 기존 스키마를 재생성하지 않았다. 기존 함수 중
`create or replace`로 확장한 것은 `trg_runs_recompute_stats` 하나이고, 마이그레이션 22의
본문에 `set_config` 한 줄을 더한 것이 전부다.

---

## 2. 설계에서 바꾼 것 — 인계 문서와 다르게 간 지점

### 2.1 NT-01의 발화점을 `user_badges`(stier_*)가 아니라 `tier_change_history`로 옮겼다

architect §0 표는 NT-01을 "`user_badges`(`stier_*`) INSERT와 같은 트랜잭션"으로 적었다.
채택하지 않았다.

`tier_change_history`는 마이그레이션 34 이후 **티어 상승만** 기록한다. 시즌 하드
리셋(전원 브론즈)도, 부정 기록 무효화도 행을 만들지 않으므로 **INSERT 되는 것이 곧
승급**이다. 반면 `stier_*` 뱃지는 `evaluate_badges`의 일반 경로에 얹혀 있어 발급 시점이
승급 시점과 항상 같다는 보장이 없고(수렴 루프 3패스), 시즌 인스턴스가 없으면 아예
발급되지 않는다. `profiles.current_tier` 감시안도 버렸다 — 시즌 경계 리셋을 승급과
구분하는 분기가 필요하고, **그 분기가 틀리면 분기 첫날 전 사용자에게 "브론즈 승급!"이
나간다.**

### 2.2 레벨업 알림에 트랜잭션 컨텍스트를 도입했다

gamification §5.1이 "레벨업은 별도 경로"로 확정했고, §5.2가 "한 러닝 = 성취 푸시 최대
1건"을 요구한다. 이 둘을 동시에 만족시키려면 **레벨 상승이 러닝 유래인지** 알아야 한다.
레벨 상승은 `profiles` UPDATE로만 관측되고 러닝 정보를 갖고 있지 않다.

해결: `runs_01`이 `runnit.notify_run_id`를, 레벨 트리거가 `runnit.notify_level`을
트랜잭션 로컬 설정에 남기고 `runs_04`가 둘을 읽어 **한 건으로 합친다.** 러닝이 없는
레벨 상승(뱃지 `verified` 변경, `tier_change_history` INSERT로도 XP가 오른다 — TRD
§3.8.4)은 레벨 트리거가 직접 `badge_level:level:{level}` 키로 보낸다.

별도 테이블을 쓰지 않은 이유: 이 상태의 수명은 트랜잭션 하나이고, 테이블로 만들면
롤백된 트랜잭션의 잔재를 청소하는 배치가 또 필요해진다.

### 2.3 NT-04를 "매시 정각 별도 패스"가 아니라 **랭킹 갱신과 같은 함수** 안에 넣었다

architect는 "`refresh_all_leaderboards` 직후 체이닝(별도 주기 금지)", gamification은
"매시 정각"이라고 했다. 둘 다 만족시키는 형태가 하나 있다 —
`refresh_leaderboards_and_notify()`가 갱신과 평가를 **한 트랜잭션에서 순서대로** 하고,
그 함수를 매시 스케줄한다. 기존 5분 주기 `runnit-leaderboard`(화면 신선도용)는 그대로
둔다. 5분마다 평가하면 상한 4건을 하루 이른 시각에 다 소진한다는 gamification의 지적이
그대로 유효하다.

### 2.4 NT-05 변형 B의 "예상 상위 %" 산식을 바꿨다

gamification §4.4의 `count(*) filter (where score < 5000) / participant_count`는
**의미가 뒤집혀 있다.** 그 값이 0.8이면 "80%를 이긴다"인데 문구는 "상위 80%"가 되어
좋은 결과를 나쁘게 읽힌다. RK-04와 같은 산식
`top_pct(rank_if_5km, participant_count + 1)`을 썼다 — 랭킹 화면과 알림의 표기가 다르면
사용자는 둘 중 어느 쪽이 진짜인지 판단할 근거를 잃는다.

여기에 48번이 게이트를 하나 더 걸었다: **모집단 5명 미만이면 백분율을 쓰지 않는다.**
`participant_count = 0`(그 주 그 티어에서 아무도 안 뛴 경우)이면 어떤 산식을 써도
"상위 100%"가 나오고, 격려하려던 문구가 꼴찌 통보가 된다.

### 2.5 마스터 스위치(`push_enabled`)와 종류별 토글의 효과를 다르게 뒀다

| 설정 | 알림함 행 | 푸시 |
|---|---|---|
| 종류별 토글 off | **만들지 않음** | — |
| `push_enabled` off | 만듦 | 보내지 않음(`send_error='push_disabled'`) |

근거: 종류별 토글을 끄는 것은 "이 일에 대해 알려주지 마"이고, 마스터를 끄는 것은
"푸시로는 받지 않겠다"이다. 후자에서 알림함까지 비우면 architect §1.2가 인박스를 만든
이유("놓친 알림을 여기서 본다")가 사라진다. 그래서 `notification_enabled()`는
`push_enabled`를 보지 않고, 47번 디스패처가 본다.

---

## 3. FCM 발송 경로 — 결정과 근거

### 3.1 (a) pg_net 직접 호출은 **구현 불가**다

FCM HTTP v1은 서비스 계정 JWT를 **RS256**으로 서명해 OAuth2 액세스 토큰으로 교환해야
한다. Postgres에는 RSA 서명 수단이 없다 — `pgjwt`는 HMAC(HS256/384/512)만 지원하고,
`pgcrypto`는 PGP/digest를 노출할 뿐 raw RSA sign이 없다. 토큰은 1시간마다 만료되므로
"미리 발급해 Vault에 넣어둔다"도 성립하지 않는다. 단순
`Authorization: key=<server key>`로 끝나던 레거시 FCM API는 2024-06에 폐지됐다.

부차적으로, `pg_net`은 fire-and-forget이라 토큰별 응답을 읽어
`UNREGISTERED`/`INVALID_ARGUMENT` 행을 지우려면 `net._http_response`를 폴링하는 워커를
결국 따로 만들어야 한다 — **원칙을 지키려다 더 복잡해진다.**

### 3.2 (b) Edge Function 1개 — 채택

`supabase/functions/push-dispatch/index.ts`. Deno WebCrypto의
RSASSA-PKCS1-v1_5로 JWT를 서명하고 액세스 토큰을 55분 캐시한다. 응답이 동기라 무효 토큰
정리와 재시도 판정을 한 자리에서 한다.

**예외의 범위를 좁게 고정했다.** 이 함수에는 제품 판정이 없다 — 누구에게 무엇을 언제
보낼지는 44~46의 SQL이 이미 `notifications` 행으로 확정한 뒤다. 함수가 하는 일은 셋뿐:

```
claim_push_batch(limit)  →  FCM v1 messages:send  →  mark_push_result() / prune_push_token()
```

큐 상태 전이(마스터 스위치·토큰 없음·만료·재시도)는 전부 `claim_push_batch()` 안,
즉 SQL에 있다. **새 알림 종류는 반드시 SQL 쪽에 추가한다** — 판정이 두 곳으로 갈라지면
"알림함에는 있는데 푸시는 안 온다"의 원인을 두 곳에서 찾아야 한다.

### 3.3 insert와 발송의 분리 (요구사항 그대로)

`enqueue_notification()`은 러닝 저장 트랜잭션 **안**에서 알림함 행만 만든다. 발송은
`dispatch_pending_pushes()`(pg_cron 매분 → pg_net → Edge Function)가 **트랜잭션 밖에서**
한다. 발송을 트랜잭션에 넣으면 FCM 장애가 곧 **러닝 저장 실패**가 된다.

Vault 시크릿이 없으면 `dispatch_pending_pushes()`는 **조용히 no-op** 한다 — FCM 연결
전에도 알림함 적재는 정상 동작해야 하고, cron이 매분 에러 로그를 쌓으면 안 된다.

---

## 4. 검증 (라이브 스모크 테스트)

| 시나리오 | 결과 |
|---|---|
| NT-03 D-14 | 10명 중 8건 발행. A(승급권 5) / B(비승급권 3) / C(플래티넘 1) 3변형 정상 |
| NT-03 D-3 | 2건 — 승급권 A + 플래티넘 C. **휴면·비승급권 B는 필터로 제외됨**(설계대로) |
| NT-01 + NT-06 | 브론즈 20.1km 유저에 6km 러닝 → `실버 승급!` 1건 + `Lv.8 달성 · 뱃지 1개 획득` 1건. **정확히 2건**, `stier_*`는 뱃지 개수에서 제외됨 |
| NT-02 | 브론즈 12.4km 유저에 8km 러닝 → `실버까지 4.6km`, `remaining_m=4600`. 승급이 아니므로 NT-01은 발화하지 않음 |
| NT-06 묶음 | 뱃지 2개 동시 획득 → `뱃지 2개를 획득했어요 / 워밍업 외 1개` **1건** |
| NT-05 일요일 | 8건 발행, 변형 B 문구·payload 정상 |
| NT-04 | 0건 — 시드 규모(티어당 1~4명)가 `participant_count >= 10` 게이트에 걸린다. **설계대로이며 실데이터 검증은 미완**(§6) |

테스트 데이터·알림 행은 전부 정리했고 프로필 시즌 거리·티어는 원상 복구했다.

`get_advisors(security)`: 신규 경고 2건(`mark_notifications_read`,
`register_push_token`이 `authenticated`에게 노출)은 **의도된 설계**다. 둘 다 내부에서
`auth.uid()`로 주체를 확정하며, 기존 `sync_my_season`과 같은 패턴이다. 그 외 경고는
전부 이번 작업 이전부터 있던 것이다.

---

## 5. 스모크 테스트로 잡은 결함 2건 (48번에서 수정)

**① `trg_level_up_notify`가 `new.user_id`를 참조했다 — `profiles`의 PK는 `id`다.**
plpgsql은 트리거 함수 본문의 필드 참조를 **실행 시점에** 해석하므로 CREATE는 통과하고,
러닝 없이 레벨이 오르는 경로(러닝 삭제·뱃지 `revoked`·`tier_change_history` INSERT)가
처음 실행될 때 `record "new" has no field "user_id"`로 터진다. 그리고 그 예외는
**러닝 저장·삭제 트랜잭션 전체를 롤백시킨다** — 이 설계가 가장 피하려던 실패 양상이
알림 코드 자체에서 나올 뻔했다. 실제로 테스트에서 러닝 삭제가 실패해 발견했다.

**② NT-05 변형 B가 "5km면 상위 100%예요"를 보냈다.** §2.4 참조.

---

## 6. 미해결 / 인계

### 6.1 flutter-ui-designer · mobile-architect가 이어받을 계약

**Provider가 호출할 것**

| 목적 | 경로 |
|---|---|
| 알림함 조회 | `notifications` select — `user_id` = 본인, `order created_at desc`, 커서 `before` |
| 미읽음 수 | `notifications` head count + `read_at is null` (부분 인덱스 있음) |
| 읽음 처리 | RPC `mark_notifications_read(p_ids uuid[])` — null이면 전체 읽음. 서버 시각 확정, 이미 읽은 행은 안 건드림 |
| 설정 조회/갱신 | `notification_settings` select / upsert(컬럼 하나만) |
| 토큰 등록 | RPC `register_push_token(p_token, p_platform, p_device_id, p_app_version)` |
| 토큰 해제 | `push_tokens` delete (본인 행) |

**구독할 테이블**: `notifications` (realtime publication 등록 완료). INSERT는
**재조회 신호로만** 쓴다 — `realtime_refetch.dart` 기존 패턴 그대로.

> ⚠️ **알림함 목록을 `NotificationSettings.isEnabled`로 필터하지 말 것.** 그 메서드는
> `pushEnabled`가 꺼져 있으면 false를 돌려주는 설정 화면용 판정이다. 서버는 종류별
> 토글이 꺼진 알림은 애초에 만들지 않고, 마스터 스위치는 **푸시만** 막는다(§2.5).
> 클라이언트가 한 번 더 거르면 마스터를 끈 사용자의 알림함이 통째로 비어 보인다.

> ⚠️ 토큰 등록이 단순 upsert가 아닌 이유: 같은 기기를 다른 계정이 쓰면 토큰은 그대로인
> 채 `user_id`만 바뀌는데, RLS update의 USING이 이전 소유자 행에 매칭되지 않아 실패한다.
> 그대로 두면 **기기를 넘겨받은 사용자에게 이전 사용자의 알림이 간다.**

**enum 3계층 일치 확인 완료**: `public.notification_type` 라벨 =
`lib/models/enums.dart`의 `@JsonValue` = `wire_enums.dart`의 `wire`. `device_platform`도
동일. `FieldRename.snake` 변환 결과가 모든 컬럼명과 정확히 일치한다(별칭 없음).

### 6.2 운영이 해야 할 것 (이것 없이는 푸시가 나가지 않는다)

> **이 목록이 서버 운영 절차의 정본이다.** `_workspace/20260828_174224_ui_notifications.md`
> §3.4에 앱 설정과 순서를 맞춰 보기 위한 요약본이 있으나, **서버 항목이 늘거나 바뀌면
> 여기를 먼저 고친다.** 요약본이 정본 행세를 하기 시작하면 드리프트가 난다.

1. FCM 프로젝트 생성 + 서비스 계정 키 발급
2. `supabase secrets set FCM_SERVICE_ACCOUNT='<서비스 계정 JSON>'`
3. `supabase functions deploy push-dispatch` — **아직 배포하지 않았다.** 시크릿 없이
   배포하면 동작하지 않는 엔드포인트만 남는다
4. Vault 시크릿 2개:
   ```sql
   select vault.create_secret('https://<ref>.functions.supabase.co/push-dispatch', 'push_dispatch_url');
   select vault.create_secret('<service_role_key>', 'push_dispatch_token');
   ```
5. 앱: `firebase_messaging` / `firebase_core` 의존성, `google-services.json` /
   `GoogleService-Info.plist`

**설정이 실제로 먹었는지 확인하는 법** — 위 2·4번은 성공해도 아무 로그를 남기지 않으므로
눈으로 확인할 방법이 필요하다:

```sql
-- 2행이 나와야 한다. 하나라도 없으면 dispatch_pending_pushes() 는 조용히 no-op 한다.
select name from vault.decrypted_secrets
 where name in ('push_dispatch_url', 'push_dispatch_token');
```

> ⚠️ **Vault 시크릿이 없으면 `notifications` 행에 실패 흔적조차 남지 않는다.**
> `dispatch_pending_pushes()`가 시크릿 부재 시 즉시 반환하므로 `claim_push_batch()`가
> 아예 돌지 않고, 그러면 큐 배출 마커(`no_token` / `push_disabled` / `expired`)도
> 찍히지 않는다. 즉 **`sent_at` null · `send_attempts` 0 · `send_error` null 세 개가
> 전부 비어 있으면 토큰 문제가 아니라 서버 설정 문제**다 — 토큰이 없는 경우라면
> 최소한 `no_token`은 남는다.
>
> no-op이 조용한 것은 "FCM 연결 전에도 알림함 적재는 정상 동작해야 하고 cron이 매분
> 에러 로그를 쌓으면 안 된다"는 §3.3의 선택이고 그대로 유지한다. 대신 위 쿼리와
> 아래 트리아지가 그 조용함을 메운다.

> **위 5단계가 끝난 뒤의 실기기 검증 절차는
> `_workspace/20260828_174224_ui_notifications.md` §5**에 있다(검증 항목 8개 +
> 서버 상태 해석표). 이 목록은 "푸시가 나갈 수 있는 상태를 만드는 것"까지이고,
> "실제로 나가는지 확인하는 것"은 그쪽이다.
>
> 검증 중 증상만으로 클라이언트 문제인지 발송 문제인지 갈리지 않으면
> `notifications` 행의 `sent_at` / `send_attempts` / `send_error`를 본다 —
> `sent_at`이 차 있고 `send_error`가 null이면 **서버는 FCM에 넘긴 것**이고, 그 뒤는
> 토큰·권한·네이티브 설정 문제다. `send_attempts`가 0에서 움직이지 않는데 재시도가
> 반복되면 **C-1 재발**이므로 backend를 호출할 것(§7.1).

### 6.3 미해결 항목

| # | 항목 | 판단 |
|---|---|---|
| 1 | **RK-06 주간 상위권 뱃지 결함 2건** (gamification §6.2 #1·#2 — 최소 모집단 게이트 없음, 진행 중인 주간을 판정에 포함) | **이번 작업에 넣지 않았다.** 알림 규칙이 아니라 뱃지 판정 정확성 버그이고, 섞으면 "알림을 넣었더니 뱃지가 바뀌었다"가 되어 회귀 추적이 불가능해진다. 다만 **베타 사용자 10명을 넘는 순간부터 잘못된 뱃지가 나가고 되돌릴 수 없다** — TRD §14-#23으로 등록. 수정 SQL은 gamification 문서 §6.2에 이식 가능한 형태로 있다 |
| 2 | 주간 확정 배치(월 00:10 KST)가 없다 | TRD §14-#12(기존). 이것이 없어서 딸린 미구현 2건: RK-06 뱃지가 "주간 확정 직후"가 아니라 다음 러닝 때 발급되고, NT-06의 `badge_level:weekly:{week_id}` 키를 쓰는 발화점이 아직 없다 |
| 3 | NT-04 실데이터 미검증 | 시드 규모가 `participant_count >= 10` 게이트에 걸려 한 건도 발화하지 않는다. 게이트를 낮추는 것은 답이 아니다(참가자 한 자리에서 "3계단 하락"은 곧 꼴찌다). 베타 20명 이상에서 재검증 필요 |
| 4 | 공개 범위(AC-05)와 알림 문구 | NT-04/NT-05가 `display_name`을 그대로 쓴다. 공개 범위 컬럼이 스키마에 아직 없어 지금은 우회 경로가 존재하지 않지만, AC-05 구현 시 **알림 쪽도 같이 막아야 한다.** TRD §14-#24 |
| 5 | PRD §5.10 NT-05 예시 문구 | PRD는 `"10위까지 2.1km"`, 구현은 `"앞사람까지 0.8km · 128위(상위 34%)"`(§5.4.1·RK-04 준수). gamification 문서 §9가 지적한 그대로이며 **오케스트레이터가 사용자 확인 후 PRD를 갱신할 대상**이다 |
| 6 | 방해 금지 시간 | 배치 계열만 KST 08~22시로 제한했다(gamification §5.4). 사용자별 설정은 PRD에 없어 만들지 않았다 |
| 7 | 오래된 토큰 정리 배치 | `push_tokens.updated_at` 인덱스만 만들어 뒀다. 270일 무갱신 토큰 정리는 실사용 데이터가 쌓인 뒤 |

---

## 7. QA CONFIRMED 3건 수정 (마이그레이션 49 · 50) — 2026-08-28

정본: `_workspace/20260828_205500_qa_notifications.md`.
세 건 모두 **푸시가 실제로 나가기 시작하는 순간** 드러났을 결함이라, 알림함(인앱)
경로만 검증한 44~48 자체 라운드에서는 잡히지 않았다.

### 7.1 C-1 (치명) — 가드가 서버 자신의 발송 상태 기록을 되돌리고 있었다

44-5 `notifications_guard`는 UPDATE 시 `is_server_write()`가 아니면
`sent_at`·`send_error`·`send_attempts`를 전부 old 값으로 되돌린다. 47번의 큐 배출
UPDATE 3건과 claim UPDATE, `mark_push_result`가 그 플래그를 세우지 않았다.
`is_server_write()`는 세션 GUC만 보므로 SECURITY DEFINER나 service_role 여부와 무관하다.

**알림함의 쓰기 보호를 세운 바로 그 가드가, 그 보호를 세운 쪽의 쓰기를 막고 있었다.**
결과는 ① `sent_at`이 영원히 null → 대기열에서 안 빠짐 → **같은 푸시가 매분 무한 반복**
② `send_attempts`가 안 늘어 3회 실패 만료 경로 사망 ③ `push_enabled=false` 배출 무효 →
**마스터 스위치를 끈 사용자에게도 푸시**(NT-08 위반). `dedupe_key`는 알림함 insert만
막지 발송은 막지 못한다.

수정: `_server_write_enter()` / `_server_write_exit(prev)` 구간으로 감쌌다.
`mark_push_result`는 `language sql`이라 `set_config` 구간을 열 수 없어 plpgsql로 바꿨다.

**가드를 완화하는 대안은 택하지 않았다.** 가드가 되돌리는 컬럼 목록을 줄이면, 나중에
누가 클라이언트 update 정책을 넓혔을 때 방어선이 한 겹 사라진 사실을 아무도 눈치채지
못한다. 44번의 "가드는 두 겹 방어선" 의도를 유지하는 쪽이 맞다.

**S-1도 같이 해소했다.** 옛 관례인 무조건 `set_config(...,'off')` 복원은 중첩 호출에서
바깥 구간을 조기 종료시킨다. 이번에 `claim_push_batch` 안에서 가드 걸린 UPDATE를 여러 번
하는 구조가 실제로 생겼으므로 더 미룰 수 없었다. `_server_write_enter()`는 **이전 값을
돌려주고 exit이 그 값을 복원**한다.

### 7.2 C-2 (높음) — FCM `data.type` 누락

클라이언트는 `message.data['type']`으로 종류를 판정해 성취 계열(NT-01·NT-06)의 인앱
배너를 생략한다. 그런데 `claim_push_batch` 반환에 `type`이 없어 이 값이 **항상
undefined**였다 → 배너가 뜨고 몇 초 뒤 `AchievementCelebrationHost`가 풀페이지 축하를
또 띄운다. ARCHITECTURE §7.4.1 "소비 지점은 하나"가 런타임에서 깨져 있었다.

수정: `claim_push_batch` 반환 테이블에 `type public.notification_type` 추가,
Edge Function이 `data.type = row.type`을 명시적으로 싣는다.

> **오케스트레이터 지시에서 한 가지를 다르게 했다.** 지시는 "`enqueue_notification`이
> payload에 `type` 포함"도 포함했으나, **payload에는 넣지 않았다.** QA C-2의 수정
> 방향이 명시적으로 "payload에 type을 섞는 방식은 권장하지 않는다"이고, 근거에 동의한다 —
> payload 규약(TRD §4.1-N)은 "서버가 채우는 **표시값**"이고 종류는 이미
> `notifications.type` 컬럼이자 `AppNotification.type` 필드다. 같은 사실을 두 곳에 적으면
> 어긋났을 때 어느 쪽이 진짜인지 판단할 근거가 사라진다. **FCM에 도달한다는 목표는
> 전용 컬럼 경로로 완전히 달성된다**(§7.4 재검증).

### 7.3 C-3 (높음) — 존재하지 않는 route 3종

flutter-ui-designer가 확정한 값으로 정정했다(마이그레이션 50).

| 종류 | 옛 발행값 | **확정값** |
|---|---|---|
| NT-01 | `/home` | `/home` (유지) |
| NT-02 | `/home` | `/home` (유지) |
| NT-03 변형 A(승급권) | `/home` | `/home` (유지) |
| NT-03 변형 B(비승급권) | `/profile` | `/profile` (유지) |
| NT-03 변형 C(플래티넘) | `/ranking` ❌ | **`/home`** |
| NT-04 rank_change | `/ranking` ❌ | **`/home`** |
| NT-05 weekend_push (A·B·C) | `/ranking` ❌ | **`/home`** |
| NT-06 러닝 유래 | `/runs/{run_id}` ❌ | **`/history/run/{run_id}`** |
| NT-06 레벨 단독 | `/profile/badges` ❌ | **`/history?tab=badges`** |

원인은 알림 구현이 **2026-08-21 4탭 개편 이전의 화면 구성을 가정**한 것이다. 랭킹 독립
탭은 홈으로, 뱃지 독립 탭은 활동 화면의 하위 탭으로 흡수됐고 `/ranking`·`/profile/badges`·
`/runs/{id}`는 이 앱에 **존재한 적이 없다.**

가장 나쁜 것은 `/profile/badges`였다 — 클라이언트 화이트리스트가 접두 매칭이라
`/profile/`에 걸려 **통과**한 뒤 go_router에서 `no routes for location`으로 터졌다.
화이트리스트가 막으려던 실패를 화이트리스트가 통과시킨 것이고, 도달 경로(러닝 없는
레벨업)는 실재한다. UI가 접두 매칭을 완전 일치 + 파라미터 패턴으로 교체했다.

**50-6에서 이미 쌓인 행의 `payload.route`도 백필했다.** 클라이언트에 과거 행 변환표가
있지만 그건 과거 데이터용 임시 장치다 — 서버가 남긴 잘못된 값은 서버가 치워야 변환표가
영구 장치가 되지 않는다.

### 7.4 원격 재검증

**C-1** — 알림 3건(정상/마스터 off/토큰 없음)을 심고 실제 워커 경로를 돌렸다.

| 검증 | 결과 |
|---|---|
| claim 대상 | `QA49 A` 1건만 (B·C는 큐에서 배출) ✅ |
| 마스터 off 배출 | `sent_at` 기록 + `send_error='push_disabled'` ✅ **(수정 전엔 전부 되돌아갔다)** |
| 토큰 없음 배출 | `sent_at` 기록 + `send_error='no_token'` ✅ |
| 실패 → 재시도 | `attempts 1 → 2`, 큐에 잔류, `send_error='FAIL-1'` ✅ |
| 성공 | `sent_at` 기록, `send_error` null, **큐에서 이탈** ✅ (무한 재발송 종료) |
| 3회 실패 후 | 다음 주기에 `send_error='expired'`로 만료 ✅ |
| 가드 2겹 방어선 | `server_write` 없는 UPDATE(`send_attempts=99` 시도)는 여전히 **전부 되돌아감** ✅ |

**C-2** — `claim_push_batch`가 `type='rank_change'`를 정상 반환. Edge Function이
`data.type`으로 싣는다(배포 전이라 FCM 왕복은 미검증 — §6.2 운영 항목).

**C-3** — NT-01/03(A·B·C)/05(B)/06(러닝 유래·레벨 단독)을 실제 발화시켜 route 실측.
발행된 **20건 전부** 라우터 등록 경로와 일치(`/home` 15 · `/profile` 3 ·
`/history/run/{uuid}` 1 · `/history?tab=badges` 1). 특히 옛날에 크래시하던 레벨 단독
경로가 `/history?tab=badges`로 정상 발행됐다.

**S-3** — `runnit-rank-notify`의 UTC 13시(= KST 22:00) 슬롯을 제거했다
(`0 23,0-13` → `0 23,0-12`). `_batch_hours_ok`가 `between 8 and 21`이라 항상 no-op이던
슬롯이다. 게이트를 22로 넓히지 않은 이유: "08:00~22:00"을 반열림 구간으로 읽는 쪽이
마감 시각 표기 규약(주간 마감 23:59, 시즌 경계)과 같고, 22:00 정각 발송은 방해 금지
경계에 걸친다.

`get_advisors(security)` 재실행 — **신규 경고 없음**(기존 5건 그대로).
테스트 데이터·알림 행은 전부 정리했고 프로필 티어·시즌 거리는 원상 복구했다.

### 7.5 문서 갱신 (D-1 · D-2)

- **D-1**: TRD §4.1-N의 `dedupe_key` 예시에 NT-04 순번을 반영
  (`rank_change:2026-W35:down` → `rank_change:2026-W35:down:2`).
- **D-2**: TRD **§6-N.7 "종류별 딥링크 목적지 — 서버 발행값의 정본"** 신설.
  "종류 → route → 실제 go_router 경로" 3열 표가 어디에도 없었던 것이 C-3이 문서
  검토에서 안 잡힌 원인이다. 표 위에 "route를 바꿀 때 `notification_deep_link.dart`와
  ARCHITECTURE §5.6.1을 함께 고칠 것"을 못박았다.
- TRD §6-N.6에 `_server_write_enter`/`_exit` 사용 의무와 FCM `data` 페이로드 규약
  (`type`은 payload가 아니라 전용 컬럼) 추가.

### 7.6 남은 것

QA의 나머지 항목 중 backend 몫은 없다. S-2(`columnOf(points)`)는 mobile 몫이고,
PRD §5.10 NT-05 예시 문구 갱신은 리더 확인 대상이다(§6.3-#5). §6.3의 미해결 6건은
그대로 유효하며, 특히 **#1(RK-06 뱃지 최소 모집단 게이트)은 베타 오픈 전 필수**다.
