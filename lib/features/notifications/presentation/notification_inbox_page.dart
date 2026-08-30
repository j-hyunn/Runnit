import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/notifications/notification_deep_link.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_shell.dart';
import '../../../models/models.dart';
import '../data/notification_providers.dart';
import 'widgets/notification_tile.dart';

/// 알림함 (`/notifications`, PRD §5.10).
///
/// ## 읽음 처리는 뷰포트 진입 기준이다
/// 목록을 열자마자 전체를 읽음 처리하지 않는다(architect §3.2). 실제로 화면에
/// 보인 항목만 모아 [NotificationInboxController.markRead]로 넘기고, "모두 읽음"은
/// 헤더의 **명시 액션**으로 따로 둔다.
///
/// 개별 요청을 항목마다 보내지 않고 500ms 동안 모아 한 번에 보낸다 — 빠르게
/// 스크롤하면 20건이 순식간에 보이고, 그때마다 RPC를 부르면 요청이 20개 뜬다.
///
/// ## 목록은 설정으로 거르지 않는다
/// `NotificationSettings.isEnabled`로 필터하면 마스터 스위치를 끈 사용자의
/// 알림함이 통째로 비어 보인다(backend §2.5). 서버가 만들어 준 행이 곧 목록이다.
class NotificationInboxPage extends ConsumerStatefulWidget {
  const NotificationInboxPage({super.key});

  @override
  ConsumerState<NotificationInboxPage> createState() =>
      _NotificationInboxPageState();
}

class _NotificationInboxPageState extends ConsumerState<NotificationInboxPage> {
  /// 스크롤이 움직일 때마다 증가 — 각 타일의 가시성 재판정 트리거.
  final _scrollTick = ValueNotifier<int>(0);
  final _pendingRead = <String>{};
  Timer? _readTimer;

  @override
  void dispose() {
    _readTimer?.cancel();
    _scrollTick.dispose();
    super.dispose();
  }

  void _reportVisible(String id) {
    _pendingRead.add(id);
    _readTimer?.cancel();
    _readTimer = Timer(const Duration(milliseconds: 500), _flushRead);
  }

  void _flushRead() {
    if (_pendingRead.isEmpty || !mounted) return;
    final ids = _pendingRead.toList(growable: false);
    _pendingRead.clear();
    unawaited(
      ref.read(notificationInboxProvider.notifier).markRead(ids),
    );
  }

