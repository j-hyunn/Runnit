# QA :: 알림 시스템(NT-01~08) 실기기·수동 검증 체크리스트 (정본)

- 일시: 2026-09-01
- 작성: qa-integration-tester
- 대상: 마이그레이션 44~50, `supabase/functions/push-dispatch/index.ts`,
  `lib/core/notifications/*`, `lib/features/notifications/**`
- 정본 참조: `docs/PRD.md` §5.4(RK-05)·§5.10(NT-01~08)·TI-07·GM-04,
  `docs/TRD.md` §14-#25, `docs/ARCHITECTURE.md` §7.4.1·§7.5
- **이 문서가 메모리 노트 `notification-testing-todo`(NT-01~08 수동/실기기 검증 보류)를 대체한다.**
  선행 문서 4건(`20260828_164428_architect_notifications.md`,
  `20260828_174224_ui_notifications.md` §3·§5,
  `20260828_181500_gamification_notification-rules.md`,
  `20260828_193000_backend_notifications.md` §6.2)의 절차를 이 문서 하나로 합쳤다.
  서버 운영 절차가 바뀌면 backend 문서 §6.2를 먼저 고치고 여기로 반영한다.

> ⚠️ 이 문서는 **검증 절차 문서**다. 새 코드·마이그레이션을 만들지 않는다.

---

## 0. 원격 실측 결과 (2026-09-01, project `xwtbwexcofcgmbvktwdo`)

이 절은 **추측이 아니라 MCP로 실제 조회한 값**이다. 검증을 시작하기 전 현재 좌표.

| 항목 | 실측값 | 판정 |
|---|---|---|
| 마이그레이션 44~50 적용 | 테이블 `notifications` · `push_tokens` · `notification_settings` 존재 | ✅ |
| pg_cron job (알림 관련 5건) | `runnit-push-dispatch`(`* * * * *`) · `runnit-rank-notify`(`0 23,0-12 * * *`) · `runnit-notify-season-ending`(`0 0 * * *`) · `runnit-weekend-push-sat`(`0 1 * * 6`) · `runnit-weekend-push-sun`(`0 9 * * 0`) — **전부 `active = true`** | ✅ |
| cron 실행 이력(48h) | 실패 0건. `runnit-push-dispatch` 2,880회 succeeded(= 매분 정상), `runnit-weekend-push-sun` 08-30 09:00Z 1회 succeeded | ✅ |
| `pg_net` 확장 | 설치됨 | ✅ |
| **Edge Function `push-dispatch` 배포** | **원격에 함수 0개 — 미배포** | ❌ **차단** |
| **Vault 시크릿 2개** | `push_dispatch_url` / `push_dispatch_token` **0행** | ❌ **차단** |
| **`push_tokens` 행** | **0행** | ❌ (앱 FCM 설정 미완의 결과) |
| `notification_settings` 행 | 0행 (= 전 종류 on 으로 간주, 정상) | ✅ |
| `notifications` 행 | 9행 — `weekend_push` 8 + `badge_level:run:…` 1. **전부 `sent_at` null · `send_attempts` 0 · `send_error` null** | ⚠️ 후술 |
| 저장된 `route` 값 | `/home` 8건, `/history/run/{uuid}` 1건 — 마이그레이션 50 확정값과 일치, 옛 경로(`/ranking`·`/profile/badges`·`/runs/…`) 0건 | ✅ |
| 앱 네이티브 FCM 설정 파일 | `android/app/google-services.json` · `ios/Runner/GoogleService-Info.plist` **둘 다 없음** | ❌ **차단** |
| 현재 시즌 | `2026-Q3` (종료 2026-09-30 24:00 KST) | — |
| 주간 랭킹 모집단 | `leaderboard_entries` 9행, `participant_count` 최대 **4** | ⚠️ NT-04/NT-05 게이트 미달 |

### 0.1 이 실측이 말해 주는 것

1. **서버의 "알림함 적재" 경로는 살아 있다.** cron이 정상적으로 돌고 실제 알림 행이
   쌓였다. `weekend_push` 8건은 08-30(일) 09:00Z = KST 18:00에 `notify_weekend_push()`가
   정상 발화한 증거다.
2. **푸시 발송 경로는 한 번도 돌지 않았다.** `sent_at`·`send_attempts`·`send_error`
   **세 개가 전부 비어 있는 것**이 그 증거다 — UI 문서 §5 트리아지 표의 마지막 행 그대로,
   Vault 시크릿 부재로 `dispatch_pending_pushes()`가 조용히 no-op 하고 있다.
   토큰이 없어서라면 최소한 `send_error = 'no_token'`이 찍혔어야 한다.
3. **9건은 이미 24시간을 넘겼다.** 발송 설정을 마치는 순간 `claim_push_batch()`가
   `created_at < now() - 24h` 조건으로 이 행들을 `send_error = 'expired'`로
   큐 밖으로 내보낸다 — **정상 동작이며, "왜 옛 알림이 안 왔지"로 착각하지 말 것.**
   § 6.1의 재현 절차로 새 행을 만들어 검증한다.
4. **NT-04(순위 변동)와 NT-05의 상위% 문구는 현재 시드로는 발화하지 않는다.**
   `participant_count` 최대가 4인데 NT-04 게이트는 `>= 10`, NT-05 B변형의 백분율
   표기 게이트는 `>= 5`다. 게이트를 낮추는 것은 답이 아니다(§6.4 참조).

---

## 1. 사전 준비 체크리스트

**§1을 전부 마치기 전에는 §6 검증을 시작하지 말 것.** 한쪽만 끝난 상태에서는 모든 항목이
"안 옴"으로만 보이고 원인을 가릴 수 없다.

### 1.1 FCM 프로젝트 · 네이티브 설정 (앱)

