/// 성취 축하 연출(HI-10)과 그 종착점인 공유 버튼.
///
/// ## 데이터는 전부 이미 있다
/// 티어 승급·PB·뱃지는 서버가 셋 다 `user_badges` INSERT로 끝내므로 감지 경로는
/// **하나**다(`pendingAchievementsProvider`). 이 파일은 그 큐를 화면에 옮기는
/// 일만 한다 — 새 조회도, 클라이언트 판정도 없다.
///
/// ## 한 번에 하나
/// 10km 달성 러닝 하나가 뱃지를 다섯 개 터뜨리는 일이 실제로 있다. 풀페이지
/// 다섯 장이 쌓이면 아무것도 축하가 되지 않으므로 큐 맨 앞 1건만 연출하고,
/// 사용자가 닫으면 `markAchievementsSeen`으로 큐를 한 칸 밀어 다음 건이 뜬다.
///
/// ## 큐에 뜬 것은 이미 서버 확정이다
/// `evaluate_badges()`는 `is_flagged = false`인 기록만 근거로 판정하고 지급 시
/// `verified = true`로 넣는다. 즉 **큐에 있다는 사실 자체가 검증 통과**라
/// 여기서는 공유 버튼을 망설일 이유가 없다. 반대로 요약 화면의 "이번 러닝"
/// 블록은 아직 확정 전일 수 있어 [AchievementGate]로 따로 판정한다
/// (`tracking_page.dart`).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../models/models.dart';
import '../../data/share_providers.dart';
import '../../domain/achievement_backlog.dart';
import '../../domain/share_card_data.dart';
import '../share_card_sheet.dart';
import 'share_card_body.dart';

/// 전역 축하 연출을 잠시 멈추는 화면의 수.
///
/// 러닝 요약 화면은 성취를 **인라인으로** 직접 그린다(그게 HI-10이 말하는 주
/// 무대다). 그동안 [AchievementCelebrationHost]까지 풀페이지를 띄우면 같은
/// 성취가 두 번 축하된다.
///
/// Riverpod provider가 아니라 [ValueNotifier]인 이유: 이 값을 바꾸는 시점이
/// 화면의 `initState`/`dispose`인데, 그 순간은 위젯 트리가 빌드 중일 수 있어
/// provider를 수정하면 Riverpod가 막는다. `AppShell.measuredHeight`가 같은
/// 이유로 같은 형태를 쓴다.
///
/// bool이 아니라 카운터인 이유: 화면 전환 중 두 화면이 잠시 겹치면 나중에
/// 사라지는 쪽의 `dispose`가 남아 있는 쪽의 억제를 꺼 버린다.
final ValueNotifier<int> achievementCelebrationSuppressors =
    ValueNotifier<int>(0);

/// [achievementCelebrationSuppressors]를 안전한 시점에 올리고 내린다.
///
/// `initState`/`dispose`는 빌드 페이즈 안일 수 있어 리스너의 `setState`가
/// "build 중 setState" 오류를 낸다 — 그래서 두 방향 모두 다음 프레임으로 미룬다.
void suppressAchievementCelebrations() {
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => achievementCelebrationSuppressors.value += 1,
  );
}

void resumeAchievementCelebrations() {
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => achievementCelebrationSuppressors.value -= 1,
  );
}

// ════════════════════ 전역 호스트 (트리거 지점 #2) ════════════════════

/// 앱 어디에 있든 성취를 놓치지 않게 하는 큐 리스너.
///
/// 서버 판정은 업로드 후 비동기라, 사용자가 요약 화면을 닫고 홈으로 간 뒤에
/// 뱃지가 도착할 수 있다. 오프라인 러닝은 **며칠 뒤 동기화 시점**에 도착한다.
/// 그래서 요약 화면 하나에만 연출을 달면 조용히 사라지는 축하가 생긴다.
///
/// [child]를 그대로 돌려주므로 트리에 끼워 넣기만 하면 된다. 큐가 바뀔 때
/// 이 위젯만 리빌드되고 [child]는 같은 인스턴스라 아래 화면은 리빌드되지 않는다.
class AchievementCelebrationHost extends ConsumerStatefulWidget {
  const AchievementCelebrationHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AchievementCelebrationHost> createState() =>
      _AchievementCelebrationHostState();
}

