# Runnit 인증 아키텍처 — 카카오 전용 로그인 + 게스트 모드

작성: mobile-architect / 2026-08-20
선행 문서: `_workspace/20260819_132600_architect_data-model.md` (AppUser 계약), `_workspace/20260819_132600_backend_schema.md`

---

## 0. 결정 요약

| 항목 | 결정 |
|------|------|
| 로그인 수단 | **카카오 단일**. Supabase 내장 OAuth(`OAuthProvider.kakao`) 웹 플로우 |
| 네이티브 SDK | 도입 안 함 (`kakao_flutter_sdk` 추가하지 않음) |
| 상태 소스 | `auth.currentSession`(동기 초기값) + `auth.onAuthStateChange`(갱신) |
| 상태 클래스 | `AppAuthState` (Supabase의 `AuthState`와 이름 충돌 회피 — `AppUser` 규칙과 동일) |
| 가드 방식 | go_router `redirect` + `refreshListenable` (라우터 재생성 없음) |
| 게스트 공개 범위 | `/ranking` 전체, `/badges` 카탈로그 |
| 로그인 라우트 | `/login` — 셸(바텀 네비) **바깥**의 최상위 라우트 |
| 프로필 조회 | 인증 상태와 **분리**된 `currentProfileProvider` |

---

## 1. 파일 구성

```
lib/core/auth/
  auth_config.dart      # 딥링크 스킴 / OAuth redirect URL 상수
  auth_state.dart       # AuthStatus enum, AppAuthState
  auth_providers.dart   # authStateProvider 외 파생 provider
  auth_controller.dart  # signInWithKakao() / signOut() 액션
lib/core/router/
  app_router.dart       # /login 라우트 + _guestGuard redirect + AuthNavigation 확장
  route_access.dart     # 게스트 허용 정책의 단일 정의 지점
lib/features/auth/presentation/
  login_page.dart       # 골격 스텁 (flutter-ui-designer가 교체)
```

`flutter analyze` 전체 통과(이슈 0).

---

## 2. 인증 상태 흐름

```
main()
  └─ await initializeSupabase()        # Supabase.initialize 내부에서 로컬 세션 복구를 await
       └─ runApp()
            └─ AuthNotifier.build()
                 ├─ 초기값 = AppAuthState.fromSession(client.auth.currentSession)   ← 동기
                 └─ subscribe: client.auth.onAuthStateChange
                                  │
   ┌──────────────────────────────┴───────────────────────────────┐
   │ signedIn / tokenRefreshed / initialSession → authenticated   │
   │ signedOut / 세션 만료                        → unauthenticated│
   └──────────────────────────────┬───────────────────────────────┘
                                  ▼
                        authStateProvider (AppAuthState)
                                  │
             ┌────────────────────┼──────────────────────┐
             ▼                    ▼                      ▼
   isAuthenticatedProvider  currentUserIdProvider  ValueNotifier<AuthStatus>
        (위젯 분기)              (쿼리 파라미터)      → GoRouter.refreshListenable
                                                        → redirect 재평가
```

**카카오 로그인 왕복:**

```
[로그인 화면] signInWithKakao()
   → 브라우저(ASWebAuthenticationSession / Custom Tabs) 실행   ← 여기서 함수 반환
   → 카카오 동의 → Supabase /auth/v1/callback
   → 딥링크 io.runnit.app://login-callback?...  (supabase_flutter가 가로챔)
   → onAuthStateChange(signedIn) → authStateProvider = authenticated
   → refreshListenable 발화 → redirect: /login → ?from 경로 (없으면 /tracking)
```

### 왜 `authStateProvider`가 동기 초기값을 갖는가
go_router의 `redirect`는 **동기 함수**다. 인증 상태가 `AsyncValue`(로딩부터 시작)면
첫 프레임에서 전부 미인증으로 판정되어, 로그인된 사용자에게도 로그인 화면이 한 번
깜빡인다. `Supabase.initialize`가 세션 복구를 await 하므로 `currentSession`을 초기값으로
쓰면 이 문제가 사라진다. 그럼에도 `AuthStatus.unknown`을 남겨둔 것은 안전판이다 —
`unknown`이면 `redirect`는 아무 판단도 하지 않는다(`isResolved` 체크).

### 왜 프로필을 인증 상태에 안 넣는가
`currentProfileProvider`(프로필) → `userRepositoryProvider` → `supabaseClientProvider`.
인증 상태가 프로필을 품으면 "로그인 판정이 네트워크 조회를 기다리는" 구조가 되고,
프로필 fetch 실패 = 로그아웃 판정이라는 잘못된 결합이 생긴다. 분리 유지.

---

## 3. 게스트 허용/차단 라우트 표

