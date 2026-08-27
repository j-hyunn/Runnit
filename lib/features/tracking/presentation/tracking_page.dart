import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../../../core/error/failure.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../models/models.dart';
import '../data/tracking_providers.dart';
import 'tracking_format.dart';
import 'tracking_ui_providers.dart';
import 'wearable_connect_page.dart';
import 'widgets/run_map_view.dart';
import 'widgets/summary_achievements.dart';
import 'widgets/tracking_stats.dart';

/// 실시간 러닝 트래킹 화면.
///
/// ## 하나의 화면, 네 개의 국면
/// | 국면 | 판정 근거 | 화면 |
/// |------|-----------|------|
/// | 대기 | 진행 중 세션 없음 + 요약 없음 | 활동 유형 선택 + 시작 버튼 |
/// | 기록 중 | `activeRunProvider.status == recording` | 지도 + 통계 + 일시정지/종료 |
/// | 일시정지 | `activeRunProvider.status == paused` | 같은 레이아웃, 재개/종료/버리기 |
/// | 요약 | `stop()`이 돌려준 레코드 보유 | 최종 기록 카드 + 확인 |
///
/// 국면을 별도 화면으로 쪼개지 않은 이유: 러너는 달리는 도중에 화면 전환을 겪으면
/// 안 된다. 지도와 통계 위젯이 계속 살아 있어야 폴리라인이 끊기지 않는다.
///
/// ## 리빌드 범위 (skill §1)
/// 이 위젯은 `activeRunProvider`를 **`select`로만** 구독한다(상태값/에러).
/// 초당 갱신되는 숫자는 [LiveStatsPanel]이, GPS 샘플은 [RunMapView]가 각각
/// 자기 구독으로 처리한다. 그래서 매 초 타이머가 흘러도 지도는 리빌드되지 않는다.
class TrackingPage extends ConsumerStatefulWidget {
  const TrackingPage({super.key});

