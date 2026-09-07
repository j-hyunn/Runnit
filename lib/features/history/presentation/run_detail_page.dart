import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/repository_providers.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/share_anchor.dart';
import '../../../models/models.dart';
import '../../tracking/data/local_run_repository.dart';
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

/// 재시도 상한([LocalRunRepository.maxSyncAttempts])에 걸려 자동 큐에서 빠진
/// 기록을 사용자가 직접 다시 올린다 (TRD §14 #29 잔여 F-5).
///
/// 예산만 되돌리면(`resetSyncAttempts`) 다음 코디네이터 신호(최대 2분)까지
/// 아무 일도 일어나지 않아 버튼이 먹통처럼 보인다. 그래서 곧바로
/// `syncPending()`을 한 번 태운다 — 코디네이터에는 외부에서 부를 수 있는
/// 트리거가 없고(`_trySync`는 private), 여기서 직접 부르는 편이 짧다.
///
/// 업로드 완료는 **기다리지 않는다**: 3,600 샘플 업로드는 수십 초가 걸릴 수
/// 있고, 결과는 `runSyncRetryExhaustedProvider`·`runSyncStatusProvider`가
/// drift `watch()`로 받아 배너를 스스로 지운다. 실패해도 행은 다시 `failed`로
/// 남아 배너가 유지되므로 별도 에러 안내를 겹쳐 띄우지 않는다.
@visibleForTesting
Future<void> retrySyncUpload(
  BuildContext context,
  WidgetRef ref,
  RunRecord record,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final repo = ref.read(runRepositoryProvider);
  if (repo is LocalRunRepository) {
    await repo.resetSyncAttempts(record.id);
  }
  messenger.showSnackBar(const SnackBar(content: Text('다시 시도하고 있어요')));
  unawaited(
    repo.syncPending(userId: record.userId).catchError((Object _) => 0),
  );
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
    // 자동 재시도 예산이 소진됐는가 — 모델에 없는 로컬 컬럼이라 별도 구독이다.
    // 아직 도착 전(loading)이면 false로 본다: 자동 재시도 중이라는 문구가
    // 사실에 더 가깝고, 값이 오면 그 자리에서 재시도 버튼으로 바뀐다.
    final retryExhausted =
        ref.watch(runSyncRetryExhaustedProvider(runId)).valueOrNull ?? false;

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
        // 플래그가 우선이다 — 두 배너를 함께 띄우지 않는다. 겹칠 경우 사용자가
        // 먼저 알아야 할 쪽은 "반영되지 않았다"는 확정 사실이다.
        //
        // G-4(마이그레이션 64) 이후 `applyServerConfirmation`이 `is_flagged`
        // 채택과 `synced` 승격을 분리하면서, `isFlagged==true && 아직 pending`
        // 조합이 실제로 도달 가능해졌다(업로드 중 로컬 편집 → pending 유지 →
        // 그 사이 서버가 플래그). 이때 플래그 배너만 띄우면 재시도 예산이
        // 소진된 사용자에게 유일한 탈출구인 "다시 시도"가 사라진다. 배너를
        // 3개로 늘리지 않고, 플래그 배너 아래에 재시도 액션만 덧붙인다.
        if (record.isFlagged == true) ...[
          const SizedBox(height: AppTokens.s12),
          const _FlaggedBanner(),
          if (retryExhausted && isSyncPending(record, syncStatus: syncStatus)) ...[
            const SizedBox(height: AppTokens.s8),
            _RetryUploadAction(
              onRetry: () => retrySyncUpload(context, ref, record),
            ),
          ],
        ] else if (isSyncPending(record, syncStatus: syncStatus)) ...[
          const SizedBox(height: AppTokens.s12),
          _SyncPendingBanner(
            failed: (syncStatus ?? record.syncStatus) == SyncStatus.failed,
            onRetry: retryExhausted
                ? () => retrySyncUpload(context, ref, record)
                : null,
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
          // 서버가 거리를 깎았을 때 이 화면에는 서로 다른 기준의 숫자가 공존
          // 한다: 요약의 거리는 **확정값**인데 랩·페이스·경로는 로컬 samples
          // (= 기기 원본)에서 계산한다. 서버가 재기입한 샘플을 되받지 않기로
          // 했으므로(3,600건 재다운로드) 이 divergence는 남으며, 여기서 한 줄로
          // 밝히는 것이 유일한 설명이다(아키텍트 문서 §4 열린항목 2·3).
          adjustedDistanceKm: record.distanceWasAdjusted
              ? Formatters.km(record.distanceMeters, fractionDigits: 2)
              : null,
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
    required String? adjustedDistanceKm,
  }) {
    // 서버 확정 거리가 기기 기록보다 작을 때만 non-null. 랩·페이스·경로가
    // 어느 기준인지 밝히는 한 줄이며, 경로만 있고 랩이 없는 기록에도 붙는다.
    final adjustedNote = adjustedDistanceKm == null
        ? const <Widget>[]
        : <Widget>[
            const SizedBox(height: AppTokens.s8),
            Text(
              '랩·페이스·경로는 기기가 기록한 원본 거리 기준이에요. '
              '티어·랭킹에는 확정 거리 $adjustedDistanceKm km가 반영돼요.',
              style: const TextStyle(
                fontSize: 12,
                color: RunDetailPage._mutedText,
              ),
            ),
          ];

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
        if (hasRoute) ...adjustedNote,
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
      ...adjustedNote,
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
    // (라벨, 값, 보조 표기). 보조 표기는 지금 거리 하나만 쓴다.
    final items = <(String, String, String?)>[
      (
        '거리',
        '${Formatters.km(record.distanceMeters, fractionDigits: 2)} km',
        // TRD §14 #27 / 아키텍트 계약 — 서버가 샘플로 거리를 재계산해 깎았을
        // 때만(> 10m) 원본을 병기한다. **주 숫자는 언제나 확정 거리**다:
        // 히스토리·통계·랭킹·공유 카드가 모두 그 값을 쓰므로 여기서만 다른
        // 숫자를 크게 보여주면 화면 간 수치가 갈린다.
        //
        // 배너가 아니라 인라인인 이유: 조정은 정상 기록에서도 일어나는 상시
        // 현상이라, 배너로 만들면 앰버 배타 규칙(플래그 > 동기화 대기)의 세
        // 번째 대상이 되고 플래그된 기록에서는 아예 사라진다.
        record.distanceWasAdjusted
            ? '기기 기록 '
                '${Formatters.km(record.clientReportedDistanceMeters!, fractionDigits: 2)} km'
            : null,
      ),
      ('이동 시간', Formatters.duration(record.movingSeconds), null),
      ('평균 페이스', RunFormat.paceOf(record), null),
      ('경과 시간', Formatters.duration(record.elapsedSeconds), null),
      if (record.caloriesKcal != null)
        ('칼로리', '${record.caloriesKcal} kcal', null),
      if (record.elevationGainMeters != null)
        ('상승 고도', '${record.elevationGainMeters!.round()} m', null),
      if (record.avgHeartRateBpm != null)
        ('평균 심박', '${record.avgHeartRateBpm} bpm', null),
      if (record.avgCadenceSpm != null)
        ('케이던스', '${record.avgCadenceSpm} spm', null),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            (constraints.maxWidth / _minItemWidth).floor().clamp(2, 4);
        final itemWidth = constraints.maxWidth / columns;
        return Wrap(
          runSpacing: AppTokens.s16,
          children: [
            for (final (label, value, note) in items)
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
                    if (note != null)
                      // 셀 폭이 96pt까지 좁아질 수 있어 두 줄까지 허용한다.
                      Text(
                        note,
                        maxLines: 2,
                        style: const TextStyle(
                          fontSize: 11,
                          color: RunDetailPage._mutedText,
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
/// 플래그 배너와 겹친 "재시도 예산 소진 + 아직 미업로드" 조합에서만 쓰는
/// 최소 액션 행. 문구는 짧게 — 옆의 [_FlaggedBanner]가 맥락을 이미 준다.
class _RetryUploadAction extends StatelessWidget {
  const _RetryUploadAction({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            '이 기록은 아직 서버에 올라가지 않았어요. 여러 번 시도했지만 '
            '실패했어요.',
            style: TextStyle(fontSize: 13, color: Color(0xFF8A5A00)),
          ),
        ),
        const SizedBox(width: AppTokens.s8),
        TextButton(onPressed: onRetry, child: const Text('다시 시도')),
      ],
    );
  }
}

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
///
/// 상태는 셋이고 문구가 각각 다르다:
/// - 미시도(`local`/`pending`) — "아직 올라가지 않았어요"
/// - 자동 재시도 중(`failed`, 예산 남음) — "실패해 다시 시도하고 있어요"
/// - **예산 소진**([onRetry] != null) — 자동 재시도가 멈췄으므로 사용자가
///   직접 눌러야 한다. 앞의 둘과 달리 "기다리면 된다"가 거짓이 되는 지점이라
///   문구를 확실히 갈라 놓는다(TRD §14 #29 F-5).
class _SyncPendingBanner extends StatelessWidget {
  const _SyncPendingBanner({required this.failed, this.onRetry});

  /// `SyncStatus.failed` — 이미 한 번 이상 업로드를 시도했다가 실패했다.
  /// 재시도는 코디네이터가 알아서 돌리므로(§9의 4신호) 사용자가 할 일은
  /// `local`/`pending`일 때와 같다. 문구만 사실에 맞춘다.
  final bool failed;

  /// null이 아니면 **자동 재시도 예산이 소진된 상태**
  /// ([LocalRunRepository.maxSyncAttempts]). 이때만 "다시 시도" 버튼을 준다 —
  /// 예산이 남아 있는데 버튼을 노출하면 코디네이터가 어차피 할 일을
  /// 사용자에게 시키는 셈이다.
  final VoidCallback? onRetry;

  static const Color _amberInk = Color(0xFF8A5A00);

  @override
  Widget build(BuildContext context) {
    final onRetry = this.onRetry;
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
                  onRetry != null
                      ? '여러 번 시도했지만 올리지 못했어요. 네트워크 상태를 '
                          '확인하고 다시 시도해 주세요. 올라가기 전까지는 이번 '
                          '시즌 티어와 주간 랭킹에 반영되지 않아요.'
                      : failed
                          ? '업로드에 실패해 다시 시도하고 있어요. 네트워크에 연결되면 '
                              '자동으로 올라가요. 그 전까지는 이번 시즌 티어와 주간 '
                              '랭킹에 반영되지 않아요.'
                          : '이 기록은 아직 서버에 올라가지 않았어요. 네트워크에 '
                              '연결되면 자동으로 업로드돼요. 그 전까지는 이번 시즌 '
                              '티어와 주간 랭킹에 반영되지 않아요.',
                  style: const TextStyle(fontSize: 13, color: _amberInk),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: AppTokens.s4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                        foregroundColor: _amberInk,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppTokens.s12,
                        ),
                        minimumSize: const Size(0, AppTokens.minTapTarget),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        '다시 시도',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