| 경로 | 게스트 | 동작 | 비고 |
|------|--------|------|------|
| `/ranking` (+ 하위) | **허용** | 그대로 렌더 | 리더보드 전체 공개 |
| `/badges` (+ 하위) | **허용** | 카탈로그 렌더 | **개인화 레이어는 위젯이 숨김** (§5) |
| `/login` | 허용 | 그대로 | 로그인되면 자동 이탈 |
| `/tracking` | 차단 | → `/login?from=/tracking` | 러닝 시작에 userId 필요 |
| `/history` | 차단 | → `/login?from=/history` | 내 기록 |
| `/history/run/:runId` | 차단 | → `/login?from=...` | 내 기록 상세 |
| `/profile` | 차단 | → `/login?from=/profile` | 내 프로필 |

정책 정의 위치: `lib/core/router/route_access.dart`의 `RouteAccess.guestAllowedPrefixes`.
**새 라우트를 추가하면 기본이 "로그인 필요"다** (allowlist 방식). 공개하려면 이 리스트에 추가.

부가 규칙:
- `initialLocation`은 `/tracking` 유지 → 미로그인 콜드 스타트는 `/login`에 착지한다.
  로그인 화면의 "둘러보기"가 게스트의 진입점이며, 누르면 `/ranking`으로 간다.
- 로그인 성공 시 `?from=` 경로로 복귀. `from`은 `RouteAccess.isSafeInternalPath`로
  검증한다(`/`로 시작 + `//` 아님 + `/login` 아님) — 오픈 리다이렉트/루프 방지.
- 로그아웃하면 `refreshListenable`이 발화해 보호 라우트에 있던 사용자가 자동으로
  `/login`으로 밀려난다. 화면 쪽에서 수동 네비게이션할 필요 없다.
- 인증 상태가 바뀌어도 **라우터 인스턴스는 재생성되지 않는다**. `appRouterProvider`가
  `authStateProvider`를 `watch`하지 않고 `listen`만 하는 이유 — watch하면 로그인할 때마다
  셸 5개 브랜치의 네비게이션 스택이 전부 날아간다.

---

## 4. flutter-ui-designer 계약

### 로그인 화면 (`lib/features/auth/presentation/login_page.dart` 교체)

```dart
// 로그인 시작 — 카카오가 유일한 수단. 다른 진입점을 추가하지 말 것.
await ref.read(authControllerProvider.notifier).signInWithKakao();

// 로그아웃 (프로필 화면)
await ref.read(authControllerProvider.notifier).signOut();

// 액션 상태: AsyncData(null) 대기 / AsyncLoading() 진행 / AsyncError(Failure)
final AsyncValue<void> action = ref.watch(authControllerProvider);

// 에러 배너 닫기
ref.read(authControllerProvider.notifier).clearError();

// 게스트 계속
context.canPop() ? context.pop() : context.go(RouteAccess.guestLanding); // '/ranking'
```

**주의 — `signInWithKakao()`의 반환은 "로그인 성공"이 아니다.** 브라우저를 띄우는 데
성공했다는 뜻일 뿐이다. 실제 로그인 완료는 딥링크 복귀 후 `authStateProvider`가 알린다.
사용자가 브라우저를 그냥 닫으면 아무 이벤트도 오지 않으므로, **버튼 스피너를
`authControllerProvider`의 로딩에만 묶고** "세션이 붙을 때까지 무한 로딩" 같은 UI를
만들지 말 것. 화면 전환은 라우터 `redirect`가 자동으로 한다 — 로그인 화면에서
`context.go(...)`로 직접 이동시키지 말 것.

`AsyncError`의 `error`는 **항상 `Failure`**다 (`Failure.unauthorized` 또는 `Failure.unknown`).

### 화면에서 쓰는 인증 조회

```dart
final bool signedIn = ref.watch(isAuthenticatedProvider);   // 위젯 분기용(권장)
final String? userId = ref.watch(currentUserIdProvider);     // 쿼리 파라미터용
final AsyncValue<AppUser?> me = ref.watch(currentProfileProvider); // 프로필(게스트면 null)
```

### 인라인 로그인 유도

공개 화면 안의 비공개 기능(예: 뱃지 카탈로그의 "내 획득 현황")에는 라우터 가드가
걸리지 않는다. 명시적으로 띄운다:

```dart
import '../../../core/router/app_router.dart';
context.goToLogin();          // 현재 위치를 from으로 넣고 /login push
```

### 뱃지 갤러리의 게스트 처리 (`badge_gallery_page.dart`)
- 게스트: 전체 카탈로그를 **잠금 표시 없이** 보여준다. 획득 여부/진행률/획득 일시는 렌더하지 않는다.
- 게스트: 화면 상단 또는 하단에 "로그인하고 내 뱃지 모으기" CTA → `context.goToLogin()`.
- 로그인: 기존대로 `UserBadge` 기반 획득 상태 + 진행률 렌더.

### 프로필 화면
가드 때문에 게스트는 진입 자체가 불가하므로, "로그인 안 됨" 빈 상태를 만들 필요는 없다.
대신 **로그아웃 버튼**을 이 화면에 둔다.

### 랭킹 화면
게스트도 전체 리더보드를 본다. "내 순위 하이라이트" 행만 `isAuthenticatedProvider`로 분기.

---

## 5. backend-engineer에게 넘기는 요청사항

