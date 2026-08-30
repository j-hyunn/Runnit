import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/notifications/notification_deep_link.dart';
import 'package:runnit/core/router/app_router.dart';
import 'package:runnit/features/notifications/domain/notification_display.dart';
import 'package:runnit/models/models.dart';

/// 알림 표시 규칙의 순수 함수들 — 딥링크 해석, 상대 시각, 설정 화면 노출 목록.
///
/// 화면을 띄우지 않고 검증할 수 있는 부분을 여기 모아 둔다. 특히 딥링크는
/// **서버가 준 경로를 그대로 믿지 않는다**는 규칙이 핵심이라, 앱에 없는 경로가
/// 들어왔을 때 죽지 않고 종류별 기본 목적지로 떨어지는지를 본다.
void main() {
  AppNotification notification({
    NotificationType type = NotificationType.rankChange,
    Map<String, dynamic> payload = const {},
  }) =>
      AppNotification(
        id: 'n1',
        userId: 'u1',
        type: type,
        title: '제목',
        body: '본문',
        payload: payload,
        createdAt: DateTime.utc(2026, 8, 28, 9),
      );

  group('딥링크', () {
    test('화이트리스트에 있는 경로는 그대로 쓴다', () {
      final target = NotificationDeepLink.resolve(
        notification(payload: {'route': Routes.history}),
      );
      expect(target, Routes.history);
    });

    test('앱에 없는 경로는 버리고 종류별 기본 목적지로 간다', () {
      // 서버가 Phase 4에 `/points`를 실어 보내도 구버전 앱이 죽으면 안 된다.
      final target = NotificationDeepLink.resolve(
        notification(
          type: NotificationType.tierPromotion,
          payload: {'route': '/points'},
        ),
      );
      expect(target, Routes.home);
    });

    test('외부 URL은 통과시키지 않는다(open redirect 방지)', () {
      final target = NotificationDeepLink.resolve(
        notification(payload: {'route': 'https://evil.example.com'}),
      );
      expect(target, Routes.home);
    });

    test('뱃지·레벨업은 활동 화면의 뱃지 탭으로 간다', () {
      expect(
        NotificationDeepLink.resolve(
          notification(type: NotificationType.badgeLevel),
        ),
        Routes.badgeGallery,
      );
    });

    test('종류를 모르면 최소한 알림함으로 보낸다', () {
      expect(
        NotificationDeepLink.resolveRaw(null, null),
        Routes.notifications,
      );
    });

    // ── 2026-08-28 QA C-3 회귀 ────────────────────────────────────────
    // 서버가 발행하던 route 3종이 라우터에 없었고, 그중 `/profile/badges`는
    // 접두사 화이트리스트(`/profile/`)를 **통과한 뒤** go_router에서
    // `no routes for location`으로 크래시했다.
    group('QA C-3 — 라우터에 없는 서버 발행 경로', () {
      // 서버는 마이그레이션 49·50에서 정정됐고 과거 행도 50-6에서 백필됐다.
      // 그래도 이 입력들이 **다시 들어와도 크래시하지 않고 종류별 목적지로
      // 착지한다**는 성질은 계속 지켜야 한다 — 클라이언트가 서버 발행값의
      // 정확성에 기대지 않는다는 것이 C-3 수정의 핵심이다.
      test('/profile/badges는 접두사를 통과하지 못한다(크래시 원인)', () {
        final target = NotificationDeepLink.resolve(
          notification(
            type: NotificationType.badgeLevel,
            payload: {'route': '/profile/badges'},
          ),
        );
        // 종류별 폴백으로 착지한다 — 우연히 목적지가 같지만, 통과가 아니라 폴백이다.
        expect(target, Routes.badgeGallery);
        expect(target, isNot('/profile/badges'));
      });

      test('/ranking은 종류별 폴백으로 착지한다', () {
        expect(
          NotificationDeepLink.resolveRaw('/ranking', NotificationType.rankChange),
          Routes.home,
        );
      });

      test('/runs/{id}는 폴백한다 — 클라이언트가 경로를 고쳐 주지 않는다', () {
        // 변환표를 뒀다가 걷어냈다(서버가 50-6에서 백필). route 매핑의 정의가
        // 두 곳으로 갈라지는 것이 C-3의 원인이었으므로, 정의는 서버 한 곳이다.
        expect(
          NotificationDeepLink.resolveRaw('/runs/abc-123', NotificationType.badgeLevel),
          Routes.badgeGallery,
        );
      });

      test('올바른 기록 상세 경로는 그대로 통과한다', () {
        expect(
          NotificationDeepLink.resolveRaw(
            '/history/run/abc-123',
            NotificationType.badgeLevel,
          ),
          '/history/run/abc-123',
        );
      });

      test('/profile 자체는 실존 라우트라 그대로 간다', () {
        expect(
          NotificationDeepLink.resolveRaw(Routes.profile, null),
          Routes.profile,
        );
      });

      test('실존 라우트의 하위 경로라도 등록돼 있지 않으면 폴백한다', () {
        // 접두사 매칭이었다면 전부 통과해서 크래시했을 입력들.
        for (final route in ['/profile/settings', '/home/ranking', '/history/badges']) {
          expect(
            NotificationDeepLink.resolveRaw(route, NotificationType.rankChange),
            Routes.home,
            reason: '$route 는 라우터에 없다',
          );
        }
      });

      test('뱃지 갤러리 딥링크는 쿼리를 유지한 채 통과한다', () {
        expect(
          NotificationDeepLink.resolveRaw(Routes.badgeGallery, null),
          Routes.badgeGallery,
        );
        expect(Routes.badgeGallery, '/history?tab=badges');
      });

      test('러닝 상세는 세그먼트 하나만 허용한다', () {
        expect(
          NotificationDeepLink.resolveRaw('/history/run/r1', null),
          '/history/run/r1',
        );
        // 중첩 경로는 라우터에 없다 → 폴백.
        expect(
          NotificationDeepLink.resolveRaw('/history/run/r1/edit', null),
          Routes.notifications,
        );
      });
    });
  });

  group('설정 화면 노출 목록', () {
    test('NT-07(포인트)은 Phase 4라 토글에 나오지 않는다', () {
      expect(
        NotificationSettings.configurableTypes,
        isNot(contains(NotificationType.points)),
      );
      expect(NotificationSettings.configurableTypes, hasLength(6));
    });

    test('모든 노출 종류에 라벨과 설명이 있다', () {
      for (final type in NotificationSettings.configurableTypes) {
        expect(NotificationDisplay.labelOf(type), isNotEmpty);
        expect(NotificationDisplay.descriptionOf(type), isNotEmpty);
      }
    });
  });

  group('상대 시각', () {
    final now = DateTime(2026, 8, 28, 15, 0);

    test('1분 미만은 방금 전', () {
      expect(
        NotificationDisplay.relativeTime(
          now.subtract(const Duration(seconds: 20)),
          now: now,
        ),
        '방금 전',
      );
    });

    test('같은 날은 시간 단위', () {
      expect(
        NotificationDisplay.relativeTime(
          now.subtract(const Duration(hours: 3)),
          now: now,
        ),
        '3시간 전',
      );
    });

    test('날짜가 바뀌면 시간 단위로 말하지 않는다', () {
      // 22시간 전이지만 어제다 — "22시간 전"은 어제인지 오늘인지 알기 어렵다.
      expect(
        NotificationDisplay.relativeTime(
          now.subtract(const Duration(hours: 22)),
          now: now,
        ),
        '어제',
      );
    });

    test('그 이전은 날짜로 말한다', () {
      expect(
        NotificationDisplay.relativeTime(
          DateTime(2026, 8, 20, 9),
          now: now,
        ),
        '8월 20일',
      );
    });
  });

  group('미읽음 배지', () {
    test('세 자리부터는 99+', () {
      expect(NotificationDisplay.unreadBadgeLabel(99), '99');
      expect(NotificationDisplay.unreadBadgeLabel(100), '99+');
    });
  });
}
