# 알림 시스템(NT-01~08) 데이터 모델 · 앱 구조 · 상태관리 설계

- 작성: mobile-architect / 2026-08-28
- 근거: PRD §5.10(NT-01~08) · §4.2 · §5.3 · §5.4 · §8.2 · §8.5, ARCHITECTURE §7.3 · §7.4 · §7.4.1 · §12-#6, TRD §2 · §6.4 · §14-#12
- 산출물: `lib/models/app_notification.dart` · `notification_settings.dart` · `push_device_token.dart`,
  `lib/models/enums.dart`(`NotificationType`/`DevicePlatform` 추가), `lib/core/api/wire_enums.dart`,
  `lib/core/repositories/notification_repository.dart`, TRD §3.10 · §4.1-N

---

## 0. 이 설계를 지배하는 한 문장

**조건 판정과 문구 작성은 전부 서버, 클라이언트는 수신·표시·설정만 한다.**

티어는 동기 트리거, 랭킹은 배치라는 기존 분리(ARCHITECTURE §7.3)가 알림에도 그대로 적용된다.
클라이언트가 "지금이 승급 알림 시점인가"를 계산하면 서버 확정값과 어긋난 알림이 생기고,
그 순간 티어·랭킹이라는 이 앱의 화폐가 신뢰를 잃는다.

| 알림 | 발행 주체 | 발행 시점 |
|---|---|---|
| NT-01 티어 승급 | `runs` AFTER 트리거 (동기) | `user_badges`(`stier_*`) INSERT와 같은 트랜잭션 |
| NT-02 다음 티어 근접 | `runs` AFTER 트리거 (동기) | 러닝 저장 후 잔여 거리가 임계치 이하로 내려간 순간 |
| NT-03 시즌 D-14 / D-3 | pg_cron (일 1회) | 시즌 종료 14일·3일 전 KST 오전 |
| NT-04 순위 추월·추월당함 | pg_cron (랭킹 확정 배치 직후) | `leaderboard_entries` rank 갱신 시 이전 rank와 비교 |
| NT-05 주말 막판 유도 | pg_cron (금·토·일) | 목표 순위까지의 격차가 유의미한 사용자만 |
| NT-06 뱃지 획득·레벨업 | `user_badges` / `profiles.level` 트리거 | 획득과 같은 트랜잭션 |
| NT-07 포인트 | — | **Phase 4. 구현하지 않는다** |