class _AchievementCelebrationHostState
    extends ConsumerState<AchievementCelebrationHost> {
  /// 다이얼로그가 떠 있는 동안 다음 건을 열지 않기 위한 잠금.
  bool _presenting = false;

  /// 이번 실행에서 이미 연출한 성취.
  ///
  /// **없으면 무한 루프가 된다**: `markAchievementsSeen`은 네트워크 실패 시
  /// 조용히 넘어가고(축하 화면이 오류로 안 닫히는 쪽이 더 나쁘다), 그러면 같은
  /// 행이 큐에 남아 스트림이 다시 밀어 준다 → 다이얼로그가 다시 뜬다.
  /// 앱을 다시 켜면 한 번 더 축하하지만, 그건 의도된 폴백이다.
  final Set<String> _presented = <String>{};

  @override
  Widget build(BuildContext context) {
    final queue = [
      for (final badge
          in ref.watch(pendingAchievementsProvider).valueOrNull ??
              const <UserBadge>[])
        if (!_presented.contains(badge.id)) badge,
    ];

    // 억제가 풀리는 순간에도 다시 판단해야 하므로(요약 화면을 닫자마자 남은
    // 큐를 이어서 축하한다) 카운터 변화에도 리빌드한다.
    return ValueListenableBuilder<int>(
      valueListenable: achievementCelebrationSuppressors,
      builder: (context, suppressors, child) {
        if (suppressors == 0 && !_presenting && queue.isNotEmpty) {
          // 빌드 중에 다이얼로그를 열 수 없다 — 다음 프레임으로 미룬다.
          WidgetsBinding.instance.addPostFrameCallback((_) => _present(queue));
        }
        return child!;
      },
      child: widget.child,
    );
  }

  Future<void> _present(List<UserBadge> queue) async {
    if (_presenting || !mounted) return;
    if (achievementCelebrationSuppressors.value > 0) return;
    if (queue.isEmpty) return;

    _presenting = true;
    try {
      if (isAchievementBacklog(queue)) {
        // 밀려 있던 성취는 한 장으로 접는다 (TRD §14 #19).
        await showDialog<void>(
          context: context,
          builder: (_) => AchievementBacklogDialog(queue: queue),
        );
        final ids = [for (final badge in queue) badge.id];
        _presented.addAll(ids);
        if (!mounted) return;
        await markAchievementsSeenFrom(ref, ids);
        return;
      }

      final next = queue.first;
      // 2026-08-27: 다이얼로그 → 풀페이지(사용자 요청). 뱃지 획득은 러닝
      // 요약 화면 다음으로 큰 "성취 모먼트"라 알림 팝업 취급보다 화면 하나를
      // 온전히 차지할 값어치가 있고, 애니메이션도 더 넓은 캔버스가 필요하다.
      // `rootNavigator: true`는 공유 카드 페이지와 같은 이유다 — 이 컨텍스트는
      // `AppShell`(셸 바깥 루트 라우트) 소유라 이미 루트에 가깝지만, 명시해서
      // 나중에 중첩 구조가 바뀌어도 네비바 없는 진짜 전체 화면이 보장된다.
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => AchievementCelebrationPage(
            userBadge: next,
            remaining: queue.length - 1,
          ),
        ),
      );
      _presented.add(next.id);
      if (!mounted) return;
      // 닫은 뒤에야 seen 처리한다 — 도중에 앱이 죽으면 다음 실행에서 다시 뜬다
      // (한 번 더 축하받는 쪽이, 조용히 사라지는 쪽보다 낫다).
      await markAchievementsSeenFrom(ref, [next.id]);
    } finally {
      if (mounted) _presenting = false;
    }
  }
}

// ════════════════════════ 풀페이지 ════════════════════════

/// 뱃지 획득(HI-10)의 **풀페이지** 축하 화면.
///
/// 2026-08-27 이전에는 `Dialog`(모달)였다. 사용자 요청으로 페이지 전환했다 —
/// 뱃지 획득은 알림 팝업이 아니라 러닝 요약 화면 다음으로 큰 성취 모먼트이고,
/// [_AchievementBurst] 애니메이션(글로우·컨페티·탄성 팝인)도 다이얼로그의
/// 좁은 상자보다 화면 전체가 훨씬 잘 산다.
class AchievementCelebrationPage extends StatelessWidget {
  const AchievementCelebrationPage({
    required this.userBadge,
    this.remaining = 0,
    super.key,
  });

