# 알림 시스템(NT-01~08) 클라이언트 구현 — 화면 + FCM 연동

- 작성: flutter-ui-designer / 2026-08-28
- 정본 입력: PRD §5.10(NT-01~08)·§5.4.1, `_workspace/20260828_164428_architect_notifications.md`,
  `_workspace/20260828_193000_backend_notifications.md`,
  `_workspace/20260828_181500_gamification_notification-rules.md`
- 검증: `flutter analyze` 무결(lib + test), `flutter test` **208개 전량 통과**(알림 관련 33개 신규)
- 2026-08-28 QA CONFIRMED 결함 2건(C-3 딥링크 · C-2 클라이언트 측) 수정 반영본

---

## 0. 한 문단 요약

**클라이언트는 판정하지 않는다.** 서버가 완성해 내려준 `title`/`body`를 그대로 렌더하고,
`payload['route']`는 화이트리스트를 통과할 때만 딥링크로 쓴다. 알림함은 커서
페이지네이션 + realtime **재조회 신호**로 갱신하고, 읽음 처리는 **뷰포트에 실제로 보인
항목**만 500ms 모아 RPC 한 번으로 보낸다. FCM은 설정 파일이 없어도 앱이 뜨도록
초기화 실패를 부재로 다루며, 그 상태에서도 알림함·설정 화면은 정상 동작한다.

---

## 1. 만든 파일

### `lib/core/notifications/` — 앱 수명주기·SDK 경계

| 파일 | 역할 |
|---|---|
| `firebase_bootstrap.dart` | `Firebase.initializeApp()` 예외를 삼키고 `isFirebaseAvailable` 한 값으로 노출 |
| `push_permission.dart` | OS 권한 상태/요청/시스템 설정 열기 |
| `push_messaging.dart` | 백그라운드 핸들러, 포그라운드 수신→인앱 배너, 알림 탭→딥링크, 종료 상태 초기 메시지 |
| `push_token_sync.dart` | 로그인/로그아웃/`onTokenRefresh` ↔ `register_push_token` RPC |
| `notification_deep_link.dart` | `payload['route']` → 앱 라우트 해석(화이트리스트 + 종류별 폴백) |

### `lib/features/notifications/`

| 파일 | 역할 |
|---|---|
| `data/supabase_notification_repository.dart` | 인계 문서에 계약만 있고 **구현이 없어 이번에 작성** |
| `data/notification_providers.dart` | 알림함(커서)·설정(낙관적 갱신)·미읽음 카운트·realtime 신호 |
| `domain/notification_display.dart` | 종류별 아이콘·색·라벨·설명, 상대 시각, 배지 문구 |
| `presentation/notification_inbox_page.dart` | `/notifications` |
| `presentation/notification_settings_page.dart` | `/notifications/settings` |
| `presentation/widgets/notification_tile.dart` | 타일 + `ViewportVisibilityReporter` |
| `presentation/widgets/unread_badge.dart` | 미읽음 배지 + 헤더 종 버튼 |
| `presentation/widgets/notification_banner_host.dart` | 포그라운드 인앱 배너 + 앱 복귀 시 미읽음/권한 재조회 |
| `presentation/widgets/notification_permission_primer.dart` | 첫 러닝 완료 직후 권한 프라이밍 |

### 수정한 파일

