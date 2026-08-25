import 'dart:math' as math;

import '../../../models/models.dart';
import 'gps_smoothing.dart';
import 'polyline_codec.dart';

/// 스무딩된 fix들을 하나의 [RunRecord]로 누적하는 **순수 Dart** 집계기.
///
/// 위치 플러그인·저장소·Riverpod를 전혀 모른다. 트래킹 서비스가 이 집계기를
/// 감싸고, 테스트는 집계기만 단독으로 돌린다.
///
/// ## elapsedSeconds vs movingSeconds (계약서 §2.2)
/// - [RunRecord.elapsedSeconds] = `endedAt - startedAt` **벽시계**. 일시정지 포함.
///   집계기가 아니라 시계로 결정되므로 [snapshot]의 `now` 인자로 받는다.
/// - [RunRecord.movingSeconds] = 이동으로 인정된 구간의 합. 일시정지 중에는
///   fix를 아예 넣지 않으므로 자동으로 멈추고, **정지 상태(신호등 대기 등)도
///   제외된다** — [GpsTrackFilter]의 정지/이동 상태기계가 `isMoving=false`로
///   판정한 구간은 거리도 시간도 더하지 않기 때문이다.
///   페이스의 분모가 movingSeconds이므로(계약서), 정지 시간을 포함시키면
///   신호등 하나에 페이스가 무너진다. 제외가 러너의 기대와도 일치한다.
///
/// ## 여기서 계산한 값은 전부 "표시용 낙관값"이다
/// `distanceMeters` / `avgPaceSecPerKm` / `caloriesKcal` / 고도는 클라이언트가
/// 즉시 보여주기 위한 추정치다. **최종 진실은 서버가 정한다** —
/// `_workspace/20260819_132600_backend_schema.md` §6 `validate_run`이 업로드된
/// 샘플로 거리·페이스를 재계산하고 이상치를 플래그한다. 랭킹/뱃지 판정은
/// 서버 재계산 값을 쓰므로, 여기 값과 서버 값이 미세하게 달라도 정상이다.
class RunSessionAggregator {
  RunSessionAggregator({
    required this.recordId,
    required this.userId,
    required this.activityType,
    required this.startedAt,
    GpsFilterConfig? filterConfig,
    TrackingProfile profile = TrackingProfile.standard,
    this.weightKg,
  })  : _filter = GpsTrackFilter(
          config: filterConfig ?? const GpsFilterConfig(),
          profile: profile,
        ),
        assert(true);

  final String recordId;
  final String userId;
  final ActivityType activityType;

  /// 세션 시작 시각(UTC).
  final DateTime startedAt;

  /// 칼로리 추정용 체중. null이면 [_defaultWeightKg]로 추정한다(추정치임을 UI에 명시).
  final double? weightKg;

  static const double _defaultWeightKg = 65;

  /// 고도 변화 데드밴드(m). GPS 고도는 수평보다 2~3배 부정확해서
  /// 데드밴드 없이 누적하면 평지 러닝에서도 수백 m의 상승 고도가 잡힌다.
  static const double _elevationDeadbandMeters = 3.0;

  final GpsTrackFilter _filter;

  final List<RunSample> _samples = <RunSample>[];
  final List<LatLngPoint> _route = <LatLngPoint>[];
  final Set<RunSampleSource> _sources = <RunSampleSource>{};

  double _maxSpeedMps = 0;
  double _elevationGain = 0;
  double _elevationLoss = 0;
  double? _elevationCheckpoint;
  double _caloriesKcal = 0;

  int _heartRateSum = 0;
  int _heartRateCount = 0;
  int _maxHeartRate = 0;
  int _cadenceSum = 0;
  int _cadenceCount = 0;

  /// 마지막으로 관측된 워치 지표. GPS fix보다 낮은 주기로 들어오므로,
  /// 다음 fix에 얹어 [RunSample]로 합류시킨다(모델 통합 원칙 — 소스별 모델 금지).
  int? _pendingHeartRateBpm;
  int? _pendingCadenceSpm;
  RunSampleSource? _pendingMetricSource;

  bool _paused = false;

  List<RunSample> get samples => List<RunSample>.unmodifiable(_samples);
  double get distanceMeters => _filter.cumulativeDistanceMeters;
  int get movingSeconds => _filter.movingSeconds.round();
  bool get isPaused => _paused;

  void pause() {
    _paused = true;
    // 재개 시 일시정지 구간이 한 번에 누적되지 않도록 기준점을 끊는다.
    _filter.breakContinuity();
  }

  void resume() {
    _paused = false;
    _filter.breakContinuity();
  }

  /// 워치(HealthKit/Health Connect)에서 온 심박/케이던스를 대기열에 얹는다.
  /// 이 값 자체로는 샘플을 만들지 않는다 — 좌표 없는 샘플이 대량으로 끼면
  /// 경로/차트 소비 측이 전부 null 체크를 해야 하기 때문이다.
  void offerWearableMetrics({
    int? heartRateBpm,
    int? cadenceSpm,
    RunSampleSource source = RunSampleSource.watch,
  }) {
    if (heartRateBpm == null && cadenceSpm == null) return;
    if (heartRateBpm != null) _pendingHeartRateBpm = heartRateBpm;
    if (cadenceSpm != null) _pendingCadenceSpm = cadenceSpm;
    _pendingMetricSource = source;
  }

