import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/share_anchor.dart';
import '../../../models/models.dart';
import '../../tracking/presentation/tracking_format.dart';
import '../../tracking/presentation/widgets/run_map_view.dart'
    show RunMapUnavailable;
import '../data/gpx_export_service.dart';
import '../data/run_detail_providers.dart';
import '../domain/gpx_encoder.dart';
import '../domain/lap_splits.dart';
import 'sync_pending.dart';
import 'widgets/history_header.dart';
import 'widgets/lap_table.dart';
import 'widgets/pace_chart.dart';
import 'widgets/run_meta_edit_sheet.dart';
import 'widgets/run_route_map.dart';

/// 러닝 상세 화면 (PRD HI-02) — 경로 지도 + 요약 통계 + 1km 랩 테이블 +
/// 페이스 그래프. `Routes.runDetail`과 활동 탭 목록 양쪽에서 진입한다.
///
/// HI-07(제목·메모 수정)의 진입점이 여기다 — 헤더의 편집 버튼과 비어 있는 메모
/// 자리의 "메모 추가하기"가 같은 [showRunMetaEditSheet]를 연다. **삭제 UI는 없다**:
/// PRD v1.6 §8.1이 러닝 삭제를 금지했고 서버에도 삭제 정책이 없다(마이그레이션 51).
/// 수정 가능한 것은 `title`·`note` 둘뿐이며, 나머지 컬럼은 UPDATE를 보내도 서버
/// 가드가 조용히 되돌린다(TRD §4.4).
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
    // 편집 버튼은 조회가 끝난 뒤에만 준다 — 로딩/에러 국면에는 시트에 채울
    // 현재 제목·메모가 없다.
    final record = async.valueOrNull;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HistoryHeader(
              title: '러닝 상세',
              trailing: record == null
                  ? null
                  : _DetailActions(
                      onEdit: () => editRunMeta(context, ref, record),
                      onExportGpx: hasExportableRoute(record)
                          ? (origin) =>
                              exportRunAsGpx(context, ref, record, origin: origin)
                          : null,
                    ),
            ),
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

/// 편집 시트를 열고, 저장됐으면 상세 조회를 무효화해 화면을 새로 그린다.
///
/// 시트가 서버 확정값을 로컬 drift 행에 이미 반영했으므로 무효화만 하면 같은 값이
/// 로컬에서 다시 읽힌다 — 재조회 왕복이 없다. 목록(`myRunsProvider`)은 drift
/// `watch()`라 별도 무효화 없이 스스로 갱신된다.
@visibleForTesting
Future<void> editRunMeta(
  BuildContext context,
  WidgetRef ref,
  RunRecord record,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final saved = await showRunMetaEditSheet(
    context,
    runId: record.id,
    initialTitle: record.title,
    initialNote: record.note,
  );
  if (saved == null) return;

  ref.invalidate(runDetailProvider(record.id));
  messenger.showSnackBar(const SnackBar(content: Text('기록을 수정했어요')));
}

/// GPX 파일을 만들어 OS 공유 시트로 넘긴다 (HI-09).
///
/// 준비 스낵바를 먼저 띄우고(직렬화·파일 쓰기가 큰 기록에선 수백 ms), 실패했을
/// 때만 별도 안내로 덮는다. 성공(시트 표시)은 OS 시트 자체가 피드백이라 조용히
/// 지나간다.
///
/// [origin]은 iPad 팝오버 앵커다. **호출부가 오버플로 버튼의 사각형을 계산해
/// 넘긴다** — 여기서 `context.findRenderObject()`를 부르면 그건 페이지 전체의
/// RenderBox라 팝오버가 화면 중앙에서 뜬다(QA A-6). [_DetailActions] 참조.
@visibleForTesting
Future<void> exportRunAsGpx(
  BuildContext context,
  WidgetRef ref,
  RunRecord record, {
  Rect? origin,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      content: Text('GPX 파일을 준비하고 있어요'),
      duration: Duration(seconds: 1),
    ),
  );

  final outcome =
      await ref.read(gpxExportServiceProvider).exportAndShare(record, origin: origin);

  if (outcome == GpxExportOutcome.failed || outcome == GpxExportOutcome.noRoute) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('GPX 파일을 만들지 못했어요')),
      );
  }
}

/// 헤더 오른쪽 액션 묶음 — 편집 버튼 + (경로가 있을 때만) 오버플로 메뉴.
///
/// 오버플로 버튼에 [GlobalKey]를 달아 두는 이유는 하나뿐이다: iPad 공유
/// 팝오버가 **그 버튼**을 가리켜야 하기 때문(QA A-6). 키는 State가 소유해야
/// 리빌드 사이에 같은 위젯을 계속 가리킨다.
class _DetailActions extends StatefulWidget {
  const _DetailActions({required this.onEdit, this.onExportGpx});

  final VoidCallback onEdit;

  /// 인자는 iPad 팝오버 앵커(오버플로 버튼의 전역 사각형). 계산 불가면 null.
  final void Function(Rect? origin)? onExportGpx;

  @override
  State<_DetailActions> createState() => _DetailActionsState();
}