  @override
  ConsumerState<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends ConsumerState<TrackingPage> {
  // 2026-08-25: "러닝 설정" 바텀시트가 활동 유형 선택 진입점이 됐다
  // (실외 러닝/러닝 머신 2가지로 축소 — 사용자 확정 사항). 그 전까지는
  // Figma 대기 화면에 이 선택 UI가 없어 야외 러닝으로 고정해 뒀었다.
  ActivityType _activityType = ActivityType.outdoorRun;

  /// 대기 화면에서 정하는 러닝 목표. [RunTrackingService]에는 전달하지 않는다
  /// (엔진 인터페이스를 건드리지 않고, 화면 레이어에서 `activeRunProvider`의
  /// 실시간 거리/시간과 비교하는 것만으로 진행률·달성 알림을 구현한다 — 서버
  /// 영속화나 목표 기반 자동 종료가 필요해지면 그때 엔진/모델 확장이 필요하다).
  _RunGoalMetric _goalMetric = _RunGoalMetric.distance;
  double _goalDistanceKm = 5.0;
  int _goalDurationSeconds = 30 * 60;

  /// 현재 목표를 값 객체로 묶은 것. 진행률 계산과 달성 판정이 이 한 곳(
  /// [_RunGoal])에만 있어야 진행 중 화면과 달성 알림이 서로 다른 기준으로
  /// 어긋나는 일이 없다.
  _RunGoal get _goal => _RunGoal(
        metric: _goalMetric,
        distanceKm: _goalDistanceKm,
        durationSeconds: _goalDurationSeconds,
      );

  /// 이번 세션에서 목표 달성 알림을 이미 띄웠는지. 없으면 매초 스냅샷마다
  /// 다시 알림이 뜬다(목표를 넘긴 채로 계속 달리는 게 정상 흐름이므로).
  bool _goalReachedNotified = false;

  /// `stop()`이 돌려준 최종 레코드. null이 아니면 요약 국면이다.
  RunRecord? _summary;

  /// 시작/종료 명령이 진행 중 — 버튼 연타로 세션이 두 번 시작되는 것을 막는다.
  bool _busy = false;

  /// 세션이 살아 있는지. `activeRunProvider`만으로는 판정할 수 없다 —
  /// `invalidate` 직후에도 `AsyncLoading`이 **이전 값을 함께 들고 있어서**
  /// 종료 후에도 진행 중처럼 보인다. 그래서 국면 판정의 기준은 이 플래그가 쥔다.
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    // ⚠️ select로만 구독한다. 통째로 watch하면 1초마다 지도까지 리빌드된다.
    final status =
        ref.watch(activeRunProvider.select((v) => v.valueOrNull?.status));
    final liveError = ref.watch(activeRunProvider.select((v) => v.error));
    final command = ref.watch(trackingControllerProvider);

    // 목표 달성은 "화면이 계속 켜져 있는 동안 한 번" 알리면 충분하다 — 매초
    // 갱신되는 스냅샷 전체를 watch할 필요 없이 listen으로 사이드이펙트만 문다.
    ref.listen<AsyncValue<RunRecord>>(activeRunProvider, (previous, next) {
      if (!_running || _goalReachedNotified) return;
      final record = next.valueOrNull;
      if (record == null || !_goal.isReached(record)) return;
      _goalReachedNotified = true;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('목표 ${_goal.targetLabel}를 달성했어요! 🎉')),
        );
    });

    final summary = _summary;
    final active = _running;

    final Widget body;
    if (summary != null) {
      body = _SummaryView(
        record: summary,
        onDone: _resetToIdle,
        onOpenHistory: () {
          _resetToIdle();
          context.go(Routes.history);
        },
      );
    } else if (active) {
      body = _ActiveView(
        paused: status == RunStatus.paused,
        activityType: _activityType,
        goal: _goal,
        busy: _busy,
        liveError: liveError,
        onPause: () => ref.read(trackingControllerProvider.notifier).pause(),
        onResume: () => ref.read(trackingControllerProvider.notifier).resume(),
        onStop: _stop,
        onDiscard: _discard,
      );
    } else {
      body = _IdleView(
        goalMetric: _goalMetric,
        goalDistanceKm: _goalDistanceKm,
        goalDurationSeconds: _goalDurationSeconds,
        activityType: _activityType,
        busy: _busy || command.isLoading,
        failure: command.error,
        onGoalMetricChanged: (metric) =>
            setState(() => _goalMetric = metric),
        onGoalDistanceChanged: (km) =>
            setState(() => _goalDistanceKm = km),
        onGoalDurationChanged: (seconds) =>
            setState(() => _goalDurationSeconds = seconds),
        onActivityTypeChanged: (type) =>
            setState(() => _activityType = type),
        onStart: _start,
        onOpenSettings: openAppSettings,
      );
    }

    // 대기 화면일 때만 커스텀 헤더를 보여준다 — 진행 중(지도 풀블리드)/요약
    // 화면은 각자 자기 안에 필요한 헤더(또는 없음)를 이미 갖고 있다.
    final showHeader = !active && summary == null;

    return Scaffold(
      // 2026-08-25: 실제 Material `AppBar`를 쓰면서 배경(기본 흰색 계열)과
      // 헤더 높이/여백이 홈·활동·마이(전부 `#F8F8F8` 배경 + 직접 그린
      // Row 헤더, padding vertical 15)와 미묘하게 달라 보였다 — AppBar의
      // 기본 toolbarHeight/elevation이 커스텀 헤더보다 위아래로 더 넓게
      // 차지해서 탭 목록 위에 불필요한 빈 공간까지 생겼다. 대기 화면에서는
      // AppBar 대신 다른 탭과 동일한 커스텀 헤더를 쓰고 배경도 통일한다.
      backgroundColor: showHeader ? const Color(0xFFF8F8F8) : null,
      body: SafeArea(
        child: Column(
          children: [
            if (showHeader) const _TrackingHeader(),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  // ───────────────────────── 명령 ─────────────────────────

  Future<void> _start() async {
    if (_busy) return;
    setState(() => _busy = true);
    // 이전 세션의 폴리라인이 새 러닝에 이어 붙지 않도록 먼저 비운다.
    ref.read(liveRouteProvider.notifier).clear();
    _goalReachedNotified = false;
    await ref
        .read(trackingControllerProvider.notifier)
        .start(type: _activityType);
    if (!mounted) return;
    // 권한 거부 등으로 실패하면 컨트롤러가 AsyncError가 된다 — 대기 국면에 남는다.
    final command = ref.read(trackingControllerProvider);
    setState(() {
      _busy = false;
      _running = !command.hasError && command.valueOrNull != null;
    });
  }

  Future<void> _stop() async {
    if (_busy) return;
    final confirmed = await _confirm(
      title: '러닝을 종료할까요?',
      message: '지금까지 기록한 거리와 시간이 저장돼요.',
      confirmLabel: '종료하고 저장',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      final record =
          await ref.read(trackingControllerProvider.notifier).stop();
      if (!mounted) return;
      setState(() {
        _summary = record;
        _running = false;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _showSnack('러닝을 저장하지 못했어요. 잠시 후 다시 시도해 주세요.');
    }
  }

  Future<void> _discard() async {
    if (_busy) return;
    final confirmed = await _confirm(
      title: '이 러닝을 버릴까요?',
      message: '기록이 저장되지 않고 사라져요. 되돌릴 수 없습니다.',
      confirmLabel: '버리기',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    await ref.read(trackingControllerProvider.notifier).discard();
    if (!mounted) return;
    setState(() => _busy = false);
    _resetToIdle();
  }

  /// 요약/폐기 후 대기 국면으로 되돌린다.
  ///
  /// `activeRunProvider`는 종료 후에도 마지막 스냅샷을 들고 있으므로
  /// invalidate로 비워야 대기 화면이 다시 나온다.
  void _resetToIdle() {
    ref.read(liveRouteProvider.notifier).clear();
    ref.invalidate(activeRunProvider);
    ref.invalidate(interruptedRunProvider);
    if (mounted) {
      setState(() {
        _summary = null;
        _running = false;
      });
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool destructive = false,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: destructive
                ? TextButton.styleFrom(foregroundColor: scheme.error)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 홈/활동/마이와 같은 커스텀 헤더(제목 + 검색/알림). 대기 화면에서만 쓴다.
class _TrackingHeader extends StatelessWidget {
  const _TrackingHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      // 홈 헤더(Figma `55:1179`, px-24 py-15)와 통일 — 2026-08-25.
      padding: EdgeInsets.fromLTRB(24, 15, 24, 15),
      // 34로 고정 — 다른 헤더와 같은 이유(`_ActivityHeader` 참고, 24로 두면
      // 24px 타이틀 텍스트 줄높이가 넘쳐서 잘렸다).
      child: SizedBox(
        height: 34,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '러닝',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: Colors.black),
            ),
            Row(
              children: [
                _HeaderIconButton(asset: 'assets/icons/search.svg', label: '검색'),
                SizedBox(width: AppTokens.s12),
                _HeaderIconButton(asset: 'assets/icons/bell.svg', label: '알림'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 검색/알림 둘 다 아직 목적 화면이 없다 — 홈/활동/마이 헤더와 같은 자리표시자 처리.
class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({required this.asset, required this.label});

  final String asset;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rPill),
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label 기능은 준비 중이에요')),
        );
      },
      child: SvgPicture.asset(asset, width: 24, height: 24),
    );
  }
}

// ═══════════════════════ 대기 국면 ═══════════════════════
//
// Figma 디자인 반영(node 47:341, 2026-08-20). 활동 유형 칩 대신 "거리/시간"
// 목표 탭 + 큰 목표 숫자로 교체 — 사용자 확정 사항. 활동 유형 선택은
// "러닝 설정" 바텀시트(`_RunSettingsSheet`)로 옮겨졌다.
//
// ⚠️ 목표(거리/시간)는 이 화면의 **로컬 UI 상태일 뿐**이다. 화면을 벗어나면
// 사라지고, [RunTrackingService.start]에도 아직 전달되지 않는다(진행 중 목표
// 달성 알림/자동 종료는 후속 범위). 이번 작업은 Figma의 "목표 설정 UI"까지다.

/// 러닝 목표를 거리로 잴지 시간으로 잴지.
enum _RunGoalMetric { distance, time }

/// 대기 화면에서 정한 목표 + 진행률/달성 판정 로직을 한 곳에 묶은 값 객체.
///
/// 진행 중 화면([_GoalProgressPanel])과 달성 알림([_TrackingPageState.build]의
/// `ref.listen`)이 **반드시 같은 기준**으로 판정해야 한다 — 진행률 바는 99%인데
/// 알림은 이미 떴다거나 하는 어긋남을 막기 위해 계산을 여기 한 곳에만 둔다.
class _RunGoal {
  const _RunGoal({
    required this.metric,
    required this.distanceKm,
    required this.durationSeconds,
  });

  final _RunGoalMetric metric;
  final double distanceKm;
  final int durationSeconds;

  bool get _isDistance => metric == _RunGoalMetric.distance;

  double _currentOf(RunRecord record) =>
      _isDistance ? record.distanceMeters : record.elapsedSeconds.toDouble();

  double get _target => _isDistance ? distanceKm * 1000 : durationSeconds.toDouble();

  /// 0.0~1.0. 목표를 넘겨도 1.0에서 멈춘다(진행률 바가 넘치지 않도록).
  double progressOf(RunRecord record) {
    if (_target <= 0) return 0;
    return (_currentOf(record) / _target).clamp(0.0, 1.0);
  }

  bool isReached(RunRecord record) => _currentOf(record) >= _target;

  String get targetLabel =>
      _isDistance ? '${distanceKm.toStringAsFixed(2)}km' : RunFormat.duration(durationSeconds);
}

/// 진행 중 화면에 목표 대비 진행률을 보여준다. `activeRunProvider`를 직접
/// 구독해서 매초 갱신되지만, 부모(`_ActiveView`)는 select로만 구독하므로
/// 지도가 다시 그려지지는 않는다([LiveStatsPanel]과 동일한 구독 패턴).
class _GoalProgressPanel extends ConsumerWidget {
  const _GoalProgressPanel({required this.goal});

  final _RunGoal goal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref.watch(activeRunProvider).valueOrNull;
    if (record == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final progress = goal.progressOf(record);
    final reached = goal.isReached(record);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              reached ? '목표 달성!' : '목표 ${goal.targetLabel}까지',
              style: theme.textTheme.labelMedium?.copyWith(
                color: reached
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: reached ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            Text(
              '${(progress * 100).round()}%',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.s4),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppTokens.rSm),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
  }
}

class _IdleView extends ConsumerWidget {
  const _IdleView({
    required this.goalMetric,
    required this.goalDistanceKm,
    required this.goalDurationSeconds,
    required this.activityType,
    required this.busy,
    required this.failure,
    required this.onGoalMetricChanged,
    required this.onGoalDistanceChanged,
    required this.onGoalDurationChanged,
    required this.onActivityTypeChanged,
    required this.onStart,
    required this.onOpenSettings,
  });

  final _RunGoalMetric goalMetric;
  final double goalDistanceKm;
  final int goalDurationSeconds;
  final ActivityType activityType;
  final bool busy;
  final Object? failure;
  final ValueChanged<_RunGoalMetric> onGoalMetricChanged;
  final ValueChanged<double> onGoalDistanceChanged;
  final ValueChanged<int> onGoalDurationChanged;
  final ValueChanged<ActivityType> onActivityTypeChanged;
  final VoidCallback onStart;
  final VoidCallback onOpenSettings;

  Future<void> _editGoal(BuildContext context) async {
    if (goalMetric == _RunGoalMetric.distance) {
      final result = await _GoalEditSheet.showDistance(
        context,
        initialKm: goalDistanceKm,
      );
      if (result != null) onGoalDistanceChanged(result);
    } else {
      final result = await _GoalEditSheet.showDuration(
        context,
        initialSeconds: goalDurationSeconds,
      );
      if (result != null) onGoalDurationChanged(result);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 2026-08-25: 예전엔 `Center` + `minHeight: 화면 전체`로 이 컨텐츠
    // 묶음(탭/목표 숫자/시작 버튼/설정 칩) 전체를 남는 공간 안에서 세로
    // 중앙 정렬했다 — 그래서 헤더 바로 아래에 항상 큰 빈 여백이 생겼다.
    // 탭을 헤더 바로 아래 붙이기로 해서 세로 중앙 정렬을 뺐다(가로 정렬만
    // 남김). 콘텐츠가 화면보다 길어지는 기기에서도 스크롤은 그대로 된다.
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppTokens.s24),
                child: _InterruptedRunBanner(),
              ),
              if (failure != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.s24,
                    0,
                    AppTokens.s24,
                    AppTokens.s20,
                  ),
                  child: _FailureBanner(
                    failure: failure!,
                    onRetry: onStart,
                    onOpenSettings: onOpenSettings,
                  ),
                ),
              _GoalMetricTabs(
                selected: goalMetric,
                onChanged: busy ? null : onGoalMetricChanged,
              ),
              // 탭을 헤더 바로 아래 붙이고 나니(세로 중앙 정렬 제거) 탭 바로
              // 아래 숫자가 너무 붙어 위로 쏠려 보였다 — 여기 간격만 넉넉히 키움.
              const SizedBox(height: 64),
              Center(
                child: _GoalValueDisplay(
                  metric: goalMetric,
                  distanceKm: goalDistanceKm,
                  durationSeconds: goalDurationSeconds,
                  onTap: busy ? null : () => _editGoal(context),
                ),
              ),
              const SizedBox(height: AppTokens.s40),
              Center(
                child: _StartButton(busy: busy, onPressed: onStart),
              ),
              const SizedBox(height: AppTokens.s24),
              Center(
                child: _RunSettingsChip(
                  activityType: activityType,
                  onActivityTypeChanged: onActivityTypeChanged,
                ),
              ),
              const SizedBox(height: AppTokens.s24),
            ],
          ),
        ),
      ),
    );
  }
}