  final UserBadge userBadge;
  final int remaining;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close),
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppTokens.s24),
                child: AchievementCelebrationView(
                  userBadge: userBadge,
                  remaining: remaining,
                  // 다이얼로그의 좁은 상자를 벗어났으니 메달도 더 크게 —
                  // 풀페이지가 주는 여유를 실제로 쓴다.
                  badgeSize: 168,
                  onDismiss: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 밀린 성취 요약 — "그동안 받은 뱃지 N개".
///
/// 개별 축하를 재생하지 않는 이유: 이건 **방금 일어난 일이 아니다.** 며칠 전
/// 받은 뱃지를 지금 하나씩 터뜨리면 축하가 아니라 밀린 알림 정리가 된다.
/// 대신 개수를 보여주고 갤러리로 보낸다.
class AchievementBacklogDialog extends ConsumerWidget {
  const AchievementBacklogDialog({required this.queue, super.key});

  final List<UserBadge> queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final names = [
      for (final badge in queue.take(3))
        if (badge.badge != null) badge.badge!.name,
    ];

    return AlertDialog(
      icon: const Icon(Icons.military_tech_rounded, size: 40),
      title: Text('그동안 받은 뱃지 ${queue.length}개'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            names.isEmpty
                ? '아직 확인하지 않은 뱃지를 모두 정리했어요.'
                : '${names.join(', ')}${queue.length > names.length ? ' 외 ${queue.length - names.length}개' : ''}를 획득했어요.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppTokens.s12),
          Text(
            '활동 탭의 뱃지 갤러리에서 하나씩 확인하고 공유할 수 있어요.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('확인'),
        ),
      ],
    );
  }
}

// ════════════════════════ 연출 본문 ════════════════════════

/// 성취 1건의 축하 본문. 풀페이지(전역, [AchievementCelebrationPage])와 요약
/// 화면(인라인)이 **같은 위젯**을 쓴다 — 두 경로의 문구와 메달이 갈라지지 않게.
class AchievementCelebrationView extends ConsumerWidget {
  const AchievementCelebrationView({
    required this.userBadge,
    required this.onDismiss,
    this.remaining = 0,
    this.badgeSize = 132,
    super.key,
  });

  final UserBadge userBadge;

  /// "확인"을 눌렀을 때. 호출부가 seen 처리/닫기를 담당한다.
  final VoidCallback onDismiss;

  /// 이 건 뒤에 남은 성취 수. 0이면 표시하지 않는다.
  final int remaining;

  /// 메달 지름. 요약 화면 인라인(좁음)과 풀페이지(넓음)가 같은 위젯을 쓰되
  /// 크기만 다르게 준다 — [AchievementCelebrationPage]는 168, 인라인은
  /// 기본값 132.
  final double badgeSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final card = ref.watch(shareCardForAchievementProvider(userBadge));

    return card.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppTokens.s24),
        child: Center(child: CircularProgressIndicator()),
      ),
      // 카드를 못 만들어도(카탈로그 조인 누락 등) 축하는 한다 — 다만 공유는
      // 그릴 그림이 없으므로 뺀다. 여기서 조용히 사라지면 사용자는 뱃지를
      // 받았다는 사실 자체를 모른다.
      error: (_, __) => _Fallback(onDismiss: onDismiss),
      data: (data) {
        if (data == null) return _Fallback(onDismiss: onDismiss);
        final accent = shareCardAccent(data);
        final asset = shareCardEmblemAsset(data);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (asset != null)
              _AchievementBurst(
                accent: accent,
                size: badgeSize,
                child: ShareCardEmblem(
                  assetPath: asset,
                  size: badgeSize,
                  accent: accent,
                ),
              ),
            const SizedBox(height: AppTokens.s12),
            Text(
              achievementKicker(data.kind),
              style: theme.textTheme.labelLarge?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: AppTokens.s4),
            Text(
              data.headline,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (data.subhead != null) ...[
              const SizedBox(height: AppTokens.s8),
              Text(
                data.subhead!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            if (remaining > 0) ...[
              const SizedBox(height: AppTokens.s8),
              Text(
                '외 $remaining개 더 있어요',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: AppTokens.s20),
            // 일반 뱃지는 공유하지 않는다(2026-08-27, 사용자 요청) — 티어
            // 승급·PB 카드만 남긴다. 카탈로그의 "뱃지"는 대부분 티어/PB보다
            // 덜 자랑할 만한 잡다한 카테고리라 공유 값어치가 낮다는 판단이다.
            if (data is! BadgeEarnedCardData)
              FilledButton.icon(
                onPressed: () => showShareCardSheet(context, data),
                icon: const Icon(Icons.ios_share),
                label: const Text('공유하기'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(AppTokens.minTapTarget),
                ),
              ),
            TextButton(
              onPressed: onDismiss,
              child: Text(remaining > 0 ? '다음' : '확인'),
            ),
          ],
        );
      },
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.military_tech_rounded, size: 48),
        const SizedBox(height: AppTokens.s12),
        Text('새 뱃지를 획득했어요!', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppTokens.s16),
        TextButton(onPressed: onDismiss, child: const Text('확인')),
      ],
    );
  }
}

