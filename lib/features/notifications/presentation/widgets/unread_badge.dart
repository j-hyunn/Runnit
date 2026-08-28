import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_tokens.dart';
import '../../data/notification_providers.dart';
import '../../domain/notification_display.dart';

/// 미읽음 개수 배지(빨간 점/숫자).
///
/// [unreadNotificationCountProvider] **하나만** 구독한다 — 목록을 받아 세면
/// 배지 하나 때문에 전체 payload를 내려받게 되고, 알림이 쌓일수록 비용이
/// 선형으로 는다(architect §3.3). 게스트는 그 provider가 항상 0을 준다.
class UnreadCountBadge extends ConsumerWidget {
  const UnreadCountBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 조회 실패·로딩 중에는 배지를 그리지 않는다. "알림이 있을지도 모른다"는
    // 애매한 표시는 배지를 신호가 아니라 소음으로 만든다.
    final count = ref.watch(unreadNotificationCountProvider).valueOrNull ?? 0;
    if (count <= 0) return const SizedBox.shrink();

    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFE5484D),
        borderRadius: BorderRadius.circular(AppTokens.rPill),
        // 아이콘 위에 겹쳐도 경계가 살도록 배경색 테두리를 두른다.
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        NotificationDisplay.unreadBadgeLabel(count),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// 헤더의 종 아이콘 + 미읽음 배지. 탭하면 알림함으로 간다.
///
/// 프로필 헤더의 "준비 중" 자리표시자를 대체한다.
class NotificationBellButton extends StatelessWidget {
  const NotificationBellButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '알림',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.rPill),
        onTap: () => context.push(Routes.notifications),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SvgPicture.asset('assets/icons/bell.svg', width: 24, height: 24),
            const Positioned(
              top: -6,
              right: -8,
              child: UnreadCountBadge(),
            ),
          ],
        ),
      ),
    );
  }
}