/// "거리 | 시간" 목표 지표 탭. 선택된 쪽만 검정 밑줄이 붙는다(Figma 원본 그대로).
class _GoalMetricTabs extends StatelessWidget {
  const _GoalMetricTabs({required this.selected, required this.onChanged});

  final _RunGoalMetric selected;
  final ValueChanged<_RunGoalMetric>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFECECEC))),
      ),
      child: Row(
        children: [
          Expanded(
            child: _GoalMetricTab(
              label: '거리',
              selected: selected == _RunGoalMetric.distance,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!.call(_RunGoalMetric.distance),
            ),
          ),
          Expanded(
            child: _GoalMetricTab(
              label: '시간',
              selected: selected == _RunGoalMetric.time,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!.call(_RunGoalMetric.time),
            ),
          ),
        ],
      ),
    );
  }
}

class _GoalMetricTab extends StatelessWidget {
  const _GoalMetricTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 활동 탭(`_ActivityTabBar`/`history_page.dart`)과 완전히 같은 규격으로
    // 맞췄다 — padding vertical 10, 고정 16px 텍스트(테마 titleMedium에
    // 기대지 않음). 두 탭 형식이 같은 화면 결이라 규격도 동일해야 한다.
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? const Color(0xFF00C84B) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black),
        ),
      ),
    );
  }
}

