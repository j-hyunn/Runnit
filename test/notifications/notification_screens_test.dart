import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/notifications/push_permission.dart';
import 'package:runnit/core/providers/repository_providers.dart';
import 'package:runnit/core/repositories/notification_repository.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/notifications/presentation/notification_inbox_page.dart';
import 'package:runnit/features/notifications/presentation/notification_settings_page.dart';
import 'package:runnit/features/notifications/presentation/widgets/notification_tile.dart';
import 'package:runnit/models/models.dart';

/// 알림함·알림 설정 화면의 **규칙**을 검증한다.
///
/// 문구 자체(서버가 완성해 내려주는 title/body)는 검증 대상이 아니다. 이 화면이
/// 지켜야 하는 것은 셋이다:
/// 1. 목록을 열자마자 전체를 읽음 처리하지 않는다 — 뷰포트에 보인 것만.
/// 2. NT-07(포인트)은 설정 화면에 나오지 않는다.
/// 3. 마스터 스위치를 꺼도 종류별 토글의 **원래 값**은 그대로 보인다.
class _FakeNotificationRepository implements NotificationRepository {
  _FakeNotificationRepository({
    this.inbox = const <AppNotification>[],
    NotificationSettings? settings,
    this.unread = 0,
  }) : settings = settings ?? NotificationSettings.defaultsFor('u1');

  List<AppNotification> inbox;
  NotificationSettings settings;
  int unread;

  final markReadCalls = <List<String>>[];
  var markAllReadCalls = 0;

  @override
  Future<List<AppNotification>> fetchInbox({
    required String userId,
    DateTime? before,
    int limit = 30,
  }) async =>
      before == null ? inbox : const <AppNotification>[];

  @override
  Future<int> fetchUnreadCount(String userId) async => unread;

  @override
  Stream<void> watchIncoming(String userId) => const Stream<void>.empty();

  @override
  Future<void> markRead(List<String> notificationIds) async {
    markReadCalls.add(notificationIds);
  }

  @override
  Future<void> markAllRead(String userId) async => markAllReadCalls++;

  @override
  Future<NotificationSettings?> fetchSettings(String userId) async => settings;

  @override
  Future<NotificationSettings> updateSetting({
    required String userId,
    required NotificationType type,
    required bool enabled,
  }) async {
    settings = settings.withType(type, enabled);
    return settings;
  }

  @override
  Future<NotificationSettings> updatePushEnabled({
    required String userId,
    required bool enabled,
  }) async {
    settings = settings.copyWith(pushEnabled: enabled);
    return settings;
  }

  @override
  Future<void> upsertToken(PushDeviceToken token) async {}

  @override
  Future<void> deleteToken(String token) async {}
}

