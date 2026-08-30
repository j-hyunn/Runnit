import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/notifications/push_permission.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/widgets/app_shell.dart';
import '../../../models/models.dart';
import '../data/notification_providers.dart';
import '../domain/notification_display.dart';

/// 알림 설정 (`/notifications/settings`, PRD §5.10 NT-08).
///
/// ## 토글을 하나씩 하드코딩하지 않는다
/// [NotificationSettings.configurableTypes]를 순회해 그린다. 종류가 늘어도 화면을
/// 고칠 필요가 없고, **NT-07(포인트, Phase 4)은 자동으로 빠진다** — 동작하지 않는
/// 스위치를 만들지 않기 위한 장치다(architect §1.3).
///
/// ## 마스터 스위치가 꺼져도 개별 값은 그대로 보여준다
/// [NotificationSettings.rawFlag]를 그린다. `isEnabled`를 쓰면 마스터를 끈 순간
/// 개별 토글이 전부 off로 보이고, 다시 켰을 때 사용자가 예전에 끈 항목이
/// 무엇이었는지 알 수 없게 된다.
///
/// ## 크루 알림은 없다
/// Runnit은 개인 중심 앱이다(PRD §2.3·§5.9 — 크루는 P2). 이 화면에 크루 관련
/// 항목을 추가하지 않는다.
class NotificationSettingsPage extends ConsumerWidget {
  const NotificationSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(notificationSettingsProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F8F8),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _SettingsHeader(),
            Expanded(
              child: settings.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => _SettingsError(
                  onRetry: () => ref.invalidate(notificationSettingsProvider),
                ),
                data: (value) => _SettingsBody(settings: value),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                '알림 설정',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsBody extends ConsumerWidget {
  const _SettingsBody({required this.settings});

  final NotificationSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(notificationSettingsProvider.notifier);
    final types = NotificationSettings.configurableTypes;

    return ValueListenableBuilder<double>(
      valueListenable: AppShell.measuredHeight,
      builder: (context, navHeight, _) => ListView(
        padding: EdgeInsets.fromLTRB(
          AppTokens.s16,
          0,
          AppTokens.s16,
          navHeight + AppTokens.s24,
        ),
        children: [
          const _SystemPermissionNotice(),
          _SettingsCard(
            children: [
              _SwitchRow(
                label: '푸시 알림 받기',
                description: '끄면 어떤 푸시도 오지 않아요. '
                    '받은 알림은 이 앱의 알림함에서 계속 볼 수 있어요.',
                value: settings.pushEnabled,
                onChanged: (value) => _guard(
                  context,
                  () => controller.setPushEnabled(value),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.s16),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTokens.s4,
              0,
              AppTokens.s4,
              AppTokens.s8,
            ),
            child: Text(
              '알림 종류',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.black.withValues(alpha: 0.5),
              ),
            ),
          ),
          _SettingsCard(
            children: [
              for (final type in types)
                _SwitchRow(
                  label: NotificationDisplay.labelOf(type),
                  description: NotificationDisplay.descriptionOf(type),
                  // 마스터가 꺼져 있어도 **원래 값**을 그린다.
                  value: settings.rawFlag(type),
                  enabled: settings.pushEnabled,
                  onChanged: (value) => _guard(
                    context,
                    () => controller.setType(type, value),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppTokens.s16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppTokens.s4),
            child: Text(
              '알림 문구와 발송 시점은 서버가 정합니다. '
              '방해가 되지 않도록 순위·시즌 알림은 낮 시간에만 보내요.',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Color(0xFF9B9B9B),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 저장 실패는 스낵바로만 알린다 — 화면을 에러로 바꾸면 다른 토글까지
  /// 못 쓰게 된다. 값 자체는 컨트롤러가 이미 롤백했다.
  void _guard(BuildContext context, Future<void> Function() action) {
    unawaited(() async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await action();
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(content: Text('설정을 저장하지 못했어요. 잠시 후 다시 시도해 주세요.')),
        );
      }
    }());
  }
}

/// OS 알림 권한이 꺼져 있을 때의 안내. 앱 안에서는 되돌릴 수 없으므로
/// **시스템 설정으로 보내는 것**이 유일한 복구 경로다.
class _SystemPermissionNotice extends ConsumerWidget {
  const _SystemPermissionNotice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pushPermissionStatusProvider).valueOrNull;
    // unavailable(=FCM 미설정 빌드)에는 아무것도 띄우지 않는다 — 사용자가 할 수
    // 있는 일이 없는 안내는 소음이다.
    if (status == null || !status.needsSystemSettings) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: AppTokens.s16),
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(AppTokens.rLg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.notifications_off_outlined,
              size: 20, color: Color(0xFFB26A00)),
          const SizedBox(width: AppTokens.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '휴대폰 설정에서 알림이 꺼져 있어요',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF7A4A00),
                  ),
                ),
                const SizedBox(height: AppTokens.s4),
                const Text(
                  '아래 설정을 켜 두어도 알림이 도착하지 않아요.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF7A4A00)),
                ),
                const SizedBox(height: AppTokens.s8),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () =>
                      unawaited(openSystemNotificationSettings()),
                  child: const Text('시스템 설정 열기'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2.5),
        ],
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Divider(height: 1, thickness: 1, color: Color(0xFFEAEAEA)),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String description;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      // 비활성일 때도 값은 보인다 — 흐리게만 한다(마스터를 다시 켜면 그대로 복귀).
      opacity: enabled ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.s16,
          vertical: AppTokens.s12,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: AppTokens.s4),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Color(0xFF9B9B9B),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppTokens.s12),
            Switch.adaptive(
              value: value,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsError extends StatelessWidget {
  const _SettingsError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '알림 설정을 불러오지 못했어요.',
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
