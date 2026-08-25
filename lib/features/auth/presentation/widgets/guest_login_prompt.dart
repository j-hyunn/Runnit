import 'package:flutter/material.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_tokens.dart';

/// 게스트 허용 화면(랭킹 / 뱃지 카탈로그) 안에서 로그인을 유도하는 **배너 카드**.
///
/// 라우터 가드는 화면 단위로만 막으므로, 공개 화면 안의 개인화 기능은
/// 이렇게 명시적으로 유도한다. 탭하면 `context.goToLogin()` —
/// 현재 위치가 `?from=`으로 실려 로그인 후 이 화면으로 되돌아온다.
///
/// 로그인 상태에서는 **호출부가 아예 렌더하지 않는다**(이 위젯은 분기하지 않는다).
class GuestLoginPromptCard extends StatelessWidget {
  const GuestLoginPromptCard({
    required this.title,
    required this.message,
    this.icon = Icons.lock_outline,
    this.actionLabel = '카카오로 로그인',
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(AppTokens.s16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppTokens.rLg),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: scheme.onPrimaryContainer, size: 22),
          const SizedBox(width: AppTokens.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: AppTokens.s4),
                Text(
                  message,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: AppTokens.s8),
                Align(
                  alignment: Alignment.centerLeft,
                  // primaryContainer 위에 tonal 버튼을 얹으면 대비가 부족하다.
                  // CTA는 화면에서 가장 강한 대비를 가져야 하므로 primary 채움.
                  child: FilledButton(
                    onPressed: () => context.goToLogin(),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      shape: const StadiumBorder(),
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                    ),
                    child: Text(actionLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 게스트에게 **콘텐츠 자체가 없는** 영역(크루/친구 랭킹 탭 등)에 쓰는 전면 안내.
///
/// 빈 리스트를 그대로 보여주면 "데이터가 없는 건지 로그인이 필요한 건지"
/// 구분할 수 없다. 원인을 명시하고 곧바로 로그인으로 연결한다.
class GuestLoginGate extends StatelessWidget {
  const GuestLoginGate({
    required this.title,
    required this.message,
    this.icon = Icons.group_outlined,
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTokens.s24),
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.surfaceContainerHighest,
                ),
                child: Icon(icon, size: 34, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppTokens.s20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppTokens.s8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: text.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppTokens.s20),
              FilledButton.icon(
                onPressed: () => context.goToLogin(),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('카카오로 로그인'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(180, AppTokens.minTapTarget),
                  shape: const StadiumBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