/// 목표 큰 숫자. 탭하면 [_GoalEditSheet]로 값을 바꾼다.
class _GoalValueDisplay extends StatelessWidget {
  const _GoalValueDisplay({
    required this.metric,
    required this.distanceKm,
    required this.durationSeconds,
    required this.onTap,
  });

  final _RunGoalMetric metric;
  final double distanceKm;
  final int durationSeconds;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDistance = metric == _RunGoalMetric.distance;
    final valueText = isDistance
        ? distanceKm.toStringAsFixed(2)
        : RunFormat.duration(durationSeconds);
    final unitText = isDistance ? '킬로미터' : '분';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTokens.rMd),
      child: Padding(
        padding: const EdgeInsets.all(AppTokens.s12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(vertical: AppTokens.s8),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.black, width: 2)),
              ),
              child: Text(
                valueText,
                style: const TextStyle(
                  fontSize: 60,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                  height: 1.0,
                ),
              ),
            ),
            const SizedBox(height: AppTokens.s8),
            Text(
              unitText,
              style: const TextStyle(fontSize: 18, color: Color(0xFF616161)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 목표 값 편집 바텀시트. Figma에는 편집 인터랙션이 정의돼 있지 않아
/// 가장 단순한 형태(텍스트 입력)로 구현했다 — 스테퍼/슬라이더로 다듬는 건
/// 디자이너 확인 후 후속 작업.
class _GoalEditSheet {
  const _GoalEditSheet._();

  // 2026-08-25: 러너 랭킹 시즌 선택 바텀시트(`_SeasonPill._showSeasonSheet`,
  // full_ranking_page.dart)와 같은 색/레이아웃으로 맞췄다 — 흰 배경 +
  // 위쪽만 20px 라운드 + 어두운 스크림(`0x99000000`) + `useRootNavigator:
  // true`(플로팅 알약 네비바 위로 뜨게 하려면 필수, 안 그러면 시트가 알약
  // 밑에 깔린다). 시즌 시트는 선택형 목록이라 이 시트(숫자 입력)와 콘텐츠
  // 구조 자체는 다르지만, 시트를 감싸는 크롬(배경/모서리/스크림)과 내부
  // 타이포그래피 규칙은 동일하게 가져왔다.
  static const _sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
  );

  static Future<double?> showDistance(
    BuildContext context, {
    required double initialKm,
  }) {
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      barrierColor: const Color(0x99000000),
      backgroundColor: Colors.white,
      shape: _sheetShape,
      builder: (context) => _GoalEditSheetBody(
        title: '목표 거리',
        suffix: 'km',
        initialText: initialKm.toStringAsFixed(2),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        parse: (text) {
          final value = double.tryParse(text.replaceAll(',', '.'));
          if (value == null || value <= 0 || value > 999) return null;
          return value;
        },
      ),
    );
  }

  static Future<int?> showDuration(
    BuildContext context, {
    required int initialSeconds,
  }) {
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      barrierColor: const Color(0x99000000),
      backgroundColor: Colors.white,
      shape: _sheetShape,
      builder: (context) => _GoalEditSheetBody(
        title: '목표 시간',
        suffix: '분',
        initialText: (initialSeconds ~/ 60).toString(),
        keyboardType: TextInputType.number,
        parse: (text) {
          final minutes = int.tryParse(text);
          if (minutes == null || minutes <= 0 || minutes > 999) return null;
          return minutes * 60;
        },
      ),
    );
  }
}

