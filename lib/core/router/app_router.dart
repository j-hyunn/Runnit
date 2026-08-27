import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/login_page.dart';
import '../../features/history/presentation/history_page.dart';
import '../../features/history/presentation/run_detail_page.dart';
import '../../features/home/presentation/home_page.dart';
import '../../features/profile/presentation/profile_page.dart';
import '../../features/tracking/presentation/tracking_page.dart';
import '../auth/auth_config.dart';
import '../auth/auth_providers.dart';
import '../auth/auth_state.dart';
import '../widgets/app_shell.dart';
import 'route_access.dart';

/// 라우트 경로 상수. 문자열 리터럴을 화면 코드에 흩뿌리지 않는다.
///
/// **2026-08-21 4탭 개편**: `ranking`/`badges` 독립 라우트를 없앴다.
/// 랭킹은 [Routes.home](티어 카드 + 랭킹), 뱃지는 [Routes.history] 안의
/// 하위 탭으로 흡수됐다 — Figma 프레임(홈/러닝/기록/마이 4탭) 반영.
class Routes {
  const Routes._();

  static const home = '/home';
  static const tracking = '/tracking';
  static const history = '/history';
  static const runDetail = 'run/:runId'; // history 하위 (전체: /history/run/:id)
  static const profile = '/profile';

  /// 카카오 로그인 화면. 셸(바텀 네비) **바깥**의 최상위 라우트다 —
  /// 로그인 벽에서 탭 바가 보이면 "탭은 있는데 눌러도 안 되는" 상태가 된다.
  static const login = '/login';

  /// 로그인 후 원래 가려던 곳으로 되돌리기 위한 쿼리 파라미터 이름.
  /// 예: `/login?from=%2Fprofile`
  static const fromQueryParam = 'from';
}