`pubspec.yaml`(firebase_core·firebase_messaging), `lib/main.dart`(초기화+백그라운드 핸들러),
`lib/app.dart`(수명주기 provider 2개), `lib/core/router/app_router.dart`(라우트 2개),
`lib/core/providers/repository_providers.dart`, `lib/core/api/wire_enums.dart`
(`notificationTypeFromWire`), `lib/core/widgets/app_shell.dart`(배너 호스트),
`lib/features/profile/presentation/profile_page.dart`(종 아이콘·"알림 설정" 연결),
`lib/features/tracking/presentation/tracking_page.dart`(프라이밍 삽입),
`android/app/src/main/AndroidManifest.xml`, `android/settings.gradle.kts`,
`android/app/build.gradle.kts`, `ios/Runner/Info.plist`, `ios/Runner/Runner.entitlements`,
`docs/ARCHITECTURE.md`(§3.1 폴더·§2 전제·§12-#6·§13), `docs/TRD.md`(§2 표).

### 테스트

| 파일 | 수 | 내용 |
|---|---|---|
| `test/notifications/notification_display_test.dart` | 21 | 딥링크 해석·QA C-3 회귀·상대 시각·설정 노출 목록 |
| `test/notifications/notification_deep_link_router_test.dart` | 4 | **해석 결과를 실제 `GoRouter.configuration.findMatch()`에 물려** 등록 여부 검증 |
| `test/notifications/notification_screens_test.dart` | 8 | 알림함(뷰포트 읽음·빈 상태) · 설정(NT-07 제외·rawFlag·권한 안내) |

---

## 2. 설계 판단 — 인계 문서에서 더 좁히거나 다르게 간 지점

### 2.1 뷰포트 판정을 패키지 없이 직접 했다

architect §3.2가 요구한 "뷰포트 진입 기준 읽음 처리"를 `visibility_detector` 없이
`RenderBox` 좌표 비교로 구현했다(`ViewportVisibilityReporter`). 필요한 것은 "뷰포트
사각형과 겹치는가" 한 줄뿐이고, 패키지 하나를 이것 때문에 늘리면 이후 지도·차트처럼
교체 비용이 붙는다.

**lazy build만 믿지 않았다.** `ListView`는 `cacheExtent` 때문에 화면 밖 항목까지 미리
만든다 — "타일이 build됐다 = 보였다"로 처리하면 스크롤 한 번 없이 다음 화면 분량까지
읽음이 된다. 그래서 스크롤 틱마다 다시 판정하고, **높이의 절반(최대 24px) 이상**이
겹칠 때만 읽음으로 본다.

### 2.2 딥링크 화이트리스트 — 접두사에서 완전 일치로 (QA C-3 수정)

architect는 `payload['route']`를 그대로 쓰는 것으로 적었다. 그대로 두지 않았다 —
서버가 Phase 4에 `/points`를 실어 보내면 **구버전 앱은 `GoException: no routes for
location`으로 죽는다.**

**첫 구현은 접두사 매칭이었고, 그것이 QA C-3의 원인이었다.** 서버가 발행하던
`/profile/badges`가 `/profile/`로 시작한다는 이유로 화이트리스트를 **통과한 뒤**
go_router에서 크래시했다 — 화이트리스트가 막으려던 바로 그 실패를 화이트리스트가
통과시켰다. 접두사는 "이 아래 어딘가에 라우트가 있을 것"이라는 추측일 뿐,
라우터에 등록돼 있다는 근거가 아니다.

수정: **라우터에 등록된 경로와의 완전 일치**(`_exactRoutes`) + 파라미터 라우트
패턴 1개(`/history/run/{세그먼트 하나}`). 통과하지 못하면 종류별 기본 목적지로
폴백한다. 라우트를 추가하며 목록을 빠뜨리면 딥링크가 폴백될 뿐 **크래시하지 않는**
방향으로 실패한다. 외부 URL 차단은 기존 `RouteAccess.isSafeInternalPath`를
재사용했다(open redirect 방지 규약 공유).

`GoRouter.configuration.findMatch()`를 런타임 판정에 쓰지 않은 이유: core 계층이
라우터 인스턴스에 의존하면 방향이 뒤집히고, 딥링크 해석이 라우터 생성 시점에 묶인다.
대신 **테스트가 그 등가성을 보장한다** —
`test/notifications/notification_deep_link_router_test.dart`가 해석 결과 전부를 실제
`findMatch()`에 물려 `isError == false`를 확인하므로, 두 정의가 어긋나면 테스트가
먼저 깨진다.

### 2.2.1 확정한 딥링크 목적지 (서버 발행값의 정본)

| 알림 | 목적지 | route |
|---|---|---|
| NT-01·02·03·04·05 | 홈(티어 카드 / 주간 랭킹) | `/home` |
| NT-06 레벨 단독 | 활동 — 뱃지 탭 | `/history?tab=badges` |
| NT-06 러닝 유래 | 기록 상세 | `/history/run/{run_id}` |
| NT-07 · 종류 미상 | 알림함 | `/notifications` |

`docs/ARCHITECTURE.md` **§5.6.1**에 같은 표를 넣었다 — QA가 이 표의 부재를 C-3이
문서 검토에서 잡히지 않은 원인으로 지적했다. backend-engineer에게도 회신했다.

**뱃지 갤러리는 라우트가 아니라 쿼리다.** `/history/badges`를 라우트로 만들면 활동
화면 위에 활동 화면이 한 장 더 쌓인다 — 탭은 화면이 아니라 같은 화면의 상태다.
`HistoryPage`가 `?tab=badges`를 읽어 뱃지 탭으로 열리게 했다.

**과거 행 변환표는 두지 않는다.** 처음에는 이미 쌓인 `/ranking`·`/profile/badges`·
`/runs/{id}` 행을 클라이언트가 변환하게 뒀지만, backend가 마이그레이션 50-6에서 그
행들을 직접 백필해(잘못된 route 0건) 걷어냈다. 남기면 **route 매핑의 정의가 두 곳**이
되는데, 정의가 갈라진 것이 C-3의 원인이었다 — 서버가 남긴 잘못된 값은 서버가 치우고,
클라이언트는 "라우터에 등록됐는가" 하나만 판단한다. 미지 경로가 다시 와도 폴백이
안전하게 받는다(크래시 아님).

### 2.3 라우트는 "경로만 최상위, 스택은 마이 탭"

`/notifications`를 셸 밖 최상위 라우트로 두면 알림함에서 바텀 네비가 사라지고, 셸의
어느 브랜치에도 속하지 않아 뒤로 가기 목적지가 애매해진다. 마이 탭 브랜치 안에
`/notifications`(+ 자식 `settings`)를 두어 **경로 문자열은 스펙대로, 스택은 마이 탭**이
되게 했다. 게스트 차단은 `RouteAccess`가 기본값으로 처리한다(허용 목록에 없으면 차단).

### 2.4 권한 상태 출처를 `permission_handler`가 아니라 FirebaseMessaging으로

iOS의 `Permission.notification.status`는 **"아직 안 물어봄"과 "거부함"을 둘 다 `denied`로**
돌려준다. 이 앱은 그 둘을 반드시 구분해야 한다 — `notDetermined`에서만 프라이밍을
띄우고 `denied`에서는 시스템 설정으로 보내야 하기 때문이다. 구분에 실패하면 이미 거부한
사용자에게 러닝마다 같은 카드가 다시 뜬다. 시스템 설정 열기만 `permission_handler`의
`openAppSettings()`를 쓴다.

### 2.5 마스터 스위치와 종류별 토글의 표시 규칙

설정 화면은 `isEnabled`가 아니라 **`rawFlag`**를 그린다. `isEnabled`는 마스터가 꺼져
있으면 항상 false를 주므로, 마스터를 끄는 순간 개별 토글이 전부 off로 보이고 다시 켰을 때
사용자가 예전에 무엇을 껐는지 알 수 없게 된다. 마스터가 꺼진 동안 개별 토글은
**비활성(투명도 45%)이되 값은 그대로** 보인다.

### 2.6 알림함을 설정으로 거르지 않았다 (backend §6.1 경고 반영)

`NotificationSettings.isEnabled`로 목록을 필터하지 않는다. 서버는 종류별 토글이 꺼진
알림을 **애초에 만들지 않고**, 마스터 스위치는 **푸시만** 막는다. 클라이언트가 한 번 더
거르면 마스터를 끈 사용자의 알림함이 통째로 비어 보여 인박스를 만든 이유가 사라진다.
이 규칙은 `notification_providers.dart` 파일 주석에 경고로 못박아 뒀다.

### 2.7 로그아웃 시 FCM 토큰 자체를 폐기한다

서버 행 삭제(`push_tokens` delete)는 세션이 끊긴 뒤라 RLS에 막혀 실패할 수 있다. 그래서
`FirebaseMessaging.deleteToken()`을 두 번째 방어선으로 뒀다 — 토큰이 무효화되면 남은
행은 발송 시 `UNREGISTERED`를 받아 서버가 스스로 지운다. **기기를 넘겨받은 사람에게
이전 사용자의 순위·티어 알림이 가는 사고**를 두 경로 중 하나라도 막으면 되게 했다.

### 2.8 인앱 배너는 축하 큐를 건드리지 않는다

`NotificationBannerHost`는 `AchievementCelebrationHost`를 **감싸기만** 하고 `user_badges`
큐에는 접근하지 않는다. 성취 계열(`isAchievement`)은 배너 스트림에 실리기 전에
`PushMessagingService`가 걸러내므로, 배너 코드에 종류 분기가 없다 — 판정 지점이 하나다.
푸시 payload에 `user_badge_id`가 있어도 그것으로 축하를 띄우지 않는다(ARCHITECTURE §7.4.1).

---

## 3. 사용자(운영)가 해야 할 일 — 이것 없이는 푸시가 나가지 않는다

### 3.1 FCM 프로젝트

1. Firebase 콘솔에서 프로젝트 생성 → Android 앱(`com.runnit.runnit`), iOS 앱(번들 ID) 등록
2. `google-services.json` → **`android/app/google-services.json`**
3. `GoogleService-Info.plist` → **`ios/Runner/GoogleService-Info.plist`**
   (Xcode에서 Runner 타겟에 **파일 참조 추가**까지 해야 번들에 들어간다 — 디렉터리에
   두기만 하면 런타임에 못 찾는다)

### 3.2 Android

`android/settings.gradle.kts`와 `android/app/build.gradle.kts`에 주석 처리해 둔
`com.google.gms.google-services` 플러그인 두 줄을 **함께** 해제한다.

⚠️ **설정 파일 없이 플러그인만 켜면 빌드가 실패한다**("File google-services.json is
missing"). 그래서 지금은 꺼 둔 상태로 커밋했다 — 이 상태에서도 앱은 정상 빌드·기동되고
푸시만 비활성이다.

### 3.3 iOS

1. Xcode → Runner 타겟 → Signing & Capabilities → **+ Capability → Push Notifications**
   (`Runner.entitlements`에 `aps-environment`를 미리 넣어 뒀지만, capability를 추가해야
   프로비저닝 프로파일에 APNs가 포함된다 — HealthKit과 같은 절차다)
2. Apple Developer 콘솔에서 **APNs 인증 키(.p8) 발급 → Firebase 콘솔에 업로드**.
   이것이 없으면 iOS에는 푸시가 **전혀** 가지 않는다.
3. `Info.plist`의 `UIBackgroundModes`에 `remote-notification`은 이미 추가했다.

### 3.4 서버 쪽(아직 미완)

`supabase secrets set FCM_SERVICE_ACCOUNT=...`, `supabase functions deploy push-dispatch`,
Vault 시크릿 2개(`push_dispatch_url` / `push_dispatch_token`).

정본은 `_workspace/20260828_193000_backend_notifications.md` **§6.2**다 — 여기 요약은
앱 설정과 순서를 맞춰 보기 위한 것이고, 서버 항목이 늘거나 바뀌면 그쪽이 먼저 갱신된다.

> **이 3장(§3.1~3.4)을 전부 마친 다음 단계는 §5 실기기 검증 절차다.**
> §3은 "푸시가 나갈 수 있는 상태를 만드는 것"까지이고, "실제로 나가는지 확인하는 것"은
> §5다. backend 문서 §6.2 끝에도 이 §5로 오는 링크가 걸려 있다.

---

## 4. 미해결 / 인계

| # | 항목 | 판단 |
|---|---|---|
| 0 | **QA CONFIRMED 결함 2건 수정 완료(2026-08-28)** | C-3(딥링크 접두사 매칭 → 완전 일치, 목적지 3종 확정, 문서 표 추가) · C-2 클라이언트 측(`data.type` 등 FCM data 파싱을 캐스팅에서 타입 검사로 하드닝 — 값이 없어도 크래시 없이 폴백). **서버 측도 완료** — backend가 마이그레이션 49(`data.type` 탑재)·50(route 확정값 + 과거 행 백필)을 원격 적용하고 발행값 20건을 전수 확인했다. 그에 따라 클라이언트의 과거 route 변환표는 걷어냈다 |
| 1 | **실기기 검증 미완** | FCM 설정 파일이 없어 토큰 발급·수신·딥링크는 **한 번도 실제로 돌려보지 못했다.** 절차는 아래 §5 |
| 2 | 알림 종류별 아이콘이 Material 임시값 | `assets/icons/`에 종류별 lucide 원본이 없다. Figma 확정 시 SVG로 교체(`notification_display.dart`) |
| 3 | Android 알림 채널·아이콘 미설정 | 기본 채널/기본 아이콘 meta-data를 넣지 않았다. 서버가 `notification` 블록을 보내므로 동작은 하지만, 상태바 아이콘이 흰 사각형으로 보일 수 있다 — 흑백 실루엣 drawable이 준비되면 `manifest`에 `com.google.firebase.messaging.default_notification_icon`을 추가한다 |
| 4 | `appVersion`을 항상 null로 보낸다 | `package_info_plus`를 이 필드 하나 때문에 추가하지 않았다. "특정 버전에서만 알림이 안 온다"를 추적해야 할 시점에 도입 |
| 5 | 홈·활동 헤더에는 종 아이콘이 없다 | 미읽음 배지 진입점은 현재 **마이페이지 헤더 하나**다. Figma의 홈 헤더에 종 아이콘이 없어 임의로 추가하지 않았다 — 노출을 늘릴지는 디자인 결정 사항 |
| 6 | PRD §5.10 NT-05 예시 문구 | PRD는 `"10위까지 2.1km"`, 구현(서버)은 `"앞사람까지 0.8km · 128위(상위 34%)"`. backend §6.3-#5와 동일한 미해결 항목이며 **오케스트레이터가 사용자 확인 후 PRD를 갱신할 대상**이다. 설정 화면 설명 문구는 §5.4.1의 격차 우선 표기를 따랐다 |


---

## 5. 실기기 검증 절차 (FCM 운영 설정 완료 후)

**선행 조건**: §3(앱·네이티브 설정) + `_workspace/20260828_193000_backend_notifications.md`
§6.2(FCM 프로젝트·시크릿·Edge Function 배포)를 **둘 다** 마쳐야 한다. 한쪽만 끝난
상태에서는 아래 항목 대부분이 "안 옴"으로만 보이고 원인을 가릴 수 없다.

§3을 마치고 나서 확인할 항목이다. **증상만으로는 클라이언트 문제인지 발송 문제인지
갈리지 않으므로**, 각 항목을 서버 상태와 함께 본다(backend-engineer 제공).

```sql
select type, title, payload->>'route' as route,
       sent_at, send_attempts, send_error, read_at
  from notifications where user_id = '<uid>' order by created_at desc limit 20;
```

| 서버 상태 | 해석 |
|---|---|
| `sent_at` 있고 `send_error` null | **서버는 FCM에 넘겼다.** 기기에 안 뜨면 그 뒤(토큰·권한·네이티브 설정) 문제 |
| `send_error = 'no_token'` | `push_tokens`에 행이 없음 → `register_push_token`이 안 불린 것(= 클라이언트 `PushTokenSync` 문제) |
| `send_error = 'push_disabled'` | 마스터 스위치 off |
| `sent_at` null + `send_attempts` 증가 | FCM 호출 실패 중. `send_error`에 HTTP 상태·응답 앞부분 |
| **셋 다 비어 있음** (`sent_at` null · `send_attempts` 0 · `send_error` null) | 디스패처가 **아예 돌지 않았다.** 십중팔구 Vault 시크릿(`push_dispatch_url`/`push_dispatch_token`) 미설정 — 그 경우 `dispatch_pending_pushes()`가 조용히 no-op이라 **실패 흔적조차 남지 않는다.** 토큰이 없으면 `no_token`으로라도 남으므로, "아무 흔적 없음"은 토큰 문제가 아니라 서버 설정 문제다. **추측하지 말고 backend 문서 §6.2의 Vault 확인 쿼리로 단정할 것**(`vault.decrypted_secrets`에서 2행이 나와야 한다) |
| `send_attempts`가 0에서 안 움직이는데 재시도 반복 | **C-1 재발** — backend-engineer 호출 |

### 검증 항목

| # | 항목 | 확인 내용 |
|---|---|---|
| 1 | 토큰 등록 | 로그인 후 `push_tokens`에 행이 생기는가(권한 승인 후) |
| 2 | 포그라운드 배너 (NT-04) | 인앱 스낵바가 뜨고 "보기"가 `/home`으로 가는가 |
| 3 | 포그라운드 **억제** (NT-01/06) | 성취 계열은 배너가 **뜨지 않고** 축하 풀페이지만 뜨는가 (`data.type`이 실려야 동작 — 마이그레이션 49) |
| 4 | 백그라운드 탭 → 딥링크 | 트레이 알림 탭 시 목적지 화면으로 가는가 |
| 5 | 종료 상태 탭 → 딥링크 | `getInitialMessage` 경로. 첫 프레임 뒤 이동이라 타이밍 확인 필요 |
| 6 | **레벨 단독 → `/history?tab=badges`** | **C-3이 크래시하던 바로 그 경로.** 최우선 |
| 7 | 뷰포트 읽음 처리 | 실기기 스크롤에서 화면 밖 항목이 읽음되지 않는가 |
| 8 | 로그아웃 | 이전 계정 알림이 오지 않는가(`push_tokens` 행 삭제 + FCM 토큰 폐기) |

⚠️ **6번은 러닝으로 발화하지 않는다**(backend 확인). 러닝 유래 레벨업은 `runs_04`가
뱃지와 묶어 `/history/run/{id}`로 보내고, 레벨 단독 경로는 **러닝 없이 XP가 오르는
경우**(뱃지 `verified`/`revoked` 변경, `tier_change_history` INSERT)라 자연 발생이 드물다.
backend-engineer가 테스트 계정에 그 경로를 태워 알림 행을 만들어 줄 수 있다 —
**필요한 것은 테스트 계정 uid 하나**이며, 그 계정은 FCM 설정을 마친 실기기에서
로그인한 계정이어야 한다.

---

## 6. 이 작업 범위 밖 — 오케스트레이터 결정 필요

**RK-06 주간 상위권 뱃지의 최소 모집단 게이트 누락**(TRD §14-#23, backend-engineer 제기).
알림과 무관한 뱃지 판정 정확성 버그이지만 **베타 오픈 전 필수**다 — 베타 사용자가 10명을
넘는 순간부터 참가자 3명짜리 티어에서 1위 뱃지가 나가기 시작하고, **뱃지는 영구 자산이라
정상 경로로 회수가 안 된다.** 수정 SQL은 `_workspace/20260828_181500_gamification_
notification-rules.md` §6.2에 이식 가능한 형태로 있다. 별도 라운드가 필요하다.