class _GoalEditSheetBody<T> extends StatefulWidget {
  const _GoalEditSheetBody({
    required this.title,
    required this.suffix,
    required this.initialText,
    required this.keyboardType,
    required this.parse,
  });

  final String title;
  final String suffix;
  final String initialText;
  final TextInputType keyboardType;
  final T? Function(String text) parse;

  @override
  State<_GoalEditSheetBody<T>> createState() => _GoalEditSheetBodyState<T>();
}

class _GoalEditSheetBodyState<T> extends State<_GoalEditSheetBody<T>> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);
  String? _error;

  void _submit() {
    final value = widget.parse(_controller.text.trim());
    if (value == null) {
      setState(() => _error = '올바른 값을 입력해 주세요.');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppTokens.s16,
        AppTokens.s16,
        AppTokens.s16,
        MediaQuery.of(context).viewInsets.bottom + AppTokens.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
          ),
          const SizedBox(height: AppTokens.s16),
          TextField(
            controller: _controller,
            keyboardType: widget.keyboardType,
            autofocus: true,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: Colors.black),
            decoration: InputDecoration(
              suffixText: widget.suffix,
              errorText: _error,
              filled: true,
              fillColor: const Color(0xFFF3F3F3),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTokens.rMd),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AppTokens.s16),
          FilledButton(
            onPressed: _submit,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00C84B),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: AppTokens.s16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTokens.rPill),
              ),
            ),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }
}

/// 러닝 설정 칩 — 탭하면 활동 유형(실외 러닝/러닝 머신) + 웨어러블 연동
/// 상태를 보여주는 바텀시트([_RunSettingsSheet])가 뜬다.
class _RunSettingsChip extends StatelessWidget {
  const _RunSettingsChip({
    required this.activityType,
    required this.onActivityTypeChanged,
  });

  final ActivityType activityType;
  final ValueChanged<ActivityType> onActivityTypeChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rPill),
      onTap: () => _RunSettingsSheet.show(
        context,
        activityType: activityType,
        onActivityTypeChanged: onActivityTypeChanged,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.s12,
          vertical: AppTokens.s8,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F4F4),
          borderRadius: BorderRadius.circular(AppTokens.rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/icons/settings.svg',
              width: 20,
              height: 20,
              colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
            ),
            const SizedBox(width: AppTokens.s8),
            const Text(
              '러닝 설정',
              style: TextStyle(color: Colors.black, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }
}

/// "러닝 설정" 바텀시트 — **2026-08-25**: 러너 랭킹 시즌 선택 바텀시트
/// (`_SeasonPill`, full_ranking_page.dart)와 같은 크롬(흰 배경, 위쪽만
/// 20px 라운드, 어두운 스크림 `0x99000000`, `useRootNavigator: true`)을
/// 쓴다. 두 섹션으로 구성:
/// 1. "러닝 설정" — 활동 유형 선택. 실외 러닝/러닝 머신 2가지로 축소
///    (사용자 확정 사항 — 트레일/걷기 등은 이 화면에서 다루지 않는다).
///    선택 행 스타일은 `_SeasonRow`와 동일(선택 시 초록 톤온톤 배경 + 체크).
/// 2. "웨어러블 연동" — 선택형이 아니라 현재 연동 상태만 보여주는 정보
///    행. 예전엔 다이얼로그로 따로 떴는데 이 시트 안으로 흡수했다.
class _RunSettingsSheet extends ConsumerWidget {
  const _RunSettingsSheet({
    required this.activityType,
    required this.onActivityTypeChanged,
  });

  final ActivityType activityType;
  final ValueChanged<ActivityType> onActivityTypeChanged;