  void _open(AppNotification notification) {
    // 탭한 알림은 즉시 읽음 — 뷰포트 판정을 기다릴 이유가 없다.
    unawaited(
      ref.read(notificationInboxProvider.notifier).markRead([notification.id]),
    );
    final route = NotificationDeepLink.resolve(notification);
    // 자기 자신으로 가는 딥링크(알림함)면 화면을 쌓지 않는다.
    if (route == Routes.notifications) return;
    context.go(route);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _scrollTick.value++;
    }
    final metrics = notification.metrics;
    if (metrics.pixels >= metrics.maxScrollExtent - 320) {
      unawaited(ref.read(notificationInboxProvider.notifier).loadMore());
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(notificationInboxProvider);
    final unread = ref.watch(unreadNotificationCountProvider).valueOrNull ?? 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _InboxHeader(
              showMarkAll: unread > 0,
              onMarkAll: () => unawaited(
                ref.read(notificationInboxProvider.notifier).markAllRead(),
              ),
            ),
            Expanded(
              child: inbox.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (_, __) => _InboxError(
                  onRetry: () => ref.invalidate(notificationInboxProvider),
                ),
                data: (state) => state.isEmpty
                    ? const _InboxEmpty()
                    : _InboxList(
                        state: state,
                        scrollTick: _scrollTick,
                        onScroll: _onScroll,
                        onVisible: _reportVisible,
                        onTap: _open,
                        onRefresh: () => ref
                            .read(notificationInboxProvider.notifier)
                            .refresh(),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxHeader extends StatelessWidget {
  const _InboxHeader({required this.showMarkAll, required this.onMarkAll});

  final bool showMarkAll;
  final VoidCallback onMarkAll;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 다른 화면 헤더(홈/마이)와 같은 여백 규약.
      padding: const EdgeInsets.fromLTRB(12, 15, 24, 15),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 20),
              color: Colors.black,
              tooltip: '뒤로',
              onPressed: () => context.canPop()
                  ? context.pop()
                  : context.go(Routes.profile),
            ),
            const Expanded(
              child: Text(
                '알림',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
            ),
            if (showMarkAll)
              TextButton(
                onPressed: onMarkAll,
                child: const Text(
                  '모두 읽음',
                  style: TextStyle(fontSize: 14, color: Color(0xFF616161)),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.settings_outlined, size: 22),
              color: Colors.black,
              tooltip: '알림 설정',
              onPressed: () => context.push(Routes.notificationSettings),
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxList extends StatelessWidget {
  const _InboxList({
    required this.state,
    required this.scrollTick,
    required this.onScroll,
    required this.onVisible,
    required this.onTap,
    required this.onRefresh,
  });

  final NotificationInboxState state;
  final ValueNotifier<int> scrollTick;
  final bool Function(ScrollNotification) onScroll;
  final void Function(String id) onVisible;
  final void Function(AppNotification) onTap;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: onScroll,
      child: RefreshIndicator(
        onRefresh: onRefresh,
        child: ValueListenableBuilder<double>(
          valueListenable: AppShell.measuredHeight,
          builder: (context, navHeight, _) => ListView.separated(
            padding: EdgeInsets.only(
              left: AppTokens.s16,
              right: AppTokens.s16,
              bottom: navHeight + AppTokens.s16,
            ),
            // 마지막 항목은 "더 불러오는 중" 자리다.
            itemCount: state.items.length + (state.hasMore ? 1 : 0),
            separatorBuilder: (_, __) => const SizedBox(height: AppTokens.s8),
            itemBuilder: (context, index) {
              if (index >= state.items.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppTokens.s24),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }

              final item = state.items[index];
              return ClipRRect(
                borderRadius: BorderRadius.circular(AppTokens.rLg),
                child: ViewportVisibilityReporter(
                  enabled: !item.isRead,
                  tick: scrollTick,
                  onVisible: () => onVisible(item.id),
                  child: NotificationTile(
                    notification: item,
                    onTap: () => onTap(item),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 빈 상태 — 알림은 러닝을 해야 생기므로 첫 러닝으로 잇는다(architect §7).
class _InboxEmpty extends StatelessWidget {
  const _InboxEmpty();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.s24,
        vertical: AppTokens.s40,
      ),
      children: [
        const SizedBox(height: AppTokens.s40),
        Icon(
          Icons.notifications_none,
          size: 56,
          color: Colors.black.withValues(alpha: 0.18),
        ),
        const SizedBox(height: AppTokens.s16),
        const Text(
          '아직 받은 알림이 없어요',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: AppTokens.s8),
        const Text(
          '러닝을 기록하면 티어 승급, 순위 변동, 뱃지 획득 소식이 여기에 쌓여요.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.5, color: Color(0xFF616161)),
        ),
        const SizedBox(height: AppTokens.s24),
        Center(
          child: FilledButton(
            onPressed: () => context.go(Routes.tracking),
            child: const Text('러닝 시작하기'),
          ),
        ),
      ],
    );
  }
}

class _InboxError extends StatelessWidget {
  const _InboxError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // `Failure`는 union이라 모든 갈래가 message를 갖지 않는다. 원인별 문구를
    // 짜맞추기보다, 사용자가 할 수 있는 행동(재시도) 하나를 분명히 준다.
    const message = '알림을 불러오지 못했어요.\n네트워크 상태를 확인하고 다시 시도해 주세요.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF616161)),
            ),
            const SizedBox(height: AppTokens.s16),
            OutlinedButton(onPressed: onRetry, child: const Text('다시 시도')),
          ],
        ),
      ),
    );
  }
}
