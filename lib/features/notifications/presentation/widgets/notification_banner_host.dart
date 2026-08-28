import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/notifications/push_messaging.dart';
import '../../../../core/notifications/push_permission.dart';
import '../../data/notification_providers.dart';

/// 포그라운드 푸시의 인앱 배너.
///
/// ## 성취 계열은 여기까지 오지 않는다
/// `PushMessagingService`가 `isAchievement`(NT-01·NT-06)를 스트림에 흘리기 전에
/// 걸러낸다 — 몇 초 뒤 `AchievementCelebrationHost`의 축하 풀페이지가 뜨므로,
/// 배너까지 띄우면 같은 사건을 두 번 알리게 된다(ARCHITECTURE §7.5.2).
/// 이 위젯은 그 호스트와 **공존만** 하고 큐를 건드리지 않는다.
///
/// 표시 수단으로 커스텀 오버레이 대신 `SnackBar`를 쓰는 이유: 축하 풀페이지와
/// 겹칠 때 누가 위에 오는지가 명확하고(풀페이지가 덮는다), 사용자가 이미 아는
/// 상호작용이다.
///
/// ## 앱 복귀 시 미읽음을 다시 읽는다
/// 앱 복귀 시 미읽음 배지도 여기서 다시 읽는다 — realtime 소켓은 장시간
/// 백그라운드 뒤 끊겨 있을 수 있고, 그동안 도착한 알림은 신호가 오지 않는다
/// (architect §3.3의 갱신 트리거 ③).
class NotificationBannerHost extends ConsumerStatefulWidget {
  const NotificationBannerHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<NotificationBannerHost> createState() =>
      _NotificationBannerHostState();
}

class _NotificationBannerHostState
    extends ConsumerState<NotificationBannerHost> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(unreadNotificationCountProvider);
      // 권한은 시스템 설정에서 바뀔 수 있다 — 돌아왔을 때 안내가 남아 있으면 안 된다.
      ref.invalidate(pushPermissionStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pushBannerProvider, (_, next) {
      final banner = next.valueOrNull;
      if (banner == null) return;

      // 알림함·배지는 서버 realtime로도 갱신되지만, 포그라운드 수신은 그보다
      // 확실한 신호다 — 즉시 다시 읽는다.
      ref.invalidate(unreadNotificationCountProvider);
      ref.invalidate(notificationInboxProvider);

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            behavior: SnackBarBehavior.floating,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  banner.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (banner.body.isNotEmpty) Text(banner.body),
              ],
            ),
            action: SnackBarAction(
              label: '보기',
              onPressed: () =>
                  ref.read(pushMessagingProvider).navigateTo(banner.route),
            ),
          ),
        );
    });

    return widget.child;
  }
}