void main() {
  AppNotification item(
    String id, {
    bool read = false,
    NotificationType type = NotificationType.rankChange,
  }) =>
      AppNotification(
        id: id,
        userId: 'u1',
        type: type,
        title: '알림 $id',
        body: '서버가 완성한 본문 $id',
        createdAt: DateTime.utc(2026, 8, 28, 9).subtract(Duration(minutes: int.parse(id))),
        readAt: read ? DateTime.utc(2026, 8, 28, 10) : null,
      );

  Future<void> pump(
    WidgetTester tester,
    Widget page,
    _FakeNotificationRepository repo, {
    PushPermissionStatus permission = PushPermissionStatus.granted,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue('u1'),
          notificationRepositoryProvider.overrideWithValue(repo),
          pushPermissionStatusProvider.overrideWith((ref) async => permission),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('알림함', () {
    testWidgets('빈 상태는 첫 러닝으로 잇는다', (tester) async {
      final repo = _FakeNotificationRepository();
      await pump(tester, const NotificationInboxPage(), repo);

      expect(find.text('아직 받은 알림이 없어요'), findsOneWidget);
      expect(find.text('러닝 시작하기'), findsOneWidget);
    });

    testWidgets('화면에 보인 미읽음만 읽음 처리한다', (tester) async {
      // 화면에 다 들어가지 않을 만큼 만든다 — 아래쪽 항목은 읽음이 되면 안 된다.
      final repo = _FakeNotificationRepository(
        inbox: [for (var i = 1; i <= 30; i++) item('$i')],
        unread: 30,
      );
      await pump(tester, const NotificationInboxPage(), repo);

      // 읽음 요청은 500ms 모아 보낸다.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      final reported = repo.markReadCalls.expand((ids) => ids).toSet();
      expect(reported, isNotEmpty, reason: '보인 항목은 읽음 처리돼야 한다');
      expect(
        reported.length,
        lessThan(30),
        reason: '목록 진입만으로 전체가 읽음이 되면 미읽음 신호가 죽는다',
      );
      // 맨 아래 항목은 아직 화면 밖이다.
      expect(reported, isNot(contains('30')));
    });

    testWidgets('이미 읽은 알림은 다시 읽음 요청하지 않는다', (tester) async {
      final repo = _FakeNotificationRepository(
        inbox: [item('1', read: true), item('2', read: true)],
      );
      await pump(tester, const NotificationInboxPage(), repo);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(repo.markReadCalls, isEmpty);
      expect(find.byType(NotificationTile), findsNWidgets(2));
    });

    testWidgets('"모두 읽음"은 미읽음이 있을 때만 나온다', (tester) async {
      final repo = _FakeNotificationRepository(
        inbox: [item('1', read: true)],
      );
      await pump(tester, const NotificationInboxPage(), repo);
      expect(find.text('모두 읽음'), findsNothing);
    });
  });

  group('알림 설정', () {
    testWidgets('NT-07(포인트)은 토글에 없다', (tester) async {
      final repo = _FakeNotificationRepository();
      await pump(tester, const NotificationSettingsPage(), repo);

      expect(find.text('포인트'), findsNothing);
      // 마스터 1개 + 종류 6개.
      expect(find.byType(Switch), findsNWidgets(7));
    });

    testWidgets('마스터를 꺼도 종류별 토글의 원래 값은 그대로 보인다', (tester) async {
      final repo = _FakeNotificationRepository(
        settings: NotificationSettings.defaultsFor('u1').copyWith(
          pushEnabled: false,
          rankChange: false,
        ),
      );
      await pump(tester, const NotificationSettingsPage(), repo);

      final switches =
          tester.widgetList<Switch>(find.byType(Switch)).toList();
      // 첫 번째가 마스터.
      expect(switches.first.value, isFalse);
      // 나머지는 비활성(onChanged == null)이지만 값은 살아 있다.
      final typeSwitches = switches.skip(1).toList();
      expect(typeSwitches.every((s) => s.onChanged == null), isTrue);
      expect(
        typeSwitches.where((s) => s.value).length,
        5,
        reason: 'rankChange 하나만 off — isEnabled가 아니라 rawFlag를 그려야 한다',
      );
    });

    testWidgets('OS 알림이 꺼져 있으면 시스템 설정 안내를 띄운다', (tester) async {
      final repo = _FakeNotificationRepository();
      await pump(
        tester,
        const NotificationSettingsPage(),
        repo,
        permission: PushPermissionStatus.denied,
      );

      expect(find.text('휴대폰 설정에서 알림이 꺼져 있어요'), findsOneWidget);
      expect(find.text('시스템 설정 열기'), findsOneWidget);
    });

    testWidgets('FCM 미설정 빌드에서는 권한 안내를 띄우지 않는다', (tester) async {
      final repo = _FakeNotificationRepository();
      await pump(
        tester,
        const NotificationSettingsPage(),
        repo,
        permission: PushPermissionStatus.unavailable,
      );

      expect(find.text('휴대폰 설정에서 알림이 꺼져 있어요'), findsNothing);
    });

    testWidgets('토글을 끄면 그 종류 하나만 갱신한다', (tester) async {
      final repo = _FakeNotificationRepository();
      await pump(tester, const NotificationSettingsPage(), repo);

      // 두 번째 스위치 = configurableTypes의 첫 종류(티어 승급).
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      expect(repo.settings.tierPromotion, isFalse);
      expect(repo.settings.tierProximity, isTrue, reason: '다른 컬럼은 건드리지 않는다');
    });
  });
}