  /// GPS fix 하나를 반영한다. 필터에 걸러졌거나 일시정지 중이면 null.
  RunSample? addFix(GpsFix fix) {
    if (_paused) return null;

    final smoothed = _filter.add(fix);
    if (smoothed == null) return null;

    if (smoothed.instantSpeedMps > _maxSpeedMps) {
      _maxSpeedMps = smoothed.instantSpeedMps;
    }

    _accumulateElevation(smoothed.altitudeMeters);

    if (smoothed.isMoving && smoothed.stepSeconds > 0) {
      _caloriesKcal += _kcalForSegment(
        speedMps: smoothed.instantSpeedMps,
        seconds: math.min(smoothed.stepSeconds, 60),
      );
    }

    final heartRate = _pendingHeartRateBpm;
    final cadence = _pendingCadenceSpm;
    if (heartRate != null) {
      _heartRateSum += heartRate;
      _heartRateCount += 1;
      if (heartRate > _maxHeartRate) _maxHeartRate = heartRate;
    }
    if (cadence != null) {
      _cadenceSum += cadence;
      _cadenceCount += 1;
    }

    // 워치 지표가 실려 붙은 샘플은 소스를 워치로 표기한다 — 좌표는 폰이지만
    // 이 세션에 워치가 기여했음을 sources로 남기기 위해서다.
    final source = (heartRate != null || cadence != null)
        ? (_pendingMetricSource ?? RunSampleSource.watch)
        : RunSampleSource.phone;
    _sources.add(source);
    // 좌표는 언제나 폰 GPS에서 왔으므로 phone도 항상 기여자다.
    _sources.add(RunSampleSource.phone);

    _pendingHeartRateBpm = null;
    _pendingCadenceSpm = null;

    final sample = RunSample(
      latitude: smoothed.latitude,
      longitude: smoothed.longitude,
      timestamp: smoothed.timestamp,
      altitudeMeters: smoothed.altitudeMeters,
      accuracyMeters: smoothed.accuracyMeters,
      speedMps: smoothed.instantSpeedMps,
      headingDegrees: smoothed.headingDegrees,
      heartRateBpm: heartRate,
      cadenceSpm: cadence,
      cumulativeDistanceMeters: smoothed.cumulativeDistanceMeters,
      source: source,
    );

    _samples.add(sample);
    _route.add(LatLngPoint(smoothed.latitude, smoothed.longitude));
    return sample;
  }

  void _accumulateElevation(double? altitude) {
    if (altitude == null || altitude.isNaN) return;
    final checkpoint = _elevationCheckpoint;
    if (checkpoint == null) {
      _elevationCheckpoint = altitude;
      return;
    }
    final delta = altitude - checkpoint;
    if (delta.abs() < _elevationDeadbandMeters) return;
    if (delta > 0) {
      _elevationGain += delta;
    } else {
      _elevationLoss += -delta;
    }
    _elevationCheckpoint = altitude;
  }

  /// ACSM 러닝 대사 방정식 기반 추정. VO2(ml/kg/min) = 0.2 × 속도(m/min) + 3.5,
  /// MET = VO2 / 3.5, kcal/min = MET × 3.5 × 체중(kg) / 200.
  /// **추정치다** — 심박 기반 추정이 필요해지면 이 함수만 교체한다.
  double _kcalForSegment({required double speedMps, required double seconds}) {
    final speedMPerMin = speedMps * 60;
    final vo2 = 0.2 * speedMPerMin + 3.5;
    final met = vo2 / 3.5;
    final kcalPerMin = met * 3.5 * (weightKg ?? _defaultWeightKg) / 200;
    return kcalPerMin * (seconds / 60);
  }

  /// 현재 상태의 [RunRecord]. [includeSamples]가 false면 samples는 빈 리스트다
  /// (진행 중 UI 갱신용 — 인터페이스 주석대로 매 프레임 전체 리스트를 넘기지 않는다).
  RunRecord snapshot({
    required DateTime now,
    required RunStatus status,
    bool includeSamples = false,
    DateTime? endedAt,
    SyncStatus syncStatus = SyncStatus.local,
  }) {
    final elapsed = now.toUtc().difference(startedAt).inSeconds;
    final moving = movingSeconds;
    final distance = distanceMeters;

    return RunRecord(
      id: recordId,
      userId: userId,
      startedAt: startedAt,
      endedAt: endedAt,
      activityType: activityType,
      status: status,
      distanceMeters: distance,
      elapsedSeconds: math.max(0, elapsed),
      // 이동 시간이 벽시계를 넘는 일은 없어야 한다 —
      // 서버 `validate_run`의 `moving_exceeds_elapsed` 플래그를 유발한다.
      movingSeconds: math.min(moving, math.max(0, elapsed)),
      // 낙관적 표시용. 서버 `validate_run`이 샘플로 재계산한 값이 최종이며,
      // 업로드 payload에서도 이 필드는 제거된다(`local_run_repository.dart`).
      avgPaceSecPerKm:
          distance > 0 && moving > 0 ? moving / (distance / 1000) : null,
      maxSpeedMps: _maxSpeedMps > 0 ? _maxSpeedMps : null,
      elevationGainMeters: _elevationGain > 0 ? _elevationGain : null,
      elevationLossMeters: _elevationLoss > 0 ? _elevationLoss : null,
      avgHeartRateBpm:
          _heartRateCount > 0 ? (_heartRateSum / _heartRateCount).round() : null,
      maxHeartRateBpm: _maxHeartRate > 0 ? _maxHeartRate : null,
      caloriesKcal: _caloriesKcal > 0 ? _caloriesKcal.round() : null,
      avgCadenceSpm:
          _cadenceCount > 0 ? (_cadenceSum / _cadenceCount).round() : null,
      samples: includeSamples ? samples : const <RunSample>[],
      routePolyline: _route.length >= 2
          ? encodePolyline(simplifyRoute(_route))
          : null,
      syncStatus: syncStatus,
      sources: _sources.isEmpty
          ? const <RunSampleSource>[RunSampleSource.phone]
          : _sources.toList(growable: false),
    );
  }
}