  static void show(
    BuildContext context, {
    required ActivityType activityType,
    required ValueChanged<ActivityType> onActivityTypeChanged,
  }) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      barrierColor: const Color(0x99000000),
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _RunSettingsSheet(
        activityType: activityType,
        onActivityTypeChanged: onActivityTypeChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(wearableConnectionProvider);

    return Padding(
      padding: const EdgeInsets.all(AppTokens.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '러닝 설정',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
          ),
          const SizedBox(height: AppTokens.s8),
          _RunSettingsOptionRow(
            label: '실외 러닝',
            selected: activityType == ActivityType.outdoorRun,
            onTap: () {
              onActivityTypeChanged(ActivityType.outdoorRun);
              Navigator.of(context).pop();
            },
          ),
          _RunSettingsOptionRow(
            label: '러닝 머신',
            selected: activityType == ActivityType.indoorRun,
            onTap: () {
              onActivityTypeChanged(ActivityType.indoorRun);
              Navigator.of(context).pop();
            },
          ),
          const SizedBox(height: AppTokens.s16),
          const Text(
            '웨어러블 연동',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.black),
          ),
          const SizedBox(height: AppTokens.s8),
          _WearableStatusRow(
            connection: connection,
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(builder: (_) => const WearableConnectPage()),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Figma `_SeasonRow`와 같은 규격의 선택 행(선택 시 초록 톤온톤 배경 + 체크).
class _RunSettingsOptionRow extends StatelessWidget {
  const _RunSettingsOptionRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rMd),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppTokens.s12),
        decoration: BoxDecoration(
          color: selected ? const Color(0x1A00C84B) : null,
          borderRadius: BorderRadius.circular(AppTokens.rMd),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  color: selected ? Colors.black : const Color(0xFF9B9B9B),
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check, size: 24, color: Color(0xFF00C84B)),
          ],
        ),
      ),
    );
  }
}

/// 웨어러블 연동 상태 행 — 탭하면 [WearableConnectPage]로 이동한다.
/// 연동돼 있으면 기기 이름을, 아니면 "연동하기" 안내를 보여준다.
class _WearableStatusRow extends StatelessWidget {
  const _WearableStatusRow({required this.connection, required this.onTap});

  final AsyncValue<String?> connection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final connected = connection.valueOrNull != null;
    final deviceName = connection.valueOrNull;

    return InkWell(
      borderRadius: BorderRadius.circular(AppTokens.rMd),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppTokens.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              connected ? Icons.watch : Icons.watch_outlined,
              size: 24,
              color: connected ? const Color(0xFF00C84B) : const Color(0xFF9B9B9B),
            ),
            const SizedBox(width: AppTokens.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connected ? '$deviceName 연동됨' : '연동된 웨어러블 없음 · 연동하기',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.black),
                  ),
                  const SizedBox(height: AppTokens.s4),
                  Text(
                    connected
                        ? '이 기기의 심박수 데이터가 러닝 기록에 함께 저장돼요.'
                        : 'Apple Watch는 건강 앱, Garmin은 Garmin Connect를 통해 자동으로 연결돼요.',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9B9B9B)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20, color: Color(0xFF9B9B9B)),
          ],
        ),
      ),
    );
  }
}

/// 큰 원형 시작 버튼. 러닝 시작은 이 화면의 유일한 주요 동작이므로
/// 화면에서 가장 큰 터치 타겟을 준다(장갑 낀 손·달리기 직전 상태 고려).
///
/// **2026-08-25 Figma 재확인**: 이전엔 중립 회색(#E9E9E9)+검정 텍스트였는데,
/// 다시 확인한 프레임은 브랜드 그린(#00C84B) 채움 + 흰 텍스트로 바뀌어 있었다
/// (앱 전역 CTA 색과 통일된 것으로 보인다).
class _StartButton extends StatelessWidget {
  const _StartButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          backgroundColor: const Color(0xFF00C84B),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF00C84B),
        ),
        child: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white,
                ),
              )
            : const Text(
                '시작',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}

/// 위치 권한/서비스 실패 안내. 케이스별로 **다른 동선**을 준다 —
/// 영구 거부에 "다시 시도" 버튼을 주면 아무 일도 일어나지 않아 사용자가 갇힌다.
class _FailureBanner extends StatelessWidget {
  const _FailureBanner({
    required this.failure,
    required this.onRetry,
    required this.onOpenSettings,
  });

  final Object failure;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final error = failure;
    if (error is! Failure) {
      return TrackingBanner(
        icon: Icons.error_outline,
        tone: TrackingBannerTone.error,
        message: '러닝을 시작하지 못했어요. 잠시 후 다시 시도해 주세요.',
        actionLabel: '다시 시도',
        onAction: onRetry,
      );
    }

    return switch (error) {
      PermissionDeniedFailure(permanentlyDenied: true) => TrackingBanner(
          icon: Icons.location_disabled,
          tone: TrackingBannerTone.error,
          message:
              '위치 권한이 꺼져 있어요. 설정 앱에서 Runnit의 위치 접근을 "앱 사용 중 허용"으로 바꾸면 러닝을 기록할 수 있어요.',
          actionLabel: '설정 열기',
          onAction: onOpenSettings,
        ),
      PermissionDeniedFailure() => TrackingBanner(
          icon: Icons.my_location,
          tone: TrackingBannerTone.warning,
          message: '러닝 경로와 거리를 기록하려면 위치 권한이 필요해요.',
          actionLabel: '권한 허용하기',
          onAction: onRetry,
        ),
      ServiceDisabledFailure() => TrackingBanner(
          icon: Icons.gps_off,
          tone: TrackingBannerTone.error,
          message: '휴대폰의 위치 서비스가 꺼져 있어요. 제어센터나 설정에서 위치 서비스를 켠 뒤 다시 시작해 주세요.',
          actionLabel: '다시 시도',
          onAction: onRetry,
        ),
      UnauthorizedFailure() => const TrackingBanner(
          icon: Icons.person_off_outlined,
          tone: TrackingBannerTone.error,
          message: '로그인이 만료됐어요. 다시 로그인한 뒤 러닝을 시작해 주세요.',
        ),
      _ => TrackingBanner(
          icon: Icons.error_outline,
          tone: TrackingBannerTone.error,
          message: '러닝을 시작하지 못했어요. 잠시 후 다시 시도해 주세요.',
          actionLabel: '다시 시도',
          onAction: onRetry,
        ),
    };
  }
}

