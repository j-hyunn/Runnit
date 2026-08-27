import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/models.dart';
import '../../tracking/presentation/tracking_format.dart';
import '../../tracking/presentation/widgets/run_map_view.dart'
    show RunMapUnavailable;
import '../data/run_detail_providers.dart';
import '../domain/lap_splits.dart';
import 'widgets/history_header.dart';
import 'widgets/lap_table.dart';
import 'widgets/pace_chart.dart';
import 'widgets/run_route_map.dart';

/// 러닝 상세 화면 (PRD HI-02) — 경로 지도 + 요약 통계 + 1km 랩 테이블 +
/// 페이스 그래프. `Routes.runDetail`과 활동 탭 목록 양쪽에서 진입한다.
///
/// HI-07(삭제·제목/메모 수정)은 이 화면에 붙을 예정이지만 아직 미구현이다 —
/// 리포지토리에 삭제·수정 경로가 없고, 삭제는 티어·랭킹 재계산까지 걸린다.
class RunDetailPage extends ConsumerWidget {
  const RunDetailPage({super.key, required this.runId});

  final String runId;

  static const Color _subtleText = Color(0xFF616161);
  static const Color _mutedText = Color(0xFF9B9B9B);

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  static String _dateTimeLabel(DateTime utc) {
    final l = utc.toLocal();
    final w = _weekdays[l.weekday - 1];
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}.${two(l.month)}.${two(l.day)} ($w) ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(runDetailProvider(runId));

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const HistoryHeader(title: '러닝 상세'),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppTokens.contentMaxWidth,
                  ),
                  child: async.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, __) => _Message(
                      text: '기록을 불러오지 못했어요',
                      onRetry: () => ref.invalidate(runDetailProvider(runId)),
                    ),
                    data: (record) => record == null
                        // 삭제된 기록의 알림/딥링크로 들어오면 여기에 닿는다.
                        // 다시 시도해도 없는 기록이므로 재시도 버튼을 주지 않는다.
                        ? const _Message(text: '기록을 찾을 수 없어요')
                        : _DetailBody(record: record, runId: runId),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.record, required this.runId});

  final RunRecord record;
  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final splits = ref.watch(runLapSplitsProvider(runId));
    final route = ref.watch(runRoutePointsProvider(runId));
    final hasRoute = route.length >= 2;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTokens.s24,
        AppTokens.s8,
        AppTokens.s24,
        AppTokens.s40,
      ),
      children: [
        Text(
          RunFormat.activityLabel(record.activityType),
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: AppTokens.s4),
        Text(
          RunDetailPage._dateTimeLabel(record.startedAt),
          style: const TextStyle(
            fontSize: 14,
            color: RunDetailPage._subtleText,
          ),
        ),
        if ((record.title ?? '').isNotEmpty) ...[
          const SizedBox(height: AppTokens.s8),
          Text(
            record.title!,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
        ],
        if (record.isFlagged == true) ...[
          const SizedBox(height: AppTokens.s12),
          const _FlaggedBanner(),
        ],
        const SizedBox(height: AppTokens.s16),
        SizedBox(
          height: 240,
          child: hasRoute
              ? RunRouteMap(route: route)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(AppTokens.rLg),
                  child: RunMapUnavailable(
                    message: record.activityType == ActivityType.indoorRun
                        ? '실내 러닝은 경로를 기록하지 않아요.'
                        : '이 기록에는 저장된 경로가 없어요.',
                  ),
                ),
        ),
        const SizedBox(height: AppTokens.s24),
        _SummaryGrid(record: record),
        if ((record.note ?? '').isNotEmpty) ...[
          const SizedBox(height: AppTokens.s24),
          _Section(
            title: '메모',
            child: Text(
              record.note!,
              style: const TextStyle(fontSize: 14, color: Colors.black),
            ),
          ),
        ],
        ..._lapSections(
          splits,
          hasRoute: hasRoute,
          // 랩 시간은 샘플 타임스탬프 차이(= 경과 시간, 일시정지 포함)라
          // 위 "평균 페이스"(이동 시간 기준)와 기준이 다르다. 일시정지가
          // 길었던 러닝에서만 눈에 띄므로 그때만 한 줄로 밝힌다.
          paused: record.elapsedSeconds - record.movingSeconds > 60,
        ),
      ],
    );
  }

  /// 랩·그래프 영역. 데이터가 없을 때 제목만 남은 빈 섹션을 만들지 않는다 —
  /// 대신 왜 없는지 한 줄로 설명한다.
  List<Widget> _lapSections(
    List<LapSplit> splits, {
    required bool hasRoute,
    required bool paused,
  }) {
    if (splits.isEmpty) {
      return [
        const SizedBox(height: AppTokens.s24),
        Text(
          hasRoute
              // 경로는 있는데 랩이 없다 = 100m도 못 채운 아주 짧은 기록.
              ? '1km 구간을 나누기에는 너무 짧은 기록이에요.'
              : '경로 데이터가 없어 구간·페이스 그래프를 만들 수 없어요.',
          style: const TextStyle(fontSize: 13, color: RunDetailPage._mutedText),
        ),
      ];
    }
    return [
      const SizedBox(height: AppTokens.s32),
      _Section(title: '구간 (1km)', child: LapTable(splits: splits)),
      if (paused) ...[
        const SizedBox(height: AppTokens.s8),
        const Text(
          '구간 시간은 일시정지를 포함한 경과 시간 기준이에요.',
          style: TextStyle(fontSize: 12, color: RunDetailPage._mutedText),
        ),
      ],
      if (PaceChart.canRender(splits)) ...[
        const SizedBox(height: AppTokens.s32),
        _Section(title: '페이스 그래프', child: PaceChart(splits: splits)),
      ],
    ];
  }
}

