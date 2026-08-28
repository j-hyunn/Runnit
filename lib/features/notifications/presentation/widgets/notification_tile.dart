import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../models/models.dart';
import '../../domain/notification_display.dart';

/// 알림함 목록의 한 줄.
///
/// 서버가 완성한 [AppNotification.title]/[AppNotification.body]를 **그대로**
/// 그린다. 미읽음은 배경 톤과 좌측 점으로 구분한다 — 굵기만 다르게 하면
/// 스크롤 중에 구분이 사라진다.
class NotificationTile extends StatelessWidget {
  const NotificationTile({
    required this.notification,
    required this.onTap,
    super.key,
  });

  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = !notification.isRead;
    final accent = NotificationDisplay.colorOf(notification.type);

    return Material(
      color: unread ? const Color(0xFFF2FBF5) : Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.s16,
            vertical: AppTokens.s16,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTokens.rMd),
                ),
                alignment: Alignment.center,
                child: Icon(
                  NotificationDisplay.iconOf(notification.type),
                  size: 20,
                  color: accent,
                ),
              ),
              const SizedBox(width: AppTokens.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppTokens.s8),
                        Text(
                          NotificationDisplay.relativeTime(
                            notification.createdAt,
                          ),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF9B9B9B),
                          ),
                        ),
                      ],
                    ),
                    if (notification.body.isNotEmpty) ...[
                      const SizedBox(height: AppTokens.s4),
                      Text(
                        notification.body,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: Color(0xFF616161),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (unread) ...[
                const SizedBox(width: AppTokens.s8),
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF00C84B),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 자식이 **스크롤 뷰포트 안에 실제로 보였을 때** 한 번만 알린다.
///
/// ## 왜 "목록을 열면 전체 읽음"이 아닌가
/// 그렇게 하면 미읽음이라는 신호 자체가 죽는다(architect §3.2) — 알림 30건이
/// 쌓인 사용자가 화면을 잠깐 열었다 닫으면 못 본 29건이 전부 읽음이 된다.
///
/// ## 왜 별도 패키지를 쓰지 않는가
/// `visibility_detector`를 이 하나 때문에 추가하지 않는다. 필요한 것은
/// "뷰포트 사각형과 겹치는가" 한 줄뿐이고, 그건 `RenderBox` 좌표 비교로 끝난다.
///
/// [tick]은 스크롤이 움직일 때마다 증가하는 값이다. 자식이 처음 build될 때와
/// 스크롤이 바뀔 때마다 다시 판정한다 — lazy build만 믿으면 `cacheExtent` 때문에
/// **화면 밖에서 미리 만들어진** 항목까지 읽음이 된다.
class ViewportVisibilityReporter extends StatefulWidget {
  const ViewportVisibilityReporter({
    required this.enabled,
    required this.tick,
    required this.onVisible,
    required this.child,
    super.key,
  });

  /// false면 판정 자체를 하지 않는다(이미 읽은 알림).
  final bool enabled;
  final ValueListenable<int> tick;
  final VoidCallback onVisible;
  final Widget child;

  @override
  State<ViewportVisibilityReporter> createState() =>
      _ViewportVisibilityReporterState();
}

class _ViewportVisibilityReporterState
    extends State<ViewportVisibilityReporter> {
  var _reported = false;

  @override
  void initState() {
    super.initState();
    widget.tick.addListener(_schedule);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant ViewportVisibilityReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tick != widget.tick) {
      oldWidget.tick.removeListener(_schedule);
      widget.tick.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void dispose() {
    widget.tick.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() {
    if (_reported || !widget.enabled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (_reported || !widget.enabled || !mounted) return;

    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final viewportBox =
        Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return;

    final origin = box.localToGlobal(Offset.zero, ancestor: viewportBox);
    final self = origin & box.size;
    final viewport = Offset.zero & viewportBox.size;
    final overlap = self.intersect(viewport);

    // 절반 이상(또는 최소 24px)이 보여야 "읽었다"고 본다. 스크롤 도중 살짝
    // 걸친 1px까지 읽음 처리하면 목록 진입 즉시 전체 읽음과 다를 게 없다.
    final threshold = (box.size.height * 0.5).clamp(1.0, 24.0);
    if (overlap.height >= threshold && overlap.width > 0) {
      _reported = true;
      widget.onVisible();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