| # | 항목 | 완료 판정 방법 |
|---|---|---|
| P-1 | Firebase 콘솔에서 프로젝트 생성, Android 앱(`com.runnit.runnit`)·iOS 앱(번들 ID) 등록 | 콘솔에 두 앱이 보인다 |
| P-2 | `google-services.json` → `android/app/google-services.json` | `ls android/app/google-services.json` |
| P-3 | `GoogleService-Info.plist` → `ios/Runner/GoogleService-Info.plist` **+ Xcode Runner 타겟에 파일 참조 추가** | 디렉터리에 두기만 하면 런타임에 못 찾는다. Xcode → Runner → Build Phases → Copy Bundle Resources 에 보여야 한다 |
| P-4 | `android/settings.gradle.kts` · `android/app/build.gradle.kts` 의 `com.google.gms.google-services` 플러그인 주석 **두 줄 함께** 해제 | ⚠️ P-2 없이 플러그인만 켜면 빌드가 "File google-services.json is missing"으로 실패한다 |
| P-5 | Xcode → Runner → Signing & Capabilities → **+ Capability → Push Notifications** | `Runner.entitlements`의 `aps-environment`만으로는 부족하다 — capability를 추가해야 프로비저닝 프로파일에 APNs가 들어간다(HealthKit과 같은 절차) |
| P-6 | **APNs 인증 키(.p8) 발급 → Firebase 콘솔에 업로드** | 이것이 없으면 iOS에는 푸시가 **전혀** 가지 않는다. 콘솔 → 프로젝트 설정 → 클라우드 메시징 → Apple 앱 구성에 키가 보인다 |
| P-7 | `Info.plist` `UIBackgroundModes`에 `remote-notification` | 이미 추가돼 있다(확인만) |
| P-8 | 실기기에서 앱 실행 시 Firebase 초기화 성공 | 로그에 `[firebase] 초기화를 건너뜁니다` 가 **없어야** 한다(`lib/core/notifications/firebase_bootstrap.dart:31`) |

### 1.2 서버 (Supabase)

| # | 항목 | 완료 판정 쿼리/명령 |
|---|---|---|
| P-9 | 서비스 계정 키 발급 후 `supabase secrets set FCM_SERVICE_ACCOUNT='<JSON 전문>'` | `supabase secrets list` 에 `FCM_SERVICE_ACCOUNT` |
| P-10 | **`supabase functions deploy push-dispatch`** | §2 Q-1 (현재 **미배포**) |
| P-11 | Vault 시크릿 2개 생성 | §2 Q-2 가 **2행**을 돌려줘야 한다 (현재 **0행**) |
| P-12 | pg_cron job 5건 active | §2 Q-3 |

```sql
-- P-11 생성문 (backend §6.2 정본). <ref> = 프로젝트 ref, 키는 service_role.
select vault.create_secret('https://<ref>.functions.supabase.co/push-dispatch', 'push_dispatch_url');
select vault.create_secret('<service_role_key>', 'push_dispatch_token');
```

> ⚠️ **P-9·P-11은 성공해도 아무 로그를 남기지 않는다.** 반드시 §2의 확인 쿼리로 단정할 것.
> 시크릿이 없으면 `dispatch_pending_pushes()`가 즉시 return 하므로
> `claim_push_batch()`가 아예 돌지 않고, 큐 배출 마커(`no_token`/`push_disabled`/`expired`)조차
> 찍히지 않는다. 그 조용함은 "FCM 연결 전에도 알림함은 정상 동작해야 한다"는 의도적 선택이다
> (`supabase/migrations/20260828190300_47_push_dispatch.sql:154-200`).

### 1.3 테스트 계정 · 기기

| # | 항목 | 비고 |
|---|---|---|
| P-13 | 실기기 2대(A: iOS, B: Android 권장) — **각각 다른 계정으로 로그인** | NT-04 "추월당함/추월함"은 두 계정의 상대 순위가 바뀌어야 한다 |
| P-14 | 두 계정 모두 **알림 권한 승인** | 권한 요청 시점은 **첫 러닝 완료 직후 하나뿐**이다(`push_permission.dart:53`). 프라이밍 카드는 `notDetermined`에서만 뜬다 — 한 번 거부하면 앱은 되돌릴 수 없고 시스템 설정으로 가야 한다 |
| P-15 | 두 계정의 `uid` 확보 | 아래 모든 쿼리의 `<uid>` |
| P-16 | 같은 티어일 것 | 주간 랭킹은 **같은 티어 안에서만** 경쟁한다(PRD §5.4). 티어가 다르면 서로의 순위에 영향을 주지 않는다 |
| P-17 | NT-04 검증용으로는 **같은 티어 참가자 10명 이상** 필요 | 현재 최대 4명 → §6.4 참조 |

---

## 2. Supabase 점검 쿼리 모음

복사해서 그대로 쓰는 용도. `<uid>`만 바꾼다.