### (A) 딥링크 스킴 등록 — **필수, 아직 미완료**
`lib/core/api/supabase_client.dart`의 `Supabase.initialize`에는 딥링크 관련 설정이 없다
(`detectSessionInUri`는 기본 true라 코드 변경은 불필요하다). 하지만 **네이티브 등록과
Supabase 대시보드 등록이 남아 있다.**

확정한 값 (`lib/core/auth/auth_config.dart`):
- 스킴: `io.runnit.app`
- 콜백: `io.runnit.app://login-callback`

필요한 작업 (**이번 세션 범위 밖 — 사용자/후속 세션**):
1. iOS `ios/Runner/Info.plist` → `CFBundleURLTypes`에 `CFBundleURLSchemes = io.runnit.app` 추가
2. Android `android/app/src/main/AndroidManifest.xml` → `MainActivity`에 intent-filter 추가
   (`android:scheme="io.runnit.app"`, `android:host="login-callback"`, BROWSABLE/DEFAULT)
3. Supabase 대시보드 → Authentication → URL Configuration → **Redirect URLs**에
   `io.runnit.app://login-callback` 추가
4. Supabase 대시보드 → Authentication → Providers → **Kakao** 활성화 + 카카오 REST API 키/Client Secret 입력
5. 카카오 개발자 콘솔 → 플랫폼 등록 + Redirect URI에 `https://<project-ref>.supabase.co/auth/v1/callback` 등록

3~5가 backend-engineer 체크리스트에 포함되어야 한다. 값이 바뀌면 앱은
`--dart-define=OAUTH_REDIRECT_URL=...`로 덮어쓸 수 있다.

### (B) `handle_new_auth_user()` 트리거 — 카카오 대응 조정 요청
`supabase/migrations/20260819140600_06_auth_bootstrap.sql`을 검토했다. **SQL은 건드리지 않았다.**
카카오 로그인 기준으로 확인한 사항:

1. **fallback 자체는 작동한다.** 카카오가 email scope 동의를 받지 못하면 `new.email`이 null →
   `split_part('', '@', 1)` = `''` → `nullif` → null → `'runner'`로 떨어지고, 중복 루프가
   `runner_0421` 같은 값을 만든다. 앱이 깨지지는 않는다.

2. **[중] username 후보에 카카오 메타데이터가 빠져 있다.** Supabase의 Kakao 프로바이더는
   `raw_user_meta_data`에 `name` / `full_name` / `preferred_username` / `picture` / `avatar_url`
   등을 넣고, `username`·`display_name` 키는 **넣지 않는다**. 그래서 이메일 미동의 사용자는
   전원 `runner_XXXX`가 된다. `coalesce` 후보에 `'preferred_username'`, `'name'`, `'full_name'`을
   추가하면 개선된다(한글 닉네임은 정규식에 걸러져 자동으로 다음 후보로 넘어간다).

3. **[중] display_name / avatar_url이 카카오에서 안 채워진다.** 현재는
   `raw_user_meta_data ->> 'display_name'` / `->> 'avatar_url'`만 본다. 각각
   `coalesce(display_name, full_name, name)` / `coalesce(avatar_url, picture)`로 확장 요청.
   (display_name은 한글을 그대로 보존해야 하므로 정규식 스트립을 적용하지 말 것.)

4. **[하·경합] 동시 가입 시 unique violation 가능성.** 이메일 없는 두 사용자가 거의 동시에
   가입하면 둘 다 `'runner'`를 후보로 계산하고, `while exists` 체크와 `insert` 사이의
   레이스로 `profiles.username` 유니크 제약 위반 → 트리거 예외 → **auth 가입 자체가 실패**한다.
   `insert`를 `exception when unique_violation then` 재시도 루프로 감싸는 방어를 권장.

5. `profiles.id`는 `auth.users.id`와 동일하다는 계약은 그대로 유효하다 — `AppUser.id` 매핑 변경 없음.

---

## 6. 데이터 모델 영향

**`AppUser` 및 다른 모든 모델에 변경 없음.** breaking change 없음.
이번 작업은 모델 계층을 건드리지 않고 `core/auth` + `core/router`만 추가/수정했다.
`lib/core/router/app_router.dart`는 기존 5탭 셸 구조·경로 상수·`RunDetailPlaceholder`를
그대로 보존한 채 `/login` 라우트와 `redirect`만 얹었다.

## 7. 후속/미결

- 게스트 모드 "둘러보기" 선택의 **영속화 안 함**(인메모리도 아님). 앱을 재시작하면
  미로그인 사용자는 다시 `/login`에 착지한다. 이게 거슬리면 `shared_preferences`로
  `hasSkippedLogin` 플래그를 두고 `initialLocation`을 분기하는 확장을 권장(별도 작업).
- 세션 만료 시 사용자에게 알리는 스낵바/다이얼로그는 미구현. 현재는 조용히 `/login`으로 이동.
- iOS/Android 네이티브 딥링크 설정 파일 미수정 (§5-A).