/// 앱 라우터.
///
/// ## 게스트 가드 계약 (2026-08-21 4탭 개편)
/// | 경로 | 게스트 | 비고 |
/// |------|--------|------|
/// | `/home` | 허용 | 티어 카드는 로그인 유도로 대체, 랭킹은 그대로 공개 |
/// | `/history` (+ 상세) | 허용 | **뱃지 탭만 공개**(카탈로그). 기록 탭은 위젯이 로그인 유도 |
/// | `/tracking` | 차단 | 러닝 시작에 userId 필요 |
/// | `/profile` | 차단 | 내 프로필 |
/// | `/login` | 항상 허용 | 로그인 완료 시 `from` 또는 `/tracking`으로 자동 이탈 |
///
/// 차단 라우트에 게스트가 진입하면 `/login?from=<원래경로>`로 리다이렉트한다.
/// 로그인 화면에는 "둘러보기"(게스트 계속) 액션이 있고, 그것을 누르면
/// [RouteAccess.guestLanding](`/home`)으로 보낸다 — flutter-ui-designer 담당.
///
/// 라우터 인스턴스는 인증 상태에 따라 **재생성되지 않는다**(재생성하면 셸의
/// 탭별 네비게이션 스택이 날아간다). 대신 `refreshListenable`로 `redirect`만
/// 다시 평가시킨다.
final appRouterProvider = Provider<GoRouter>((ref) {
  final homeKey = GlobalKey<NavigatorState>(debugLabel: 'home');
  final trackingKey = GlobalKey<NavigatorState>(debugLabel: 'tracking');
  final historyKey = GlobalKey<NavigatorState>(debugLabel: 'history');
  final profileKey = GlobalKey<NavigatorState>(debugLabel: 'profile');

  // 인증 상태가 바뀔 때마다 redirect를 재평가시키는 트리거.
  // status만 보므로 토큰 자동 갱신으로는 흔들리지 않는다.
  final refresh = ValueNotifier<AuthStatus>(
    ref.read(authStateProvider).status,
  );
  ref.listen<AppAuthState>(
    authStateProvider,
    (_, next) => refresh.value = next.status,
  );
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.tracking,
    refreshListenable: refresh,
    redirect: (context, state) => _guestGuard(ref, state),
    routes: [
      GoRoute(
        path: Routes.login,
        // 셸 밖 최상위 라우트. UI 구현은 flutter-ui-designer가 교체한다.
        builder: (_, __) => const LoginPage(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(
            navigatorKey: homeKey,
            routes: [
              GoRoute(
                path: Routes.home,
                builder: (_, __) => const HomePage(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: trackingKey,
            routes: [
              GoRoute(
                path: Routes.tracking,
                builder: (_, __) => const TrackingPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: historyKey,
            routes: [
              GoRoute(
                path: Routes.history,
                builder: (_, __) => const HistoryPage(),
                routes: [
                  GoRoute(
                    path: Routes.runDetail,
                    builder: (_, state) => RunDetailPage(
                      runId: state.pathParameters['runId'] ?? '',
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: profileKey,
            routes: [
              GoRoute(
                path: Routes.profile,
                builder: (_, __) => const ProfilePage(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

/// go_router `redirect` 본체. **동기 함수**이므로 인증 상태를 동기적으로 읽을 수
/// 있어야 한다 — `authStateProvider`가 `currentSession`으로 초기화되는 이유.
String? _guestGuard(Ref ref, GoRouterState state) {
  // 카카오 OAuth 콜백 딥링크(`io.runnit.app://login-callback?code=...`)가
  // 여기로도 들어온다 — `supabase_flutter`가 `detectSessionInUri`로 별도
  // 리스너를 통해 이 URI에서 세션을 이미 복원하고 있지만, 이 URI 자체는
  // go_router에 등록된 어떤 경로와도 매치되지 않아 그냥 두면 "Page Not
  // Found"(`GoException: no routes for location`)로 떨어진다. 세션 복원은
  // 비동기라 이 시점엔 아직 안 끝났을 수도 있으므로, 여기서는 판단하지 않고
  // 그냥 안전한 화면으로 흘려보낸다 — 세션이 실제로 반영되면
  // `refreshListenable`이 redirect를 다시 평가해 알아서 정리한다.
  if (state.uri.scheme == AuthConfig.appScheme &&
      state.uri.host == AuthConfig.oauthCallbackHost) {
    return RouteAccess.authenticatedHome;
  }

  final auth = ref.read(authStateProvider);

  // 세션 복원 전에는 판단하지 않는다(로그인 화면 깜빡임 방지).
  if (!auth.isResolved) return null;

  final location = state.matchedLocation;
  final atLogin = location == Routes.login;

  if (auth.isAuthenticated) {
    if (!atLogin) return null;
    // 로그인 완료 → 원래 가려던 곳으로 복귀. 없거나 안전하지 않으면 홈으로.
    final from = state.uri.queryParameters[Routes.fromQueryParam];
    return RouteAccess.isSafeInternalPath(from)
        ? from
        : RouteAccess.authenticatedHome;
  }

  // 여기서부터 게스트.
  if (atLogin) return null;
  if (RouteAccess.allowsGuest(location)) return null;

  return Uri(
    path: Routes.login,
    queryParameters: {Routes.fromQueryParam: state.uri.toString()},
  ).toString();
}

/// 화면 안에서 로그인을 유도할 때 쓰는 헬퍼.
///
/// 뱃지 카탈로그의 "로그인하고 내 획득 현황 보기" 같은 **인라인 CTA**에서 호출한다.
/// (라우터 가드는 화면 단위로만 막으므로, 공개 화면 안의 비공개 기능은
///  이렇게 명시적으로 로그인 화면을 띄운다.)
extension AuthNavigation on BuildContext {
  void goToLogin({String? from}) {
    final target = from ?? GoRouterState.of(this).uri.toString();
    push(
      Uri(
        path: Routes.login,
        queryParameters: RouteAccess.isSafeInternalPath(target)
            ? {Routes.fromQueryParam: target}
            : null,
      ).toString(),
    );
  }
}