```sql
-- Q-1. Edge Function 배포 여부 (SQL로는 안 보인다 — CLI/대시보드)
--   supabase functions list
--   기대: push-dispatch 1건. 현재(2026-09-01): 0건.

-- Q-2. Vault 시크릿 — 2행이 나와야 한다. 하나라도 없으면 디스패처는 조용히 no-op.
select name, created_at from vault.decrypted_secrets
 where name in ('push_dispatch_url', 'push_dispatch_token');

-- Q-3. cron job 목록 + 활성 여부
select jobid, jobname, schedule, active, command
  from cron.job where jobname like 'runnit-%' order by jobname;

-- Q-4. cron 마지막 실행 · 실패 여부 (최근 2일)
select j.jobname, d.status, count(*) as runs,
       max(d.start_time) as last_run, max(d.return_message) as sample_msg
  from cron.job_run_details d join cron.job j on j.jobid = d.jobid
 where d.start_time > now() - interval '2 days'
 group by 1, 2 order by 1, 2;

-- Q-5. 실패한 cron 실행만
select j.jobname, d.start_time, d.return_message
  from cron.job_run_details d join cron.job j on j.jobid = d.jobid
 where d.status <> 'succeeded' and d.start_time > now() - interval '7 days'
 order by d.start_time desc limit 50;

-- Q-6. 미발송 큐 (디스패처가 훑는 대상 = notifications_pending_idx)
select id, user_id, type, title, payload->>'route' as route,
       created_at, send_attempts, send_error
  from public.notifications
 where sent_at is null order by created_at limit 50;

-- Q-7. 최근 발송 로그 (특정 사용자) — UI 문서 §5 트리아지 표의 입력값
select type, title, body, payload->>'route' as route, dedupe_key,
       created_at, sent_at, send_attempts, send_error, read_at
  from public.notifications
 where user_id = '<uid>' order by created_at desc limit 20;

-- Q-8. 발송 결과 집계 (건강도 한눈에)
select coalesce(send_error, case when sent_at is null then '(대기)' else '(성공)' end) as outcome,
       count(*), max(created_at) as latest
  from public.notifications group by 1 order by 2 desc;

-- Q-9. 토큰 등록 상태
select token, user_id, platform, device_id, app_version, created_at, updated_at
  from public.push_tokens order by updated_at desc;

-- Q-10. 알림 종류별 수신 설정 (행이 없으면 전 종류 on)
select * from public.notification_settings where user_id = '<uid>';

-- Q-11. 주간 랭킹 모집단 — NT-04(>=10) · NT-05 B변형 백분율(>=5) 게이트 확인
select tier, period_start, count(*) as entries, max(participant_count) as pc
  from public.leaderboard_entries
 where period = 'weekly' and metric = 'distance' and scope = 'global' and tier is not null
 group by 1, 2 order by 2 desc, 1;

-- Q-12. NT-04 기준선 상태 (notified_rank 가 null 이면 그 사이클은 기준선만 잡고 넘어간다)
select user_id, tier, rank, notified_rank, notified_at, participant_count
  from public.leaderboard_entries
 where period = 'weekly' and metric = 'distance' and scope = 'global' and tier is not null
 order by tier, rank;

-- Q-13. 시즌 경계 — D-14 / D-3 이 며칠인지
select public.season_id_at(now()) as season,
       public.season_start(public.season_id_at(now())) as s_start,
       public.season_end(public.season_id_at(now()))   as s_end,
       ((public.season_end(public.season_id_at(now())) - interval '1 second')
          at time zone 'Asia/Seoul')::date
         - (now() at time zone 'Asia/Seoul')::date as days_left;

-- Q-14. realtime publication 에 notifications 가 있는가 (인앱 알림함 실시간 갱신)
select tablename from pg_publication_tables
 where pubname = 'supabase_realtime' and tablename = 'notifications';

-- Q-15. 배치 수동 발화 (관리자 세션에서만. 반환값 = 발행 건수)
select public.notify_season_ending();               -- NT-03 (D-14/D-3 아니면 0)
select public.refresh_leaderboards_and_notify();    -- 리더보드 재계산 + NT-04
select public.notify_weekend_push();                -- NT-05 (토/일 아니면 0)
select public.dispatch_pending_pushes();            -- 발송 워커 즉시 깨우기
```

> `notify_*` 3종과 `dispatch_pending_pushes`는 `revoke execute ... from public, anon,
> authenticated` 상태다. 앱 세션으로는 못 부르고, MCP/대시보드 SQL 에디터(서비스 권한)에서만
> 실행된다 — 그것이 의도다.

---

## 3. 발송 경로 한 장 요약

```
[사건]                          [SQL 판정·문구 완성]                       [적재]
러닝 저장 / 티어 승급 / 레벨업 ─▶ 45·50번 트리거 함수 ──┐
시즌 D-day / 순위 변동 / 주말   ─▶ 46·50번 배치 함수 ────┼─▶ enqueue_notification()
                                                        │     ├ notification_enabled() : NT-08 종류별 토글
                                                        │     ├ payload || {route}     : 딥링크 주입
                                                        │     └ on conflict (user_id, dedupe_key) do nothing : 멱등
                                                        └─────────▶ public.notifications 1행

[발송]  pg_cron `runnit-push-dispatch` (매분)
          └▶ dispatch_pending_pushes()           47/49번. Vault 시크릿 없으면 조용히 no-op
               └▶ pg_net http_post ─▶ Edge Function `push-dispatch`
                    ├▶ claim_push_batch(100)      큐 배출(push_disabled/no_token/expired) + claim + send_attempts++
                    ├▶ FCM HTTP v1 messages:send  notification{title,body} + data{notification_id, type, ...payload}
                    ├▶ mark_push_result(id, err)  성공 시 sent_at, 실패 시 error만(최대 3회 재시도)
                    └▶ prune_push_token(token)    UNREGISTERED/INVALID_ARGUMENT 시 토큰 삭제

[클라] push_messaging.dart
  ├ onMessage        (포그라운드) → type.isAchievement 면 배너 생략, 아니면 PushBanner 스트림
  ├ onMessageOpenedApp(백그라운드 탭) → navigateTo(route)
  ├ getInitialMessage (종료 상태 탭) → addPostFrameCallback 후 navigateTo(route)
  └ 경로는 전부 NotificationDeepLink.resolveRaw(route, type) 를 통과 — 화이트리스트 미통과 시 종류별 폴백
```

**설계 고정점 3개** (검증 중 "이상한데?" 싶을 때 여기로 돌아온다)

1. **문구는 서버가 완성한다.** 클라이언트는 `title`/`body`를 그대로 그린다 —
   트레이 문구와 알림함 문구가 갈라지면 같은 사건이 두 가지로 보인다.
2. **멱등의 유일한 방어선은 `unique (user_id, dedupe_key)`다.** 발송 상한도 키에
   순번을 넣어 이 제약으로 강제한다(NT-04).
