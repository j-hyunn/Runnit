import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/auth/auth_state.dart';
import 'package:runnit/core/notifications/notification_deep_link.dart';
import 'package:runnit/core/router/app_router.dart';
import 'package:runnit/models/models.dart';

/// **딥링크 해석 결과를 실제 라우터에 물려 본다.**
///
/// 2026-08-28 QA C-3의 교훈: 화이트리스트가 "통과"라고 말해도 go_router에 그 경로가
/// 없으면 `GoException: no routes for location`으로 앱이 죽는다. 두 곳(딥링크 표와
/// 라우트 등록)이 손으로 맞춰져 있다는 사실 자체가 결함의 원인이었으므로, 여기서는
/// **해석기가 내놓을 수 있는 모든 목적지를 라우터에 직접 매칭**시킨다.
///
/// 라우트를 추가·변경하면서 이 테스트가 깨지면, 깨진 쪽이 아니라 두 정의가
/// 어긋났다는 신호다.
class _FakeAuthNotifier extends AuthNotifier {
  @override
  AppAuthState build() => const AppAuthState.guest();
}

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        // 라우터만 필요하다 — Supabase 클라이언트를 세우지 않는다.
        authStateProvider.overrideWith(_FakeAuthNotifier.new),
      ],
    );
  });

  tearDown(() => container.dispose());

  /// go_router가 이 경로를 실제로 그릴 수 있는가.
  void expectRoutable(String route) {
    final router = container.read(appRouterProvider);
    final match = router.configuration.findMatch(Uri.parse(route));
    expect(
      match.isError,
      isFalse,
      reason: '$route 는 라우터에 등록돼 있지 않다 — 탭하면 앱이 죽는다',
    );
  }

  test('모든 알림 종류의 폴백 목적지가 라우터에 존재한다', () {
    for (final type in NotificationType.values) {
      expectRoutable(NotificationDeepLink.resolveRaw(null, type));
    }
  });

  test('종류를 모르는 알림의 목적지도 라우터에 존재한다', () {
    expectRoutable(NotificationDeepLink.resolveRaw(null, null));
  });

  test('서버가 보낼 수 있는 값 어떤 것도 라우터에 없는 경로를 만들지 않는다', () {
    const inputs = <String?>[
      null,
      '',
      '/home',
      '/history',
      '/history?tab=badges',
      '/history/run/run-1',
      '/notifications',
      '/notifications/settings',
      '/profile',
      '/tracking',
      // QA C-3에서 실제로 서버가 발행하던, 앱에 없는 경로들.
      '/ranking',
      '/runs/run-1',
      '/profile/badges',
      // 앞으로 생길 수 있는 미지 경로·악성 입력.
      '/points',
      '/profile/settings',
      '/history/badges',
      'https://evil.example.com',
      '//evil.example.com',
      'io.runnit.app://login-callback',
      '/login',
    ];

    for (final input in inputs) {
      for (final type in <NotificationType?>[
        null,
        NotificationType.badgeLevel,
        NotificationType.rankChange,
        NotificationType.points,
      ]) {
        expectRoutable(NotificationDeepLink.resolveRaw(input, type));
      }
    }
  });

  test('로그인 화면으로는 딥링크하지 않는다', () {
    // `/login`은 라우터에 있지만 알림 목적지로는 부적절하다 —
    // `RouteAccess.isSafeInternalPath`가 로그인 루프를 막는다.
    expect(
      NotificationDeepLink.resolveRaw('/login', NotificationType.rankChange),
      Routes.home,
    );
  });
}