⚠️ NT-04는 **배치 산물**이다. 랭킹은 실시간이 아니라 캐시 갱신 배치가 rank를 확정하므로
(TRD §14-#12), "업로드 즉시 추월 알림"은 구조적으로 불가능하다. 배치 주기가 곧 알림
지연이며, 이 지연을 줄이려고 클라이언트가 rank를 계산하는 우회는 금지한다.

⚠️ 크루/그룹 알림(PRD §5.9, P2)은 이 설계 범위 밖이다. `RankingScope.crew`가 enum에
있어도 알림은 티어 내 개인 순위만 다룬다.

---

## 1. 데이터 모델

### 1.1 `NotificationType` — 값 하나 = PRD 요구사항 ID 하나

```
tier_promotion(NT-01) / tier_proximity(NT-02) / season_ending(NT-03)
rank_change(NT-04) / weekend_push(NT-05) / badge_level(NT-06)
points(NT-07 — Phase 4, 미발행 · 설정 미노출)
```

**요구사항보다 잘게 쪼개지 않았다.** NT-04를 `rankOvertook`/`rankOvertaken` 둘로 나누는
안을 검토했으나 채택하지 않았다:

1. NT-08 토글이 PRD 표와 1:1로 대응하지 않게 된다 ("항목별 on/off"의 항목이 흐려진다)
2. 딥링크 목적지가 같다(둘 다 주간 랭킹)
3. **문구는 서버가 완성해서 내려주므로** 클라이언트가 방향을 알 필요가 없다

방향·D-day·잔여 거리 같은 뉘앙스는 전부 `payload`에 담는다.

`points`를 enum에 **자리만 남긴 이유**: Phase 4에 서버가 그 타입을 발행했을 때 구버전
앱의 `fromJson`이 예외를 던져 **알림함 전체가 깨지는** 사고를 막기 위해서다. 설정
화면에는 `NotificationTypeX.isMvp`로 걸러 노출하지 않는다.

`NotificationTypeX.isAchievement`(tierPromotion·badgeLevel) — 인앱 축하와 역할이 겹치는
종류를 식별하는 유일한 기준이다. §3.4 참조.

### 1.2 `AppNotification` — 알림함이자 발송 로그

| 필드 | 설명 |
|---|---|
| `id` / `userId` / `type` | |
| `title` / `body` | **서버가 완성한 문구.** 푸시 트레이에 뜬 것과 동일 |
| `payload` (jsonb) | 딥링크(`route`)와 부가 표시값. 미지 키 무시 |
| `createdAt` | 정렬 기준(최신 우선) |
| `readAt` | null이면 미읽음. **클라이언트가 쓸 수 있는 유일한 컬럼** |

- 이름이 `Notification`이 아닌 이유: Flutter 프레임워크에 동명 위젯 클래스가 있다.
- **테이블을 "발송 로그"와 "알림함"으로 나누지 않는다.** 나누면 "푸시는 갔는데 알림함에
  없다"는 상태가 생기고 어느 쪽이 진실인지 판단할 근거가 사라진다. 알림 권한을 끈
  사용자도 앱에 들어오면 놓친 알림을 여기서 본다 — 이게 인박스를 만드는 진짜 이유다.
- 문구를 클라이언트가 payload로 조립하지 않는다. 조립하면 트레이 문구(서버)와 알림함
  문구(클라이언트)가 갈라져 같은 사건이 두 가지로 보인다.

**payload 규약 키** (서버가 채움 / 클라이언트 읽기 전용):

| 키 | 타입 | 쓰는 종류 |
|---|---|---|
| `route` | string | 전 종류 — 탭 시 이동할 앱 경로 |
| `tier` | string | tierPromotion / tierProximity |
| `remaining_m` | number | tierProximity / weekendPush |
| `season_id` | string | seasonEnding (`2026-Q3`) |
| `days_left` | number | seasonEnding (14 / 3) |
| `direction` | string | rankChange (`up` / `down`) |
| `rank` | number | rankChange / weekendPush |
| `user_badge_id` | string | tierPromotion / badgeLevel — **참조용. 이 값으로 축하를 띄우지 않는다**(§3.4) |

### 1.3 `NotificationSettings` (NT-08) — 기본값 전부 on

**필드를 하나씩 두고 jsonb 한 컬럼으로 접지 않았다.** 발송 주체가 pg_cron이라
`join notification_settings s ... where s.weekend_push`처럼 SQL 한 번으로 수신 거부자를
걸러내야 하기 때문이다. UI는 `isEnabled(type)` / `withType(type, value)` /
`configurableTypes`로 제네릭하게 순회하므로 토글을 하드코딩하지 않는다.

**기본값 전부 on을 권장한다(확정 제안).** 이 앱의 알림은 광고가 아니라 **제품의 핵심 루프
그 자체**다 — "0.8km만 더 뛰면 앞사람을 제친다"(PRD §5.4.1), "시즌 D-3"(TI-07)는 알림이
없으면 존재하지 않는 기능이다. 기본 off면 대다수 사용자에게 이중 경쟁 루프(PRD §4.2)가
작동하지 않는다. 대신:

- **OS 권한 요청 시점을 미룬다** — 첫 실행이 아니라 **첫 러닝 완료 직후**(성취 직후가
  수락률이 가장 높고, 그 시점에 "다음 알림이 왜 필요한지"를 사용자가 이미 안다)
- 끄는 경로를 프로필에서 1탭 거리에 둔다
- 마스터 스위치 `pushEnabled`를 별도로 둔다 — OS 설정까지 가지 않고 앱 안에서 전부 끌 수
  있어야 "설정에서 앱 알림 자체를 꺼버리는"(되돌리기 어려운) 이탈을 줄인다
- 종류별 토글은 마스터가 꺼져도 **값을 기억한다**(`rawFlag`) — 다시 켰을 때 원래 상태로

**행이 없으면 전 종류 on으로 간주**한다(서버·클라이언트 공통). 가입 직후 행 생성 실패로
알림이 조용히 끊기는 쪽이, 기본값을 한 번 더 보내는 것보다 나쁘다.

**부분 갱신 원칙**: 토글 하나를 바꿀 때 행 전체를 덮어쓰지 않는다. 폰·태블릿 두 기기가
같은 화면을 열고 있으면 lost update가 난다. `columnOf(type)`이 갱신할 컬럼 하나를 준다.

### 1.4 `PushDeviceToken`

- **PK는 `token`, 유저당 여러 행이 정상**이다. `user_id`를 PK로 잡으면 두 번째 기기가
  첫 번째를 밀어내고 "이 폰에서는 오는데 저 폰에서는 안 온다"가 된다.
- 토큰은 재설치·데이터 삭제·장기 미사용으로 조용히 만료된다. 발송 시
  `UNREGISTERED`/`INVALID_ARGUMENT`가 오면 **서버가 행을 지운다** — 유일한 정리 경로다.
- `deviceId`(설치 단위 식별자)는 같은 기기의 옛 토큰을 정리하는 근거. 못 얻으면 null.
- **로그아웃 시 반드시 삭제한다.** 남기면 기기를 넘겨받은 다음 사용자에게 이전 사용자의
  순위·티어 알림이 간다. 실패해도 로그아웃 자체를 막지 않는다.

---

## 2. 모듈 구조

```
lib/core/
  notifications/                      # 앱 수명주기·SDK 경계 (feature 아님)
    push_messaging.dart               # FCM 초기화, 권한 요청, 포그라운드/백그라운드 핸들러
    push_token_sync.dart              # 인증 상태 ↔ 토큰 upsert/delete 라이프사이클
    notification_deep_link.dart       # payload['route'] → Routes 해석 (core/router 의존)
  repositories/
    notification_repository.dart      # ✅ 생성 완료 — 조회/갱신 계약(인터페이스)

lib/features/notifications/
  data/
    supabase_notification_repository.dart   # backend-engineer 담당
    notification_providers.dart             # 설정·인박스·미읽음 Provider
  domain/
    notification_display.dart               # 종류별 아이콘/라벨/그룹핑 (순수 함수)
  presentation/
    notification_inbox_page.dart            # 알림함
    notification_settings_page.dart         # NT-08 토글 화면
    widgets/notification_tile.dart
    widgets/unread_badge.dart               # 탭/헤더 미읽음 배지
```

### core vs feature 경계 기준

**core에 두는 것 = 앱이 살아 있는 동안 하나만 존재해야 하고, 화면과 무관하게 동작해야
하는 것.**

| 관심사 | 위치 | 근거 |
|---|---|---|
| FCM 초기화·권한 요청 | `core/notifications` | 앱 1회. 어떤 화면이 떠 있든 무관 |
| 포그라운드 메시지 핸들러 | `core/notifications` | 알림함 화면이 열려 있지 않아도 동작해야 한다 |
| 토큰 동기화 | `core/notifications` | 인증(`core/auth`) 수명주기에 붙는다. feature가 소유하면 알림 화면에 한 번도 안 들어간 사용자는 토큰이 등록되지 않는다 |
| 딥링크 → 라우트 | `core/notifications` | `core/router`의 `Routes`에 의존. feature가 라우터를 알면 의존 방향이 뒤집힌다 |
| 리포지토리 **인터페이스** | `core/repositories` | 기존 규약(gamification/ranking/user 동일) |
| 리포지토리 **구현** | `features/notifications/data` | 기존 규약 |
| 알림함·설정 화면, 표시 로직 | `features/notifications/presentation`·`domain` | 화면 관심사 |

`core/map`(SDK 경계 주입점)과 같은 패턴이다 — SDK를 만지는 얇은 층은 core, 그 위에
그리는 화면은 feature.

### 라우트 추가

```dart
static const notifications = '/notifications';          // 알림함 (셸 안, 게스트 차단)
static const notificationSettings = '/notifications/settings';
```

`profile_page.dart`의 "알림 설정" 자리표시자(현재 `설정 화면은 준비 중이에요` 스낵바)와
헤더 종 아이콘이 이 두 라우트의 진입점이 된다.

---

## 3. 상태관리 (Riverpod, 수동 선언)

### 3.1 알림 설정

```dart
final notificationSettingsProvider =
    AsyncNotifierProvider<NotificationSettingsController, NotificationSettings>(...);
```

- 로그인 사용자의 설정 1행. 조회 결과가 없으면 `NotificationSettings.defaultsFor(userId)`.
- 토글은 **낙관적 갱신 + 실패 롤백**. 스위치가 네트워크 왕복만큼 굳어 있으면 사용자는
  두 번 누르고, 두 번째 요청이 첫 번째를 되돌린다.
- 갱신은 `updateSetting(type, enabled)` — 컬럼 하나만 보낸다(§1.3).
- 로그아웃 시 자동 폐기(`currentUserIdProvider` watch).

### 3.2 알림함

```dart
final notificationInboxProvider =
    AsyncNotifierProvider<NotificationInboxController, List<AppNotification>>(...);
```

- **커서 페이지네이션**(`before: 마지막 항목의 createdAt`). offset은 조회 중 새 알림이
  도착하면 밀려서 같은 항목이 두 번 보인다.
- realtime INSERT는 **재조회 신호로만** 쓴다(`watchIncoming` → `ref.invalidateSelf()`).
  스트림이 밀어준 행을 목록에 직접 붙이면 앱이 백그라운드였던 구간의 누락분과 어긋난다.
  기존 `core/api/realtime_refetch.dart` 패턴을 그대로 쓴다.
- 읽음 처리는 **화면에 실제로 보인 항목**(뷰포트 진입) 기준. 목록 진입 즉시 전체 읽음
  처리하면 미읽음이라는 신호 자체가 죽는다. "모두 읽음"은 명시 액션으로 별도 제공.

### 3.3 미읽음 배지

```dart
final unreadNotificationCountProvider = ...  // 서버 count(head: true, exact)
```

- **목록을 받아 세지 않는다.** 배지 하나 때문에 전체 payload를 내려받게 되고, 알림이
  쌓일수록 비용이 선형으로 는다. `read_at is null` 부분 인덱스 + head count.
- 갱신 트리거: ① realtime INSERT ② `markRead`/`markAllRead` 직후 ③ 앱 포그라운드 복귀.
- 게스트는 항상 0.

### 3.4 FCM 토큰 라이프사이클

`core/notifications/push_token_sync.dart` — 인증 상태를 `listen`하는 Provider 하나가
소유한다. 화면이 아니라 앱 수명주기에 붙는다.

| 사건 | 동작 |
|---|---|
| 로그인 완료 | 권한 상태 확인 → `getToken()` → `upsertToken` |
| 토큰 갱신 (`onTokenRefresh`) | 새 토큰 `upsertToken` (같은 `deviceId`의 옛 토큰은 서버가 정리) |
| 로그아웃 | `deleteToken(현재 토큰)` → `FirebaseMessaging.deleteToken()`. 실패해도 로그아웃 진행 |
| 계정 전환 | 로그아웃 경로가 먼저 지우므로 새 토큰은 항상 새 `user_id`로 등록된다 |
| 권한 거부 | 토큰 등록을 시도하지 않는다. 인박스와 설정 화면은 그대로 동작(권한 없이도 알림 기록은 쌓인다) |

권한 요청 시점: **첫 러닝 완료 직후**(§1.3). 첫 실행 다이얼로그는 거부율이 높고, 한 번
거부되면 앱이 되돌릴 수 없다.

---

## 4. 기존 성취 큐(`user_badges` + `AchievementCelebrationHost`)와의 공존

**핵심: 역할을 겹치게 두지 않는다.**

| | 담당 | 소스 | 언제 |
|---|---|---|---|
| **인앱 축하 연출** | `AchievementCelebrationHost` (기존, 변경 없음) | `user_badges` 미확인 큐 | 앱을 쓰고 있을 때 |
| **푸시 알림** | FCM (신규) | `notifications` 행 | 앱이 백그라운드/종료일 때의 **재방문 유도** |
| **알림함 기록** | `notifications` (신규) | 전 종류 | 항상 — 놓친 알림의 열람 경로 |

### 4.1 소비 지점은 여전히 하나다 (ARCHITECTURE §7.4.1 유지)

성취 축하의 유일한 소비 지점은 `achievement_celebration.dart`의
`AchievementCelebrationHost`이며, **알림 모듈은 이 큐를 건드리지 않는다.**

- 푸시 payload에 `user_badge_id`가 실려 있어도 **클라이언트는 그것으로 축하를 띄우지
  않는다.** 띄우면 소비 지점이 둘이 되고, §7.4.1이 폐기한 "두 소비 지점 + 억제 카운터"
  구조가 다른 이름으로 부활한다.
- 푸시를 탭하면 딥링크로 **이동만** 한다. 그 시점에 `user_badges` 행이 아직
  `is_seen = false`면 호스트가 알아서 축하를 띄운다 — 별도 트리거가 필요 없다.
- 이미 축하를 본 성취의 푸시를 나중에 탭해도 큐가 비어 있으므로 아무 일도 안 일어난다.
  이것이 정상 동작이다(축하는 한 번뿐).

### 4.2 포그라운드 중복 방지 규칙

앱이 포그라운드일 때 FCM 메시지를 받으면:

| 종류 | 인앱 배너 |
|---|---|
| `isAchievement` == true (NT-01 · NT-06) | **띄우지 않는다.** 몇 초 뒤 축하 풀페이지가 뜬다 — 배너와 풀페이지가 같은 사건을 두 번 알린다 |
| 그 외 (NT-02 · 03 · 04 · 05) | 인앱 배너/스낵 허용. 대응하는 인앱 연출이 없다 |

모든 종류는 **인앱 배너 표시 여부와 무관하게 알림함에는 남는다.**

### 4.3 왜 성취도 푸시로 보내는가

축하 호스트만으로 충분해 보이지만, 호스트는 **앱을 열어야** 동작한다. NT-01/NT-06의
목적은 축하가 아니라 **재방문**이다 — 오프라인 러닝이 며칠 뒤 동기화되며 뱃지가 터진
경우, 푸시가 없으면 사용자는 그 사실을 영영 모른다. 축하(인앱) / 재방문 유도(푸시) /
열람 기록(인박스) 세 역할이 각각 다른 결핍을 메운다.

---

## 5. backend-engineer 인계 — 스키마 계약

TRD **§3.10 · §4.1-N**에 매핑표를 확정 반영했다. 요약:

| 테이블 | PK | 클라이언트 쓰기 | RLS |
|---|---|---|---|
| `notifications` | `id uuid` | **`read_at`만** | select 본인 행 / update는 `read_at` 컬럼 한정(가드 트리거) / insert는 서버(SECURITY DEFINER·service role) |
| `notification_settings` | `user_id` | 종류별 bool + `push_enabled` | select·insert·update 본인 행 |
| `push_tokens` | `token` | upsert/delete 본인 행 | select·insert·update·delete 본인 행 |

**꼭 지켜야 할 것:**

1. **`notifications.dedupe_key` + `unique (user_id, dedupe_key)`** — 멱등성의 유일한
   방어선. pg_cron 재실행·트리거 중복 발화로 같은 알림이 두 번 가는 사고는 반드시
   일어나며, 애플리케이션 레벨 체크로는 경합에서 새어 나간다.
   키 규약 제안: `{type}:{scope}` — `season_ending:2026-Q3:d3`,
   `rank_change:2026-W35:down`, `tier_promotion:2026-Q3:gold`,
   `badge_level:{user_badge_id}`, `weekend_push:2026-W35`.
2. **인덱스**: `(user_id, created_at desc)` — 알림함 정렬,
   `(user_id) where read_at is null` — 미읽음 count.
3. **`notifications`를 realtime publication에 추가.** 미읽음 배지가 앱을 껐다 켜야만
   갱신되면 배지의 의미가 없다.
4. **enum 타입 3계층 일치**: `public.notification_type` 라벨 =
   `lib/models/enums.dart`의 `@JsonValue` = `wire_enums.dart`의 `wire`.
   어긋나면 조회가 **에러 없이 빈 결과**를 돌려준다(기존 경고와 같은 실패 양상).
   `points` 라벨은 Postgres enum에 **포함시키되 발행하지 않는다**(Phase 4).
5. **`notification_settings`에 `points` 컬럼을 만들지 않는다** — 적립 규칙이 미정이라
   지금 만든 토글은 아무것도 제어하지 못하고 "동작하지 않는 스위치"만 남는다.
6. **발송 필터는 SQL 한 번으로**:
   `where s.push_enabled and s.weekend_push` (행이 없으면 on이므로 `left join` +
   `coalesce(s.weekend_push, true)`).
7. **토큰 무효 처리**: FCM이 `UNREGISTERED`/`INVALID_ARGUMENT`를 주면 그 `push_tokens`
   행을 삭제한다. 클라이언트는 이 사실을 알 수 없고 다음 실행에서 자연 복구된다.
8. **pg_cron 배치**: NT-03(일 1회, 시즌 D-14/D-3 — TRD §6.4 시즌 경계 배치와 별도 스케줄),
   NT-04(랭킹 확정 배치 **직후** 체이닝 — 별도 주기로 돌리면 rank 스냅샷이 어긋난다),
   NT-05(금·토·일). 전부 **KST 기준**이며 시즌·주간 경계는 PRD §8.5를 따른다.
9. **NT-02 임계치**는 서버가 소유한다. 제안: 다음 티어까지 **5km 이하**로 내려간 최초 1회
   (`dedupe_key = tier_proximity:{seasonId}:{nextTier}`). 한 시즌·한 티어당 한 번만.

---

## 6. gamification-designer 인계

- **NT-02 임계치·문구 정책**과 **NT-05 목표 순위 기준**(예: "10위까지" — 상위 N위인가
  바로 위 사용자인가)이 아직 미정이다. PRD §5.4.1이 "격차 우선"을 확정했으므로 NT-05는
  **바로 위 사용자와의 격차**를 우선 문구로 쓰는 것을 권장한다 — "10위까지 2.1km"는
  브론즈 3,000명 중 2,847위 사용자에게 도달 불가능한 목표로 읽힌다.
- NT-06의 레벨업 알림은 `profiles.level` 변화가 트리거다. 뱃지와 달리 `user_badges` 행이
  생기지 않으므로 **인앱 축하 호스트가 잡지 못한다** — 레벨업 축하를 인앱에서도 하려면
  별도 경로가 필요하다(현재 범위 밖, 결정 필요).

## 7. flutter-ui-designer 인계

- 화면 2개: 알림함(`/notifications`), 알림 설정(`/notifications/settings`).
  진입점은 `profile_page.dart`의 "알림 설정" 항목(현재 준비 중 스낵바)과 헤더 종 아이콘.
- 설정 화면은 `NotificationSettings.configurableTypes`를 순회해 그린다 — 토글을 하나씩
  하드코딩하면 종류가 늘 때마다 화면을 고쳐야 한다. NT-07은 자동으로 빠진다.
- 마스터 스위치가 꺼지면 개별 토글은 **비활성화하되 값은 그대로 보여준다**(`rawFlag`).
- 미읽음 배지는 `unreadNotificationCountProvider` 하나만 구독한다. 99+ 처리 필요.
- 빈 상태: "아직 받은 알림이 없어요" — 알림은 러닝을 해야 생기므로 첫 러닝 유도로 잇는다.
- 읽음 처리는 뷰포트 진입 기준(§3.2). 목록 진입 즉시 전체 읽음은 금지.

---

## 8. `docs/ARCHITECTURE.md` 추가 § 초안

> 아래를 §7.4.1 다음, §8(부정행위 방지) 앞에 넣는다. 폴더 구조(§3.1)의
> `# notifications/ ... 아직 없음` 주석과 §12-#6, §13은 구현 착수 시 함께 갱신한다.

```markdown
### 7.5 알림 모듈 (NT-01~08) — 2026-08-28

#### 7.5.1 판정은 서버, 클라이언트는 수신·표시·설정만

알림 조건은 전부 서버가 판정한다 — 티어·성취 계열(NT-01/02/06)은 `runs`·`user_badges`
**트리거**(동기), 랭킹·시즌 계열(NT-03/04/05)은 **pg_cron 배치**다. §7.3의 "티어=동기 /
랭킹=배치" 분리가 알림에도 그대로 적용된다.

클라이언트가 "지금이 승급 알림 시점인가"를 계산하면 서버 확정값과 어긋난 알림이 생기고,
그 순간 티어·랭킹이라는 이 앱의 화폐가 신뢰를 잃는다. 그래서
`NotificationRepository`에는 **알림을 만드는 메서드가 없다** — 쓰기는 읽음 표시 /
설정 토글 / 토큰 등록·해제 셋뿐이다.

⚠️ NT-04(순위 추월)는 배치 산물이다. rank는 캐시 갱신 배치가 확정하므로(TRD §14-#12)
"업로드 즉시 추월 알림"은 구조적으로 불가능하다. 배치 주기가 곧 알림 지연이다.

#### 7.5.2 성취 알림의 3역할 분리 — 큐 공존 원칙

성취(NT-01 티어 승급 / NT-06 뱃지·레벨업)는 인앱 축하와 푸시가 겹칠 수 있다.
**역할을 나눠 겹치지 않게 한다.**

| 수단 | 담당 | 소스 | 언제 |
|---|---|---|---|
| 인앱 축하 연출 | `AchievementCelebrationHost` (§7.4.1, 변경 없음) | `user_badges` 미확인 큐 | 앱을 쓰고 있을 때 |
| 푸시 알림 | FCM | `notifications` 행 | 앱이 백그라운드/종료일 때의 재방문 유도 |
| 알림함 | `notifications` 목록 | 전 종류 | 항상 — 놓친 알림 열람 |

**소비 지점은 여전히 하나다.** 알림 모듈은 `user_badges` 큐를 건드리지 않는다. 푸시
payload에 `user_badge_id`가 실려 있어도 클라이언트는 그것으로 축하를 띄우지 않는다 —
띄우면 소비 지점이 둘이 되어, §7.4.1이 폐기한 "두 소비 지점 + 억제 카운터" 구조가 다른
이름으로 부활한다. 푸시를 탭하면 **딥링크로 이동만** 하고, 큐가 `is_seen = false`면
호스트가 알아서 축하한다.

포그라운드 수신 시 성취 계열(`NotificationTypeX.isAchievement`)은 인앱 배너를 띄우지
않는다 — 몇 초 뒤 축하 풀페이지가 뜨므로 같은 사건을 두 번 알리게 된다. NT-02/03/04/05는
대응하는 인앱 연출이 없으므로 배너를 띄운다. 배너 여부와 무관하게 **모든 종류가 알림함에
남는다.**

축하 호스트만으로 충분해 보이지만 호스트는 앱을 열어야 동작한다. 오프라인 러닝이 며칠 뒤
동기화되며 뱃지가 터진 경우, 푸시가 없으면 사용자는 그 사실을 영영 모른다.

#### 7.5.3 core / feature 경계

`core/notifications/`에는 **앱 수명주기에 붙는 것**만 둔다 — FCM 초기화·권한 요청,
포그라운드 핸들러, 토큰 동기화(`core/auth` 수명주기 구독), 딥링크 해석(`core/router`
의존). 알림함·설정 화면과 표시 로직은 `features/notifications/`다.
`core/map`(SDK 경계 주입점)과 같은 패턴이다.

토큰 동기화를 feature가 소유하면, 알림 화면에 한 번도 들어가지 않은 사용자는 토큰이
등록되지 않아 **푸시를 영영 못 받는다.**
```

---

## 9. 남은 결정 사항

| # | 항목 | 필요한 결정 |
|---|---|---|
| 1 | NT-02 임계치 | "다음 티어까지 5km" 제안 — gamification-designer 확정 필요 |
| 2 | NT-05 목표 기준 | "10위까지"(절대) vs "바로 위 사용자까지"(격차). PRD §5.4.1 근거로 후자 권장 |
| 3 | 레벨업 인앱 축하 | `profiles.level` 변화는 `user_badges` 큐에 안 잡힌다. 인앱 축하까지 할지 |
| 4 | 방해 금지 시간 | PRD에 없음. 배치가 KST 오전에 도는 한 당장 문제는 없으나 NT-04는 랭킹 배치 시각에 종속 |
| 5 | FCM 도입 | `firebase_messaging` / `firebase_core` 의존성 추가는 아직. ARCHITECTURE §12-#6 · TRD §2 갱신 필요 |