3. **알림함 적재와 푸시 발송은 다른 트랜잭션이다.** FCM이 죽어도 러닝 저장은 성공한다.

---

## 4. 알림 종류별 검증 시나리오

각 항목의 구성: **트리거 조건 / 발송 경로 / 클라 수신·표시 / 수동 재현 / 기대 결과 / 실패 시 확인 포인트.**

---

### NT-01 · 티어 승급 (PRD §5.3, `tier_promotion`)

| 항목 | 내용 |
|---|---|
| **트리거** | `public.tier_change_history` **INSERT** → 트리거 `tier_change_history_02_notify` → `trg_tier_promotion_notify()` (`20260828190100_45_notifications_triggers.sql:92,131`) |
| **왜 profiles가 아니라 tier_change_history인가** | 마이그레이션 34 이후 이 테이블은 **상승만** 기록한다. 시즌 하드리셋(전원 브론즈)과 부정기록 무효화는 행을 만들지 않으므로, 여기 INSERT 되는 것이 곧 "승급"이다. profiles를 감시하면 분기 첫날 전 사용자에게 "브론즈 승급!"이 나간다 |
| **문구** | `"골드 승급!"` / `"이번 시즌 103.2km를 달렸어요. 2026 Q3 골드에 올랐어요."` |
| **route / dedupe_key** | `/home` · `tier_promotion:{season_id}:{tier}` → **시즌당 최대 3건(구조적 상한)** |
| **클라** | 성취 계열(`isAchievement`) → **포그라운드 배너 없음.** `AchievementCelebrationHost`의 풀페이지 축하만 뜬다(`push_messaging.dart:114`). 백그라운드/종료 탭 시 `/home` |
| **수동 재현** | 계정 A의 시즌 누적 거리를 티어 임계선(실버 25km / 골드 100km / 플래티넘 250km) **바로 아래**로 맞춰 두고, 임계선을 넘기는 러닝 1건을 실제로 업로드한다. `is_flagged=false` · `status='completed'` 여야 한다 |
| **기대** | `notifications` 에 `type='tier_promotion'` 1행 + 트레이 푸시 1건. 같은 시즌·같은 티어로 두 번은 절대 오지 않는다 |
| **실패 시** | ① `tier_change_history` 에 행이 생겼는가(안 생겼으면 알림이 아니라 **티어 재계산** 문제) ② `notifications` 행이 없으면 `notification_settings.tier_promotion` 확인 ③ 행은 있는데 푸시가 없으면 §5 트리아지 |

---

### NT-02 · 다음 티어 근접 (`tier_proximity`)

| 항목 | 내용 |
|---|---|
| **트리거** | `public.runs` INSERT/UPDATE → 트리거 `runs_04_notifications` → `trg_runs_notifications()` (`…_50_notification_routes.sql:80`, 트리거 정의 `…_45_…sql:351`) |
| **조건** | `status='completed'` · `is_flagged=false` · `activity_type <> 'indoor_run'` · **시즌 종료까지 24시간 초과** · 다음 티어까지 잔여가 밴드 안 |
| **밴드 폭** | `tier_proximity_threshold_m()` — 실버 **5,000m** / 골드 **10,000m** / 플래티넘 **15,000m** (계산식이 아니라 고정 테이블. 부동소수 경계 사고 차단) |
| **route / dedupe_key** | `/home` · `tier_proximity:{season_id}:{next_tier}` → 시즌·티어당 1건 |
| **클라** | 성취 계열이 **아니다** → 포그라운드 인앱 배너가 뜬다. 탭 시 `/home` |
| **수동 재현** | 계정 A의 시즌 누적을 예: 골드(100km)까지 12km 남은 상태로 만들고 **2km 러닝**을 올린다(잔여 10km → 밴드 진입). 실내 러닝으로 올리면 발화하지 않는 것이 정상 |
| **기대** | 알림 1건 + 인앱 배너(포그라운드일 때). 같은 시즌에 같은 다음-티어로는 재발송 없음 |
| **실패 시** | ① `activity_type`이 `indoor_run` 아닌지 ② 시즌 종료 24h 이내가 아닌지(Q-13) ③ 이미 같은 dedupe_key 행이 있는지(Q-7) |

---

### NT-03 · 시즌 종료 D-14 / D-3 (PRD TI-07, `season_ending`)

| 항목 | 내용 |
|---|---|
| **트리거** | pg_cron **`runnit-notify-season-ending`** `0 0 * * *`(UTC) = **KST 09:00 매일** → `notify_season_ending()` (`…_50_notification_routes.sql:177`) |
| **게이트** | `_batch_hours_ok()` KST 08~21시 · `days_left`가 **정확히 14 또는 3**일 때만 · 이번 시즌에 완주 러닝이 1건 이상인 사용자만 |
| **3가지 변형** | **A**(다음 티어 도달 가능 — D-14는 잔여 ≤40km, D-3은 ≤10km): `"시즌 종료 D-14 · 골드까지 32.0km"` → `/home` · **B**(도달 불가): `"시즌 종료 D-14"` + 시즌 요약 → `/profile`. **D-3의 B는 최근 14일 러닝이 있는 활성 사용자에게만** · **C**(이미 플래티넘): `"시즌 종료 D-3 · 2026 Q3 플래티넘 확정"` → `/home` |
| **dedupe_key** | `season_ending:{season_id}:d{14|3}` → 시즌당 최대 2건 |
| **클라** | 성취 계열 아님 → 배너 뜸. 탭 시 변형별 목적지(`/home` 또는 `/profile`) |
| **수동 재현** | 현재 시즌 `2026-Q3` 기준 **D-14 = 2026-09-16(KST), D-3 = 2026-09-27(KST)**. 그날을 기다리지 않으려면 `select public.notify_season_ending('2026-09-16 09:00+09'::timestamptz);` 로 **시각 인자를 직접 넘겨** 호출한다(반환값 = 발행 건수). 세 변형을 다 보려면 계정 3개의 시즌 누적을 A/B/C에 맞게 배치한다 |
| **기대** | 반환값 > 0, 계정별로 변형에 맞는 문구 1건. 같은 날 두 번 호출해도 dedupe로 추가 발행 0건 |
| **실패 시** | ① 반환 0이면 `days_left`가 14/3이 아니거나(Q-13) 호출 시각이 KST 08~21시 밖 ② 시즌 내 완주 러닝이 없는 계정은 애초에 대상이 아니다 ③ Q-4로 cron이 실제로 돌았는지 |