class _DetailActionsState extends State<_DetailActions> {
  final _overflowKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final onExportGpx = widget.onExportGpx;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _EditButton(onTap: widget.onEdit),
        if (onExportGpx != null) ...[
          const SizedBox(width: AppTokens.s4),
          PopupMenuButton<String>(
            key: _overflowKey,
            icon: const Icon(Icons.more_vert, size: 22, color: Colors.black),
            tooltip: '더보기',
            onSelected: (_) => onExportGpx(shareOriginOfKey(_overflowKey)),
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'gpx',
                child: Text('GPX 내보내기'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _AddNoteHint extends StatelessWidget {
  const _AddNoteHint({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.rMd),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: AppTokens.minTapTarget),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(
            horizontal: AppTokens.s12,
            vertical: AppTokens.s12,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTokens.rMd),
            border: Border.all(color: const Color(0xFFE0E0E0)),
          ),
          child: const Text(
            '메모 추가하기',
            style: TextStyle(fontSize: 14, color: RunDetailPage._mutedText),
          ),
        ),
      ),
    );
  }
}

class _EditButton extends StatelessWidget {
  const _EditButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '기록 수정',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTokens.rPill),
        child: const Padding(
          padding: EdgeInsets.all(AppTokens.s4),
          child: Icon(Icons.edit_outlined, size: 22, color: Colors.black),
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
    // 상세 조회는 단발이라 열어 둔 채 업로드가 끝나도 스냅샷이 갱신되지 않는다.
    // 목록 스트림이 아는 기록이면 그쪽의 실시간 값을 쓰고, 모르면(오래된 기록·
    // 다른 기기 기록) 조회 시점 값으로 폴백한다.
    final syncStatus = ref.watch(runSyncStatusProvider(runId));

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
        // 플래그가 우선이다 — 두 배너를 함께 띄우지 않는다. 검토 대상 기록은
        // 업로드가 끝났다는 뜻이므로 애초에 동시에 성립하기 어렵고, 겹칠 경우
        // 사용자가 먼저 알아야 할 쪽은 "반영되지 않았다"는 확정 사실이다.
        if (record.isFlagged == true) ...[
          const SizedBox(height: AppTokens.s12),
          const _FlaggedBanner(),
        ] else if (isSyncPending(record, syncStatus: syncStatus)) ...[
          const SizedBox(height: AppTokens.s12),
          _SyncPendingBanner(
            failed: (syncStatus ?? record.syncStatus) == SyncStatus.failed,
          ),
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
        const SizedBox(height: AppTokens.s24),
        _Section(
          title: '메모',
          child: (record.note ?? '').isEmpty
              // 빈 메모는 "없음"을 알리는 대신 바로 쓸 수 있게 한다 — 헤더 아이콘을
              // 못 찾은 사용자를 위한 두 번째 진입점이기도 하다.
              ? _AddNoteHint(onTap: () => editRunMeta(context, ref, record))
              : Text(
                  record.note!,
                  style: const TextStyle(fontSize: 14, color: Colors.black),
                ),
        ),
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

/// ARCHITECTURE §9.1 — 아직 업로드되지 않은 완료 러닝 안내.
///
/// 이 배너가 막으려는 것은 "시즌 마지막 날 오프라인 러닝을 다음 시즌에
/// 업로드했더니 승급이 인정되지 않더라"는 **사후 발견**이다. 서버는 지각
/// 도착 기록을 마감된 과거 구간에 소급 반영하지 않으므로(정책), 사용자가
/// 손을 쓸 수 있는 시점은 업로드 전뿐이다.
///
/// 톤은 경고가 아니라 안내다 — 기록·거리·뱃지·XP는 전혀 손실되지 않고,
/// 사용자가 할 일도 "네트워크에 연결한다"뿐이다. [_FlaggedBanner]와 같은
/// 앰버 info 박스를 쓰되(같은 성격의 "반영 안 됨" 알림) 겹쳐 띄우지 않는다.
class _SyncPendingBanner extends StatelessWidget {
  const _SyncPendingBanner({required this.failed});

  /// `SyncStatus.failed` — 이미 한 번 이상 업로드를 시도했다가 실패했다.
  /// 재시도는 코디네이터가 알아서 돌리므로(§9의 4신호) 사용자가 할 일은
  /// `local`/`pending`일 때와 같다. 문구만 사실에 맞춘다.
  final bool failed;

  static const Color _amberInk = Color(0xFF8A5A00);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppTokens.s12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(AppTokens.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: _amberInk),
          const SizedBox(width: AppTokens.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '동기화 대기 중',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _amberInk,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  failed
                      ? '업로드에 실패해 다시 시도하고 있어요. 네트워크에 연결되면 '
                          '자동으로 올라가요. 그 전까지는 이번 시즌 티어와 주간 '
                          '랭킹에 반영되지 않아요.'
                      : '이 기록은 아직 서버에 올라가지 않았어요. 네트워크에 '
                          '연결되면 자동으로 업로드돼요. 그 전까지는 이번 시즌 '
                          '티어와 주간 랭킹에 반영되지 않아요.',
                  style: const TextStyle(fontSize: 13, color: _amberInk),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
