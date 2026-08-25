import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/error/failure.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/route_access.dart';
import '../../../core/theme/app_tokens.dart';
import 'widgets/kakao_login_button.dart';

/// 카카오 전용 로그인 화면 + 게스트 진입점.
///
/// 이 화면이 지키는 계약(mobile-architect 확정):
/// 1. 로그인 버튼 → `authControllerProvider.notifier.signInWithKakao()`.
///    카카오가 **유일한** 로그인 수단이다. 다른 진입점을 추가하지 말 것.
/// 2. **성공 판정을 이 화면이 하지 않는다.** `signInWithKakao()`의 반환은
///    "브라우저를 띄우는 데 성공"일 뿐이다. 세션이 붙으면 라우터 `redirect`가
///    `?from=` 경로(없으면 `/tracking`)로 자동 이동시킨다.
///    → 여기서 `context.go()`로 직접 이동시키지 않는다.
///    → 스피너는 `authControllerProvider`의 로딩에만 묶는다(무한 로딩 금지).
/// 3. "둘러보기" → 게스트 랜딩(`/ranking`). 게스트가 볼 수 있는 곳은
///    랭킹과 뱃지 카탈로그뿐이다.
/// 4. `authControllerProvider`가 `AsyncError`면 `error`는 항상 [Failure]다.
class LoginPage extends ConsumerWidget {
  const LoginPage({super.key});