---

### NT-04 · 순위 변동 = 추월함/추월당함 (PRD §5.4 RK-05, `rank_change`)

| 항목 | 내용 |
|---|---|
| **트리거** | pg_cron **`runnit-rank-notify`** `0 23,0-12 * * *`(UTC) = **KST 08:00~21:00 매시** → `refresh_leaderboards_and_notify()` → `refresh_all_leaderboards()` 후 `notify_rank_changes()` (`…_50_notification_routes.sql:252`) |
| **게이트(모두 통과해야 발화)** | ① `_batch_hours_ok()` KST 08~21시 ② 주 시작 후 **24시간 경과** ③ **`participant_count >= 10`** ④ 상위 밴드 `max(30, ceil(pc*0.3))` 안에 현재 순위 또는 이전 순위가 있을 것 ⑤ 마지막 알림 후 **6시간** 경과 |
| **방향 판정** | **down(추월당함)**: 순위가 **3계단 이상** 하락 · **up(추월함)**: **5계단 이상** 상승, 또는 10위/3위/1위 진입 |
| **상한** | 주당 총 4건, down 3건 · up 2건. `dedupe_key = rank_change:{week_id}:{down|up}:{n}` 의 순번 n + unique 제약으로 **강제** |
| **문구** | down: `"홍길동님에게 추월당했어요"` / `"골드 7위 · 앞사람까지 1.2km"` (이름이 비면 `"순위가 4위 → 7위로 내려갔어요"`) · up: `"3위로 올라섰어요"` / `"골드 3위(상위 12%) · 뒷사람과 0.8km 차"` |
| **route** | `/home` — **주간 랭킹은 독립 라우트가 아니라 홈 화면 안**(티어 카드 아래)에 있다. `/ranking`은 이 앱에 존재한 적이 없다 |
| **클라** | 성취 계열 아님 → 포그라운드 배너 + "보기" → `/home` |
| **기준선** | `leaderboard_entries.notified_rank` / `notified_at`. **첫 사이클은 기준선만 잡고 발송하지 않는다**(notified_rank가 null이면 continue). 즉 **최소 2회 사이클**이 필요하다 |
| **수동 재현 (2계정)** | 1) Q-11로 같은 티어 `participant_count >= 10` 확보(§6.4) 2) `select public.refresh_leaderboards_and_notify();` 1회 → 기준선 세팅(Q-12로 `notified_rank` 채워짐 확인) 3) 계정 B로 **A를 3계단 이상 밀어낼 만큼**의 러닝을 업로드 4) `notified_at`이 6시간 이내면 발화하지 않으므로, `update public.leaderboard_entries set notified_at = now() - interval '7 hours' where user_id in (...);` 로 쿨다운을 앞당긴다 5) `select public.refresh_leaderboards_and_notify();` 재호출 |
| **기대** | A에게 down 1건(`"…에게 추월당했어요"`), B에게 up 1건(5계단 이상 또는 10/3/1위 진입 시). 반환값 = 발행 건수 |
| **실패 시** | ① 반환 0 → Q-11의 `participant_count`가 10 미만이 1순위 원인 ② Q-12에서 `notified_rank`가 null이면 아직 기준선 사이클 ③ `notified_at`이 6시간 이내면 쿨다운 ④ 순위 변동 폭이 3/5계단 미만이면 설계상 발화 없음 ⑤ 주 시작 후 24시간 이내(월요일 오전)면 전면 침묵 |

---

### NT-05 · 주말 막판 유도 (`weekend_push`)