/// 요약 통계. 3열 고정이 아니라 폭에 맞춰 열 수를 정한다 — 작은 폰(320pt)에서
/// `18px w700` 값과 라벨이 3열로는 줄바꿈되기 때문이다.
class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.record});

  final RunRecord record;

  static const double _minItemWidth = 96;

  @override
  Widget build(BuildContext context) {
    final items = <(String, String)>[
      ('거리', '${Formatters.km(record.distanceMeters, fractionDigits: 2)} km'),
      ('이동 시간', Formatters.duration(record.movingSeconds)),
      ('평균 페이스', RunFormat.paceOf(record)),
      ('경과 시간', Formatters.duration(record.elapsedSeconds)),
      if (record.caloriesKcal != null) ('칼로리', '${record.caloriesKcal} kcal'),
      if (record.elevationGainMeters != null)
        ('상승 고도', '${record.elevationGainMeters!.round()} m'),
      if (record.avgHeartRateBpm != null)
        ('평균 심박', '${record.avgHeartRateBpm} bpm'),
      if (record.avgCadenceSpm != null) ('케이던스', '${record.avgCadenceSpm} spm'),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            (constraints.maxWidth / _minItemWidth).floor().clamp(2, 4);
        final itemWidth = constraints.maxWidth / columns;
        return Wrap(
          runSpacing: AppTokens.s16,
          children: [
            for (final (label, value) in items)
              SizedBox(
                width: itemWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFA5A5A5),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: AppTokens.s12),
        child,
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: RunDetailPage._subtleText,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppTokens.s12),
            TextButton(onPressed: onRetry, child: const Text('다시 시도')),
          ],
        ],
      ),
    );
  }
}

/// PRD §8.4 — 서버 재검증이 이상치로 판정한 기록.
///
/// `isFlagged`가 null(아직 검증 전)일 때는 띄우지 않는다. 업로드 직후 잠깐
/// 지나가는 상태를 경고로 보여주면 정상 기록에 누명을 씌운다.
/// `flagReason`도 노출하지 않는다 — 내부 코드에 가까운 문자열이다.
class _FlaggedBanner extends StatelessWidget {
  const _FlaggedBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(AppTokens.rMd),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: Color(0xFF8A5A00)),
          SizedBox(width: AppTokens.s8),
          Expanded(
            child: Text(
              '이 기록은 검토 대상으로 표시되어 티어·랭킹에 반영되지 않았어요.',
              style: TextStyle(fontSize: 13, color: Color(0xFF8A5A00)),
            ),
          ),
        ],
      ),
    );
  }
}