/// 강제 종료/OS kill로 끊긴 세션 안내.
///
/// ⚠️ 현재 [RunTrackingService]에는 **끊긴 세션을 이어받는 API가 없다**
/// (`start()`는 항상 새 세션을 만든다). 그래서 "이어하기" 대신 체크포인트까지를
/// 기록으로 확정하는 선택지를 준다. 진짜 이어하기가 필요하면 엔진에 resume 계약이
/// 추가돼야 한다 — gps-tracking-engineer와 협의 필요.
class _InterruptedRunBanner extends ConsumerWidget {
  const _InterruptedRunBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interrupted = ref.watch(interruptedRunProvider).valueOrNull;
    if (interrupted == null) return const SizedBox.shrink();

    final distance = RunFormat.distanceKm(interrupted.distanceMeters);
    final elapsed = RunFormat.duration(interrupted.elapsedSeconds);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.s20),
      child: TrackingBanner(
        icon: Icons.restore,
        tone: TrackingBannerTone.warning,
        message: '완료되지 않은 러닝이 있어요 · ${distance}km / $elapsed\n'
            '여기까지를 기록으로 저장하거나 버릴 수 있어요.',
        secondaryLabel: '버리기',
        onSecondary: () async {
          await ref.read(runRepositoryProvider).delete(interrupted.id);
          ref.invalidate(interruptedRunProvider);
        },
        actionLabel: '기록으로 저장',
        onAction: () async {
          await ref.read(runRepositoryProvider).save(
                interrupted.copyWith(
                  status: RunStatus.completed,
                  endedAt: interrupted.endedAt ?? DateTime.now().toUtc(),
                ),
              );
          ref.invalidate(interruptedRunProvider);
        },
      ),
    );
  }
}

// ═══════════════════ 기록 중 / 일시정지 국면 ═══════════════════

class _ActiveView extends StatelessWidget {
  const _ActiveView({
    required this.paused,
    required this.activityType,
    required this.goal,
    required this.busy,
    required this.liveError,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onDiscard,
  });

  final bool paused;
  final ActivityType activityType;
  final _RunGoal goal;
  final bool busy;
  final Object? liveError;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: RunFormat.hasRoute(activityType)
                    ? RunMapView(dimmed: paused)
                    : const RunMapUnavailable(
                        message: '실내 러닝은 GPS 좌표가 없어 지도 대신 거리·시간만 기록해요.',
                      ),
              ),
              Positioned(
                left: AppTokens.s16,
                right: AppTokens.s16,
                top: AppTokens.s8,
                child: _ActiveBanners(liveError: liveError),
              ),
            ],
          ),
        ),
        // 통계 + 컨트롤은 지도와 분리된 카드다. 지도가 다시 그려져도
        // 이 카드는 자기 구독으로만 갱신된다.
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppTokens.rLg),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.s20,
                    AppTokens.s20,
                    AppTokens.s20,
                    AppTokens.s16,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _GoalProgressPanel(goal: goal),
                      const SizedBox(height: AppTokens.s16),
                      LiveStatsPanel(paused: paused),
                      const SizedBox(height: AppTokens.s20),
                      _ActiveControls(
                        paused: paused,
                        busy: busy,
                        onPause: onPause,
                        onResume: onResume,
                        onStop: onStop,
                        onDiscard: onDiscard,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 진행 중에만 뜨는 안내들. 워치 배너는 세션 도중 조건이 바뀌므로
/// 초당 틱에 맞춰 다시 판정한다([wearableNoticeReaderProvider] 주석 참고).
class _ActiveBanners extends ConsumerWidget {
  const _ActiveBanners({required this.liveError});

  final Object? liveError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // elapsedSeconds만 select — 초당 1회 리빌드되지만 배너 두 줄짜리 서브트리다.
    ref.watch(activeRunProvider.select((v) => v.valueOrNull?.elapsedSeconds));
    final notice = ref.watch(wearableNoticeReaderProvider)();

    final banners = <Widget>[
      if (liveError is ServiceDisabledFailure)
        const TrackingBanner(
          icon: Icons.gps_off,
          tone: TrackingBannerTone.error,
          message: '위치 서비스가 꺼졌어요. 지금까지의 기록은 유지되지만 새 위치가 들어오지 않아요.',
        )
      else if (liveError != null)
        const TrackingBanner(
          icon: Icons.warning_amber_rounded,
          tone: TrackingBannerTone.warning,
          message: 'GPS 신호에 문제가 있어요. 기록은 계속되고 있어요.',
        ),
      if (notice.delayedSync)
        const TrackingBanner(
          icon: Icons.watch_outlined,
          tone: TrackingBannerTone.info,
          message: '워치 데이터는 Garmin Connect 동기화 후 반영돼요.',
        ),
    ];

    if (banners.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final banner in banners)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTokens.s8),
            child: banner,
          ),
      ],
    );
  }
}

class _ActiveControls extends StatelessWidget {
  const _ActiveControls({
    required this.paused,
    required this.busy,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onDiscard,
  });