/// **획득 애니메이션**(2026-08-27 추가, 사용자 요청). 메달이 등장하는 0.9초
/// 동안 세 가지가 동시에 진행된다 — 자체 `AnimationController` 하나로 전부
/// 구동해 위젯 3개가 각자 타이머를 갖고 미묘하게 어긋나는 일이 없게 한다.
///
/// 1. **글로우 링**: 뒤에서 팽창하며 옅어진다("펑" 하고 터지는 느낌).
/// 2. **컨페티**: 중심에서 사방으로 튀어나가며 페이드아웃.
/// 3. **메달**: [Curves.elasticOut]으로 살짝 오버슈트했다 정착한다.
///
/// 컨페티 좌표는 고정 시드로 한 번만 만든다 — 매 프레임 다시 뽑으면 입자가
/// 순간이동하는 것처럼 보인다.
class _AchievementBurst extends StatefulWidget {
  const _AchievementBurst({
    required this.child,
    required this.accent,
    required this.size,
  });

  final Widget child;
  final Color accent;
  final double size;

  @override
  State<_AchievementBurst> createState() => _AchievementBurstState();
}

class _AchievementBurstState extends State<_AchievementBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_ConfettiParticle> _particles;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
    _particles = _ConfettiParticle.generate(16, widget.accent);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stageSize = widget.size * 2.4;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // 글로우는 앞쪽 60%에서 팽창하며 사라진다.
        final glowT = Curves.easeOut.transform((t / 0.6).clamp(0.0, 1.0));
        // 메달은 앞쪽 55%에서 탄성 있게 튀어 들어온다.
        final badgeT = Curves.elasticOut.transform((t / 0.55).clamp(0.0, 1.0));
        // 컨페티는 살짝 늦게 출발해 전체 구간에 걸쳐 퍼진다.
        final confettiT = ((t - 0.05) / 0.95).clamp(0.0, 1.0);

        return SizedBox(
          width: stageSize,
          height: stageSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              IgnorePointer(
                child: Opacity(
                  opacity: (1 - glowT).clamp(0.0, 1.0) * 0.55,
                  child: Transform.scale(
                    scale: 0.5 + glowT * 1.3,
                    child: Container(
                      width: widget.size * 1.7,
                      height: widget.size * 1.7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            widget.accent.withValues(alpha: 0.55),
                            widget.accent.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                child: CustomPaint(
                  size: Size(stageSize, stageSize),
                  painter: _ConfettiPainter(
                    progress: confettiT,
                    particles: _particles,
                  ),
                ),
              ),
              Transform.scale(
                scale: badgeT.clamp(0.0, 1.6),
                child: Opacity(
                  opacity: badgeT.clamp(0.0, 1.0),
                  child: widget.child,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConfettiParticle {
  const _ConfettiParticle({
    required this.angle,
    required this.distance,
    required this.radius,
    required this.color,
    required this.delay,
  });

  /// 진행 방향(라디안).
  final double angle;

  /// 무대 반지름 대비 이동 거리 배율.
  final double distance;
  final double radius;
  final Color color;

  /// 0~1. 전체 애니메이션 중 이 입자가 출발하는 시점 — 한꺼번에 튀지 않고
  /// 아주 살짝씩 어긋나야 "펑" 하나가 아니라 자연스러운 흩날림으로 읽힌다.
  final double delay;

  static List<_ConfettiParticle> generate(int count, Color accent) {
    // 고정 시드 — 리빌드마다 입자가 재배치되면 애니메이션이 아니라 잡음이 된다.
    final random = math.Random(7);
    final palette = [accent, Colors.white, accent.withValues(alpha: 0.7)];
    return List.generate(count, (i) {
      return _ConfettiParticle(
        angle: (2 * math.pi / count) * i + random.nextDouble() * 0.4,
        distance: 0.65 + random.nextDouble() * 0.55,
        radius: 2.5 + random.nextDouble() * 2.5,
        color: palette[i % palette.length],
        delay: random.nextDouble() * 0.25,
      );
    });
  }
}

class _ConfettiPainter extends CustomPainter {
  const _ConfettiPainter({required this.progress, required this.particles});

  final double progress;
  final List<_ConfettiParticle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.shortestSide / 2;

    for (final p in particles) {
      final local = ((progress - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final eased = Curves.easeOut.transform(local);
      final travelled = maxRadius * p.distance * eased;
      final position = center +
          Offset(math.cos(p.angle), math.sin(p.angle)) * travelled;
      final opacity = (1 - local).clamp(0.0, 1.0);
      if (opacity <= 0) continue;

      canvas.drawCircle(
        position,
        p.radius * (1 - local * 0.35),
        Paint()..color = p.color.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// 카드 종류별 머리말. 사용자가 "무슨 일이 일어났는지"를 0.5초 안에 알아야 한다.
String achievementKicker(ShareCardKind kind) => switch (kind) {
      ShareCardKind.tierPromotion => '티어 승급',
      ShareCardKind.badgeEarned => '새 뱃지 획득',
      ShareCardKind.personalBest => '개인 최고 기록',
      ShareCardKind.runRecap => '러닝 완료',
    };
