import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../models/models.dart';
import '../../data/tracking_providers.dart';
import '../tracking_format.dart';

/// 진행 중 통계 패널 — **1초마다 갱신되는 유일한 구독 단위**.
///
/// 지도([RunMapView])와 별도의 [ConsumerWidget]으로 떼어 둔 이유가 여기 있다.
/// 화면 전체를 하나의 Consumer로 감싸면 매 초 지도 타일까지 리빌드돼 프레임이
/// 드랍된다(skill §1).
class LiveStatsPanel extends ConsumerWidget {
  const LiveStatsPanel({super.key, required this.paused});

  final bool paused;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 러닝 도중 위치 서비스가 꺼지면 스트림이 에러를 흘리지만 **누적값은 살아 있다**
    // (gps 노트 §5-2). 그래서 에러 상태에서도 마지막 값을 계속 보여준다.
    final run = ref.watch(activeRunProvider).valueOrNull;

    return _StatsBody(run: run, paused: paused);
  }
}

class _StatsBody extends StatelessWidget {
  const _StatsBody({required this.run, required this.paused});

  final RunRecord? run;
  final bool paused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final record = run;

    final distance =
        record == null ? '0.00' : RunFormat.distanceKm(record.distanceMeters);
    final elapsed =
        record == null ? '00:00' : RunFormat.duration(record.elapsedSeconds);
    final pace = record == null ? RunFormat.emptyPace : RunFormat.paceOf(record);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (paused)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.s8),
            child: Text(
              '일시정지됨',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.tertiary,
                letterSpacing: 1.2,
              ),
            ),
          ),
        // 거리는 러너가 가장 자주 보는 값이다 — 뛰면서도 읽히도록 가장 크게.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  distance,
                  style: theme.textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: paused ? scheme.onSurfaceVariant : scheme.onSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppTokens.s8),
            Text(
              'km',
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.s16),
        Row(
          children: [
            Expanded(child: RunStatTile(label: '시간', value: elapsed)),
            _StatDivider(color: scheme.outlineVariant),
            Expanded(child: RunStatTile(label: '페이스', value: '$pace/km')),
          ],
        ),
        if (record != null &&
            (record.avgHeartRateBpm != null || record.caloriesKcal != null))
          Padding(
            padding: const EdgeInsets.only(top: AppTokens.s12),
            child: Row(
              children: [
                Expanded(
                  child: RunStatTile(
                    label: '심박',
                    value: record.avgHeartRateBpm == null
                        ? '--'
                        : '${record.avgHeartRateBpm} bpm',
                    compact: true,
                  ),
                ),
                _StatDivider(color: scheme.outlineVariant),
                Expanded(
                  child: RunStatTile(
                    label: '칼로리',
                    value: record.caloriesKcal == null
                        ? '--'
                        : '${record.caloriesKcal} kcal',
                    compact: true,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: AppTokens.s32, child: VerticalDivider(color: color));
}

/// 라벨 + 값 한 쌍. 요약 화면과 진행 중 패널이 같은 위젯을 쓴다.
class RunStatTile extends StatelessWidget {
  const RunStatTile({
    super.key,
    required this.label,
    required this.value,
    this.compact = false,
  });

  final String label;
  final String value;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppTokens.s4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: (compact
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.headlineMedium)
                ?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// 화면 상단 안내 배너. 권한/서비스/워치 안내가 모두 이 모양을 공유한다 —
/// 케이스마다 다른 생김새를 만들면 사용자가 심각도를 가늠하지 못한다.
class TrackingBanner extends StatelessWidget {
  const TrackingBanner({
    super.key,
    required this.icon,
    required this.message,
    this.tone = TrackingBannerTone.info,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String message;
  final TrackingBannerTone tone;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      TrackingBannerTone.info => (scheme.surfaceContainerHighest, scheme.onSurface),
      TrackingBannerTone.warning => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      TrackingBannerTone.error => (scheme.errorContainer, scheme.onErrorContainer),
    };

    return Container(
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppTokens.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: foreground),
              const SizedBox(width: AppTokens.s8),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: foreground),
                ),
              ),
            ],
          ),
          if (actionLabel != null || secondaryLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: AppTokens.s4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (secondaryLabel != null)
                    TextButton(
                      onPressed: onSecondary,
                      child: Text(secondaryLabel!),
                    ),
                  if (actionLabel != null)
                    TextButton(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

enum TrackingBannerTone { info, warning, error }