  final bool paused;
  final bool busy;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 56,
                child: paused
                    ? FilledButton.icon(
                        onPressed: busy ? null : onResume,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('재개'),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: busy ? null : onPause,
                        icon: const Icon(Icons.pause_rounded),
                        label: const Text('일시정지'),
                      ),
              ),
            ),
            const SizedBox(width: AppTokens.s12),
            Expanded(
              child: SizedBox(
                height: 56,
                child: FilledButton.icon(
                  onPressed: busy ? null : onStop,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('종료'),
                ),
              ),
            ),
          ],
        ),
        // 버리기는 일시정지 상태에서만 노출한다. 달리는 중에 실수로 눌러
        // 기록이 통째로 날아가는 것이 이 화면 최악의 사고다.
        if (paused)
          Padding(
            padding: const EdgeInsets.only(top: AppTokens.s4),
            child: TextButton(
              onPressed: busy ? null : onDiscard,
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              child: const Text('이 러닝 버리기'),
            ),
          ),
      ],
    );
  }
}

// ═══════════════════════ 요약 국면 ═══════════════════════

/// 요약 국면 — **HI-10의 주 무대**.
///
/// 러닝 자체의 공유 버튼([RunShareButton])이 여기서 시작된다. 성취(뱃지/티어/
/// PB) 축하는 2026-08-27부터 이 화면 **위에 풀페이지로 덮이는**
/// `AchievementCelebrationHost`(`achievement_celebration.dart`)가 전담한다 —
/// 예전에는 이 화면이 떠 있는 동안 전역 축하를 억제하고 인라인으로 직접
/// 그렸지만, 이제는 억제하지 않는다.
class _SummaryView extends ConsumerStatefulWidget {
  const _SummaryView({
    required this.record,
    required this.onDone,
    required this.onOpenHistory,
  });

  final RunRecord record;
  final VoidCallback onDone;
  final VoidCallback onOpenHistory;

  @override
  ConsumerState<_SummaryView> createState() => _SummaryViewState();
}

class _SummaryViewState extends ConsumerState<_SummaryView> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final record = widget.record;
    final onDone = widget.onDone;
    final onOpenHistory = widget.onOpenHistory;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTokens.s24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTokens.contentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 완주 자체가 보상이다 — 숫자를 늘어놓기 전에 성취를 먼저 말한다.
              _SummaryHeader(activityType: record.activityType),
              const SizedBox(height: AppTokens.s24),
              Container(
                padding: const EdgeInsets.all(AppTokens.s20),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppTokens.rLg),
                ),
                child: Column(
                  children: [
                    Text(
                      '${RunFormat.distanceKm(record.distanceMeters)} km',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppTokens.s20),
                    Row(
                      children: [
                        Expanded(
                          child: RunStatTile(
                            label: '시간',
                            value: RunFormat.duration(record.elapsedSeconds),
                            compact: true,
                          ),
                        ),
                        Expanded(
                          child: RunStatTile(
                            label: '이동 시간',
                            value: RunFormat.duration(record.movingSeconds),
                            compact: true,
                          ),
                        ),
                        Expanded(
                          child: RunStatTile(
                            label: '페이스',
                            value: '${RunFormat.paceOf(record)}/km',
                            compact: true,
                          ),
                        ),
                      ],
                    ),
                    if (_hasSecondaryStats(record)) ...[
                      const SizedBox(height: AppTokens.s16),
                      const Divider(height: 1),
                      const SizedBox(height: AppTokens.s16),
                      Row(
                        children: [
                          if (record.caloriesKcal != null)
                            Expanded(
                              child: RunStatTile(
                                label: '칼로리',
                                value: '${record.caloriesKcal} kcal',
                                compact: true,
                              ),
                            ),
                          if (record.avgHeartRateBpm != null)
                            Expanded(
                              child: RunStatTile(
                                label: '평균 심박',
                                value: '${record.avgHeartRateBpm} bpm',
                                compact: true,
                              ),
                            ),
                          if (record.elevationGainMeters != null)
                            Expanded(
                              child: RunStatTile(
                                label: '상승 고도',
                                value:
                                    '${record.elevationGainMeters!.round()} m',
                                compact: true,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppTokens.s16),
              // 성취 블록(HI-10). 서버가 확정한 뱃지/티어/PB가 도착하면 여기에
              // 축하와 공유 버튼이 뜨고, 아직이면 상태만 정직하게 말한다.
              SummaryAchievements(record: record),
              const SizedBox(height: AppTokens.s16),
              // 러닝 자체를 공유하는 경로(HI-08). 대부분의 러닝은 뱃지를
              // 터뜨리지 않으므로, 성취가 없어도 자랑할 수 있어야 한다.
              RunShareButton(record: record),
              const SizedBox(height: AppTokens.s16),
              FilledButton(
                onPressed: onDone,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(AppTokens.minTapTarget),
                ),
                child: const Text('확인'),
              ),
              const SizedBox(height: AppTokens.s8),
              TextButton(
                onPressed: onOpenHistory,
                child: const Text('기록에서 보기'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _hasSecondaryStats(RunRecord record) =>
      record.caloriesKcal != null ||
      record.avgHeartRateBpm != null ||
      record.elevationGainMeters != null;
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({required this.activityType});

  final ActivityType activityType;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        // 짧은 스케일 인은 "끝났다"는 전환을 몸으로 느끼게 한다(디자인 토큰 §10).
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.85, end: 1),
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutBack,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: CircleAvatar(
            radius: 36,
            backgroundColor: scheme.primaryContainer,
            child: Icon(
              Icons.check_rounded,
              size: 40,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: AppTokens.s16),
        Text(
          '${RunFormat.activityLabel(activityType)} 완료!',
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