| 항목 | 내용 |
|---|---|
| **트리거** | pg_cron **`runnit-weekend-push-sat`** `0 1 * * 6` = **토 KST 10:00**, **`runnit-weekend-push-sun`** `0 9 * * 0` = **일 KST 18:00** → `notify_weekend_push()` (`…_50_notification_routes.sql:370`) |
| **대상** | 최근 28일 내 완주 러닝이 있는 사용자 |
| **변형 A(추격)** | 순위 2위 이하 + 앞사람과의 격차 **≤ 5,000m**: `"앞사람까지 1.4km"` / `"골드 5위(상위 20%) · 오늘 1.4km면 한 칸 올라가요."` |
| **변형 C(방어, 일요일만)** | 1위 + 2위와의 격차 ≤ 5,000m: `"골드 1위, 마감까지 0.9km 차"` |
| **변형 B(미러닝, 일요일만)** | 이번 주 랭킹 엔트리가 없는 사용자: `"이번 주 기록이 아직 없어요"`. 상위% 문구는 **모집단 5명 이상**일 때만 붙는다 |
| **route / dedupe_key** | `/home` · `weekend_push:{week_id}:{sat|sun}` → **주당 최대 2건**(토 1 + 일 1) |
| **수동 재현** | 토/일이 아닌 날에는 `v_slot`이 null이라 즉시 0을 반환한다. 시각 인자를 넘겨 호출: `select public.notify_weekend_push('2026-09-06 18:00+09'::timestamptz);`(일요일). A/C는 격차 5km 안, B는 그 주 러닝 0건인 계정으로 각각 만든다 |
| **기대** | 계정별 변형에 맞는 1건. 같은 슬롯 재호출 시 dedupe로 0건 |
| **실패 시** | ① 반환 0 → 요일/시각 인자 확인 ② 격차 > 5km면 **의도적으로 보내지 않는다**(포기 신호 방지) ③ 최근 28일 러닝이 없으면 대상 밖 |
| **알려진 문서 불일치** | PRD §5.10 NT-05 예시 문구는 `"10위까지 2.1km"`인데 구현은 **격차 우선**(`"앞사람까지 …km"`)이다. PRD §5.4.1·RK-04의 "격차 우선, 절대순위·상위% 병기" 확정을 따른 것 — **PRD 갱신 대상**(TRD §14, backend §6.3-#5, ui §4-#6) |

---

### NT-06 · 뱃지 획득 · 레벨업 (PRD GM-04, `badge_level`)

**두 개의 발화 경로가 있고, 이 둘을 혼동하는 것이 이 종류의 유일한 함정이다.**

#### (a) 러닝 유래 — 뱃지 + 레벨업을 **묶어서 1건**

| 항목 | 내용 |
|---|---|
| **트리거** | `runs_04_notifications` → `trg_runs_notifications()` 후반부 (`…_50_…sql:80`) |
| **판정** | `user_badges` 중 `source_run_id = new.id` · `revoked=false` · `category <> 'season_tier'` 를 센다. 티어 승급 뱃지를 제외하는 이유: **NT-01이 같은 사건을 이미 알렸다** |
| **레벨 결합** | `profiles.level` 상승은 `profiles_02_level_notify`가 먼저 잡지만, 러닝 컨텍스트(`runnit.notify_run_id`)가 있으면 **발송하지 않고 GUC에만 남기고** 여기서 합친다 |
| **문구** | `"Lv.12 달성 · 뱃지 3개 획득"` / `"10K 러너 외 2개"`. 뱃지 1개면 `"10K 러너 획득!"` + 뱃지 설명 |
| **route / dedupe_key** | **`/history/run/{run_id}`** · `badge_level:run:{run_id}` → 한 러닝당 1건 |
| **클라** | **성취 계열 → 포그라운드 배너 없음.** 풀페이지 축하(`AchievementCelebrationHost`)만 뜬다. 딥링크는 **이동만 하고 축하를 띄우지 않는다** — 도착 화면에서 `user_badges.is_seen`이 false면 호스트가 알아서 띄운다 |
| **수동 재현** | 미획득 뱃지 조건을 만족하는 러닝을 업로드(예: 첫 10km). 뱃지 여러 개 + 레벨업이 동시에 터져도 **알림은 1건**이어야 한다 |
| **기대** | 알림 1건, route가 `/history/run/{uuid}`, 탭 시 러닝 상세로 착지 |
| **실패 시** | ① `user_badges`에 `source_run_id`가 채워졌는가(안 채워졌으면 **뱃지 평가** 문제) ② `category='season_tier'`만 붙은 경우는 설계상 NT-06 미발화(NT-01이 대신함) |

#### (b) 레벨 단독 — 러닝 없이 XP가 오른 경우 **최우선 검증 항목**

| 항목 | 내용 |
|---|---|
| **트리거** | `profiles` UPDATE OF `level` → 트리거 `profiles_02_level_notify` → `trg_level_up_notify()` (`…_50_…sql:36`) |
| **발화 경로** | 러닝 없이 total_xp가 오르는 실제 경로 — XP-3(뱃지 `verified`/`revoked` 변경), XP-4(`tier_change_history` INSERT) (TRD §3.8.4) |
| **문구** | `"Lv.13 달성"` / `"누적 4,200XP · 다음 레벨까지 300XP"` (만렙이면 `"만렙에 도달했어요."`) |
| **route / dedupe_key** | **`/history?tab=badges`** · `badge_level:level:{level}` |
| **⚠️ 왜 최우선인가** | **이 경로가 QA C-3에서 실제로 크래시하던 경로다.** 예전 서버는 `/profile/badges`를 보냈고, 클라이언트 화이트리스트가 접두사 매칭이라 통과시킨 뒤 go_router가 `no routes for location`으로 죽었다. 뱃지 갤러리는 독립 화면이 아니라 **활동 화면의 하위 탭**이다(2026-08-21 4탭 개편). `/history`만 보내면 기록 탭으로 열린다(크래시는 아님) |
| **수동 재현** | 러닝으로는 발화하지 않는다. 테스트 계정에 XP 경로를 직접 태운다 — 예: 해당 계정의 `user_badges` 한 행을 `revoked=true` ↔ `false`로 토글해 XP 재계산 → 레벨 상승을 유발한다. **레벨이 실제로 오르는 XP 폭**이어야 한다(`xp_level_thresholds()` 확인) |
| **기대** | 알림 1건, `payload->>'route' = '/history?tab=badges'`, 탭 시 **활동 화면의 뱃지 탭**으로 열리고 **크래시하지 않는다** |
| **실패 시** | ① `profiles.level`이 실제로 증가했는가 ② 러닝 트랜잭션 안에서 올렸다면 (a)로 묶여 별도 발화하지 않는 것이 정상 ③ 크래시하면 즉시 backend + ui 양쪽 호출(C-3 재발) |

---

### NT-07 · 포인트 (`points`) — **검증 대상 아님**

Phase 4. enum 라벨만 심어 두고 **발행 경로가 없다**(`notification_enabled()`가 항상 false를
반환하고 `notification_settings`에 컬럼도 없다). 라벨을 미리 심은 이유는 나중에 서버가 그 타입을
발행했을 때 구버전 앱의 `fromJson`이 예외를 던져 **알림함 전체가 깨지는 사고**를 막기 위해서다.
딥링크 폴백은 `/notifications`(알림함).

---

### NT-08 · 종류별 on/off 토글 — 화면 검증

| 항목 | 내용 |
|---|---|
| **화면** | `/notifications/settings` (`notification_settings_page.dart`) |
| **마스터 스위치 `push_enabled`** | **끄면 푸시만 멈추고 알림함 기록은 남는다.** `claim_push_batch()`가 `send_error='push_disabled'`로 큐에서 배출 |
| **종류별 토글** | 끄면 `enqueue_notification()`이 애초에 행을 만들지 않는다 → 알림함에도 안 남는다 |
| **행 부재 = 전 종류 on** | 가입 직후 행 생성 실패로 알림이 조용히 끊기는 쪽이 더 나쁘다는 판단 |
| **수동 재현** | ① `rank_change`만 끄고 §NT-04 재현 → `notifications`에 행이 **안 생겨야** 한다 ② 마스터만 끄고 아무 알림 발화 → 행은 생기고 `send_error='push_disabled'`로 배출되며 **알림함에는 보여야** 한다 |
| **⚠️ 알림함 목록을 설정으로 필터하지 말 것** | `NotificationSettings.isEnabled`는 `pushEnabled`가 꺼져 있으면 false를 돌려주는 **설정 화면용** 판정이다. 클라이언트가 한 번 더 거르면 마스터를 끈 사용자의 알림함이 통째로 비어 보인다 |

---

## 5. 실기기 검증 항목 8종 + 트리아지

§1을 전부 마친 뒤 순서대로 진행한다.

| # | 항목 | 확인 내용 | 관련 코드 |
|---|---|---|---|
| V-1 | **토큰 등록** | 로그인 + 권한 승인 후 `push_tokens`에 행이 생기는가(Q-9) | `push_token_sync.dart:71` → RPC `register_push_token` |
| V-2 | **포그라운드 배너**(NT-02/03/04/05) | 인앱 배너가 뜨고 탭/"보기"가 목적지로 가는가 | `push_messaging.dart:109`, `notification_banner_host.dart` |
| V-3 | **포그라운드 억제**(NT-01/06) | 성취 계열은 배너가 **뜨지 않고** 풀페이지 축하만 뜨는가. `data.type`이 실려야 동작(마이그레이션 49 + edge function `index.ts:152-159`) | `push_messaging.dart:114` |
| V-4 | **백그라운드 탭 → 딥링크** | 앱을 백그라운드로 보낸 뒤 트레이 알림 탭 → 목적지 화면 | `onMessageOpenedApp` |
| V-5 | **종료 상태 탭 → 딥링크(콜드스타트)** | 앱 강제 종료 후 트레이 알림 탭 → 첫 프레임 뒤 이동. **타이밍 확인 필요** | `getInitialMessage` + `addPostFrameCallback` (`push_messaging.dart:99-103`) |
| V-6 | **레벨 단독 → `/history?tab=badges`** | **C-3이 크래시하던 경로. 최우선.** §NT-06(b) | `notification_deep_link.dart:121` |
| V-7 | **뷰포트 읽음 처리** | 실기기 스크롤에서 화면 밖 항목이 읽음 처리되지 않는가 | `notification_inbox_page.dart` |
| V-8 | **로그아웃** | 이전 계정 알림이 오지 않는가(`push_tokens` 행 삭제 + FCM 토큰 폐기 이중 방어) | `push_token_sync.dart:109` |

### 5.1 트리아지 표 — 증상만으로는 클라/서버가 갈리지 않는다

Q-7을 돌리고 결과를 이 표에 대조한다.

| 서버 상태 | 해석 | 다음 행동 |
|---|---|---|
| `sent_at` 있고 `send_error` null | **서버는 FCM에 넘겼다** | 그 뒤(토큰·권한·네이티브 설정) 문제. V-1부터 다시 |
| `send_error = 'no_token'` | `push_tokens`에 행 없음 | 클라이언트 `PushTokenSync` 문제 — 권한 승인 여부, `isFirebaseAvailable` 확인 |
| `send_error = 'push_disabled'` | 마스터 스위치 off | 설정 화면 확인(정상 동작) |
| `send_error = 'expired'` | 24h 경과 또는 3회 실패 | 새 알림으로 재현. **§0의 기존 9건이 여기 해당** |
| `sent_at` null + `send_attempts` 증가 | FCM 호출 실패 중 | `send_error`에 HTTP 상태·응답 앞부분. 401/403이면 서비스 계정, 404/UNREGISTERED면 죽은 토큰 |
| **셋 다 비어 있음**(`sent_at` null · `send_attempts` 0 · `send_error` null) | **디스패처가 아예 돌지 않았다** | Q-2로 **단정**할 것. Vault 시크릿 부재면 no-op이라 실패 흔적조차 없다. 그다음 Q-1(Edge Function 배포) |
| `send_attempts`가 0에서 안 움직이는데 재시도 반복 | **C-1 재발**(가드 트리거가 쓰기를 되돌림) | 즉시 backend-engineer 호출. 마이그레이션 49의 `_server_write_enter/exit` 구간이 깨진 것 |

---

## 6. 알려진 리스크 · 엣지케이스

### 6.1 이미 쌓인 9건은 발송 설정 직후 `expired`로 배출된다

§0-3 참조. **정상 동작이다.** 검증은 반드시 **새로 만든 알림**으로 한다.

### 6.2 앱 종료 상태 수신 / 백그라운드 격리

- 서버는 `notification` 블록을 실어 보내므로 **앱이 죽어 있어도 OS가 트레이에 그린다.**
  `runnitFirebaseBackgroundHandler`는 **아무것도 하지 않는 것이 정상**이다
  (`push_messaging.dart:24`) — 이 격리에는 Riverpod 컨테이너도 Supabase 세션도 없다.
- 그럼에도 **핸들러 등록은 필요**하다. 등록하지 않으면 일부 Android 기기에서 data-only
  메시지가 조용히 버려진다.
- 알림함은 앱이 열릴 때 다시 읽으므로 백그라운드에서 갱신할 이유가 없다.

### 6.3 딥링크 콜드스타트 타이밍

`getInitialMessage()`의 이동은 `addPostFrameCallback`으로 첫 프레임 뒤로 미뤄져 있다.
라우터가 준비되기 전에 `go()`를 부르면 이동이 유실되기 때문이다.
**리스크**: 콜드스타트가 느린 기기에서 스플래시/인증 리다이렉트와 경합할 수 있다.
V-5에서 **저사양 기기 + 로그아웃 상태 + 로그인 필요 목적지** 조합을 반드시 한 번 본다.
`navigateTo()`는 실패해도 예외를 삼키고 로그만 남기므로(`push_messaging.dart:142`)
**증상이 "아무 일도 안 일어남"으로 나타난다** — 실패를 눈으로 볼 수 없다는 점을 기억할 것.

### 6.4 NT-04 / NT-05가 현재 시드로는 절대 발화하지 않는다

`participant_count` 최대 4 < 게이트 10(NT-04) · 5(NT-05 백분율).
**게이트를 낮추는 것은 답이 아니다** — 참가자 한 자리 수에서 "3계단 하락"은 곧 꼴찌 통보다.
선택지는 둘 중 하나:
1. 같은 티어에 시드 계정 10개 이상을 만들어 주간 러닝을 넣는다(권장 — 실제 판정 경로를 탄다)
2. 베타 사용자 20명 이상 확보 후 재검증(TRD §14-#12·backend §6.3-#3과 동일 제약)

### 6.5 토큰 갱신 · 기기 이관

- `onTokenRefresh` → 같은 `device_id`의 옛 토큰은 서버 RPC가 정리한다.
- 재설치·데이터 삭제로 토큰은 **조용히** 만료된다. **유일한 정리 시점은 FCM이
  `UNREGISTERED`/`INVALID_ARGUMENT`를 돌려주는 순간**(`prune_push_token`).
  클라이언트는 이 사실을 알 수 없고 다음 실행의 `onTokenRefresh`로 자연 복구된다.
- 로그아웃 시 서버 행 삭제가 RLS로 실패할 수 있어(세션이 이미 끊김)
  `FirebaseMessaging.deleteToken()`이 두 번째 방어선이다 — **기기를 넘겨받은 사람에게
  이전 사용자의 순위·티어 알림이 가는 사고**를 막는다. V-8에서 반드시 확인.

### 6.6 배치 중복 발송 방지가 실제로 작동하는지

- 방어선은 **`unique (user_id, dedupe_key)` 하나뿐**이다. 애플리케이션 레벨 count 체크는
  pg_cron 재실행 경합에서 새어 나간다.
- **검증법**: 같은 배치 함수를 연속 2회 호출해 **두 번째 반환값이 0**인지 본다(Q-15).
  NT-04만은 예외 — 순번 n이 키에 들어가므로 조건이 다시 성립하면 상한(주 4건)까지는
  새 키로 발행된다. 상한 초과분이 안 나가는지를 Q-7의 `dedupe_key` 목록으로 확인한다.
- **발송 측 중복**: `mark_push_result`가 `sent_at`을 못 쓰면 같은 푸시가 **매분 무한 반복**된다.
  이것이 C-1이었고 마이그레이션 49로 고쳤다. 재발 신호는 §5.1 마지막 행.
- 한 기기라도 성공하면 발송 성공으로 본다 — 죽은 토큰 때문에 살아 있는 기기에
  재발송하면 그쪽이 중복 알림을 받는다(`index.ts:203`).

### 6.7 방해 금지 시간

배치 계열(NT-03/04/05)만 KST 08:00~21:59로 제한된다(`_batch_hours_ok`).
트리거 계열(NT-01/02/06)은 **방금 러닝을 끝낸 순간**이라 심야 예외다 — 새벽 러닝 후
02:00에 뱃지 알림이 오는 것은 **버그가 아니다.** 사용자별 방해 금지 설정은 PRD에 없다.

### 6.8 Android 트레이 아이콘 · 알림 채널 미설정

기본 채널/기본 아이콘 meta-data를 넣지 않았다. 서버가 `notification` 블록을 보내므로
동작은 하지만 **상태바 아이콘이 흰 사각형으로 보일 수 있다.** V-4에서 눈으로 확인하고,
문제가 되면 흑백 실루엣 drawable + `com.google.firebase.messaging.default_notification_icon`
manifest 추가(ui §4-#3).

### 6.9 `app_version`이 항상 null

`package_info_plus`를 이 필드 하나 때문에 추가하지 않았다. "특정 버전에서만 알림이
안 온다"를 추적해야 하는 시점에 도입(ui §4-#4).

---

## 7. 차단 항목 요약 — 이것부터

| 순서 | 항목 | 담당 | 현재 |
|---|---|---|---|
| 1 | `supabase functions deploy push-dispatch` | 운영/backend | ❌ 미배포(원격 함수 0개) |
| 2 | `supabase secrets set FCM_SERVICE_ACCOUNT=…` | 운영 | ❌ |
| 3 | Vault 시크릿 2개(Q-2가 2행) | 운영/backend | ❌ 0행 |
| 4 | `google-services.json` / `GoogleService-Info.plist` + Gradle 플러그인 + APNs 키 | 운영/앱 | ❌ 둘 다 없음 |
| 5 | 실기기 2대 + 테스트 계정 uid 2개 | QA | — |
| 6 | 같은 티어 참가자 10명 이상 시드(NT-04용) | backend | ❌ 최대 4 |

1~4가 전부 끝나기 전에는 §5의 V-1~V-8이 모두 "안 옴"으로만 보이고 원인을 가릴 수 없다.
반면 **§4의 알림함 적재 검증(푸시 없이 `notifications` 행과 인앱 알림함만 보는 것)은
지금 당장 가능하다** — 테스트 계정 uid만 있으면 된다.