  void _continueAsGuest(BuildContext context) {
    // 보호 라우트에서 밀려온 경우(스택이 있으면) 뒤로, 아니면 게스트 랜딩으로.
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(RouteAccess.guestLanding);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final action = ref.watch(authControllerProvider);
    final failure = action.error is Failure ? action.error! as Failure : null;

    // 에러는 인라인 배너 + 스낵바 양쪽으로 알린다.
    // (배너는 화면 하단이라 스크롤로 가려질 수 있고, 스낵바는 즉시성이 있다.)
    ref.listen<AsyncValue<void>>(authControllerProvider, (prev, next) {
      if (next.hasError && next.error is Failure) {
        // 스낵바는 `ScaffoldMessenger`의 오버레이로 떠서 이 위젯보다 오래
        // 살 수 있다 — 액션 콜백 안에서 `ref`를 다시 참조하면(위젯이 그
        // 사이 폐기된 경우) "Cannot use ref after disposed"로 죽는다.
        // 여기서 notifier 객체 자체를 미리 꺼내 캡처해 두면, 이후 버튼을
        // 눌러도 `ref`가 아니라 이 안정적인 객체를 통해서만 호출한다.
        final notifier = ref.read(authControllerProvider.notifier);
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(_LoginCopy.failureMessage(next.error! as Failure)),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '다시 시도',
              onPressed: notifier.signInWithKakao,
            ),
          ),
        );
      }
    });

    final from = GoRouterState.of(context)
        .uri
        .queryParameters[Routes.fromQueryParam];
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 작은 화면(SE급)에서도 잘리지 않도록 스크롤 + 최소 높이 확보.
            return SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTokens.s24,
                vertical: AppTokens.s24,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - AppTokens.s24 * 2,
                  maxWidth: AppTokens.contentMaxWidth,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppTokens.contentMaxWidth,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _BrandHeader(),
                        const SizedBox(height: AppTokens.s32),

                        // 왜 로그인 화면에 왔는지 설명 (가드로 밀려온 경우).
                        if (_LoginCopy.reasonFor(from) != null) ...[
                          _ReasonBanner(text: _LoginCopy.reasonFor(from)!),
                          const SizedBox(height: AppTokens.s20),
                        ],

                        Text(
                          '카카오로 3초 만에 시작하기',
                          textAlign: TextAlign.center,
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: AppTokens.s8),
                        Text(
                          '별도 가입 없이 카카오 계정으로 바로 달리기 시작.\n'
                          '기록 · 랭킹 · 뱃지가 계정에 저장돼요.',
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: AppTokens.s24),

                        if (failure != null) ...[
                          _ErrorBanner(
                            message: _LoginCopy.failureMessage(failure),
                            detail: _LoginCopy.failureDetail(failure),
                            onDismiss: () => ref
                                .read(authControllerProvider.notifier)
                                .clearError(),
                          ),
                          const SizedBox(height: AppTokens.s16),
                        ],

                        KakaoLoginButton(
                          isLoading: action.isLoading,
                          onPressed: () => ref
                              .read(authControllerProvider.notifier)
                              .signInWithKakao(),
                        ),
                        const SizedBox(height: AppTokens.s12),

                        TextButton(
                          onPressed: action.isLoading
                              ? null
                              : () => _continueAsGuest(context),
                          style: TextButton.styleFrom(
                            minimumSize:
                                const Size.fromHeight(AppTokens.minTapTarget),
                          ),
                          child: const Text('게스트로 둘러보기'),
                        ),
                        const SizedBox(height: AppTokens.s8),
                        Text(
                          '게스트는 랭킹과 뱃지 카탈로그만 볼 수 있어요.',
                          textAlign: TextAlign.center,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),

                        // 디버그 빌드에서만 보이는 개발자 뒷문. 카카오 로그인은
                        // 시뮬레이터에서 실계정으로 끝까지 완료할 수 없어(SMS 인증 등)
                        // 인증이 필요한 화면을 개발 중 확인할 방법이 없었다 — 이걸
                        // 우회하는 임시 로그인이다. release 빌드에는 아예 렌더링되지
                        // 않고, 대상 계정도 카카오 로그인 경로와 완전히 분리돼 있다.
                        if (kDebugMode) ...[
                          const SizedBox(height: AppTokens.s24),
                          const Divider(),
                          const SizedBox(height: AppTokens.s8),
                          TextButton.icon(
                            onPressed: action.isLoading
                                ? null
                                : () => ref
                                    .read(authControllerProvider.notifier)
                                    .signInWithTestAccount(),
                            icon: const Icon(Icons.bug_report_outlined,
                                size: 18),
                            label: const Text('[DEBUG] 테스트 계정으로 로그인'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 로고 자리 — 이미지 에셋이 없으므로 타이포 + 심볼로 구성한다.
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Column(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primaryContainer,
          ),
          child: Icon(
            Icons.directions_run,
            size: 44,
            color: scheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: AppTokens.s16),
        Text(
          'Runnit',
          textAlign: TextAlign.center,
          style: text.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: AppTokens.s4),
        Text(
          '함께 달리고, 함께 오른다',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

/// 가드에 막혀 왔을 때 "왜 여기로 왔는지" 알려주는 안내.
class _ReasonBanner extends StatelessWidget {
  const _ReasonBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.s16,
        vertical: AppTokens.s12,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTokens.rMd),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppTokens.s8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    required this.onDismiss,
    this.detail,
  });

  final String message;
  final String? detail;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.s16,
        AppTokens.s12,
        AppTokens.s8,
        AppTokens.s12,
      ),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(AppTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: AppTokens.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty) ...[
                  const SizedBox(height: AppTokens.s4),
                  Text(
                    detail!,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onErrorContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
            color: scheme.onErrorContainer,
            tooltip: '닫기',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// 로그인 화면의 문구 규칙을 한곳에 모은다.
class _LoginCopy {
  const _LoginCopy._();

  /// `?from=` 경로에 따라 "왜 로그인 화면으로 왔는지"를 설명한다.
  /// 게스트가 직접 로그인 탭을 눌러 온 경우(= from 없음)에는 null.
  ///
  /// 2026-08-21 4탭 개편 이후 `/home`·`/history`는 라우터 가드가 막지 않는다
  /// (게스트도 열람 가능). 그래도 이 문구가 필요한 이유: 그 화면들 **안의
  /// 인라인 CTA**(크루/친구 탭, "내 순위 보기", 기록 탭 등)가 `context.goToLogin()`을
  /// 호출할 때 현재 위치를 그대로 `from`에 실어 보내기 때문이다.
  static String? reasonFor(String? from) {
    if (from == null || from.isEmpty) return null;
    if (from.startsWith(Routes.tracking)) {
      return '러닝을 시작하려면 로그인이 필요해요. 기록이 계정에 안전하게 저장돼요.';
    }
    if (from.startsWith(Routes.profile)) {
      return '내 프로필과 레벨을 보려면 로그인이 필요해요.';
    }
    if (from.startsWith(Routes.history)) {
      return '내 러닝 기록과 획득한 뱃지를 확인하려면 로그인이 필요해요.';
    }
    if (from.startsWith(Routes.home)) {
      return '내 티어와 순위, 크루·친구 랭킹은 로그인 후 볼 수 있어요.';
    }
    return null;
  }

  /// [Failure] → 사용자용 한 줄 메시지.
  static String failureMessage(Failure failure) {
    if (failure is NetworkFailure) {
      return '네트워크 연결을 확인해 주세요.';
    }
    if (failure is UnauthorizedFailure) {
      return '카카오 로그인에 실패했어요. 잠시 후 다시 시도해 주세요.';
    }
    return '로그인 중 문제가 발생했어요. 다시 시도해 주세요.';
  }

  /// 원인 파악에 도움이 되는 서버 메시지(있을 때만).
  static String? failureDetail(Failure failure) {
    if (failure is NetworkFailure) return failure.message;
    if (failure is UnauthorizedFailure) return failure.message;
    if (failure is UnknownFailure) return failure.message;
    return null;
  }
}
