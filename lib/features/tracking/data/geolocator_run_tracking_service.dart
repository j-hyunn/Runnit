import 'dart:async';
import 'dart:io' show Platform;

import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:uuid/uuid.dart';

import '../../../core/error/failure.dart';
import '../../../models/models.dart';
import '../domain/gps_smoothing.dart';
import '../domain/run_session_aggregator.dart';
import '../domain/run_tracking_service.dart';
import 'battery_optimization.dart';
import 'health_wearable_source.dart';

/// [RunTrackingService]의 geolocator 구현.
///
/// 이 클래스가 하는 일은 **배선**뿐이다 — 권한, 위치 스트림 구독, 틱 타이머,
/// 워치 지표 합류, 체크포인트 저장. 실제 거리/시간 계산은 전부
/// `domain/gps_smoothing.dart` + `domain/run_session_aggregator.dart`(순수 Dart)에
/// 있다. 플러그인 없이 로직을 테스트할 수 있게 하려는 의도적 분리다.
///
/// ## 모듈 경계
/// 저장소를 주입받지 않는다. 크래시 대비 중간 저장이 필요하면
/// [onCheckpoint] **함수**를 넘긴다 — 타입 의존이 생기지 않으므로
/// `RunTrackingService`가 리포지토리/게이미피케이션을 모른다는 계약
/// (`domain/run_tracking_service.dart` §모듈 경계 원칙)이 유지된다.
class GeolocatorRunTrackingService implements RunTrackingService {
  GeolocatorRunTrackingService({
    this.profile = TrackingProfile.standard,
    this.filterConfig = const GpsFilterConfig(),
    this.wearableSource,
    this.onCheckpoint,
    this.weightKg,
    this.checkpointInterval = const Duration(seconds: 15),
    this.batteryOptimizationGuard = const BatteryOptimizationGuard(),
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  /// 배터리 ↔ 정확도 프로파일. 사용자 설정에서 바꾸면 provider가 서비스를
  /// 새로 만들도록 되어 있다(`tracking_providers.dart`).
  final TrackingProfile profile;

  /// 스무딩·이상치 임계값. 집계기에 그대로 넘기고, [rawFixStream]의 정확도
  /// 게이트도 같은 값을 쓴다(두 곳이 어긋나면 마커만 튀는 fix로 움직인다).
  final GpsFilterConfig filterConfig;

  /// 워치 지표 소스. null이면 폰 단독 트래킹(정상 경로다 — 에러가 아니다).
  final WearableMetricsSource? wearableSource;

  /// 진행 중 기록의 주기적 저장 훅. 앱이 강제 종료돼도 마지막 체크포인트까지는
  /// 남는다. 실패해도 러닝을 중단시키지 않는다(로그만 삼킨다).
  final Future<void> Function(RunRecord record)? onCheckpoint;

  final Duration checkpointInterval;

  /// Android 배터리 최적화 예외 요청 경로(R-2). 테스트에서 교체 가능하도록
  /// 주입받는다.
  final BatteryOptimizationGuard batteryOptimizationGuard;

  /// 칼로리 추정용 체중(kg). 프로필에서 주입.
  final double? weightKg;

  final Uuid _uuid;

  final StreamController<RunSample> _sampleController =
      StreamController<RunSample>.broadcast();
  final StreamController<RunRecord> _sessionController =
      StreamController<RunRecord>.broadcast();

  /// 스무딩 **이전** 좌표. 지도 마커 전용이다([rawFixStream] 주석 참조).
  final StreamController<GpsFix> _rawFixController =
      StreamController<GpsFix>.broadcast();

  RunSessionAggregator? _aggregator;
  StreamSubscription<geo.Position>? _positionSub;
  StreamSubscription<WearableMetricSample>? _wearableSub;
  Timer? _ticker;
  DateTime _lastCheckpointAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 백그라운드 위치 권한("항상 허용")이 실제로 부여됐는지.
  /// 거부돼도 트래킹은 진행한다 — 포그라운드 전용으로 우아하게 저하한다.
  bool _hasBackgroundPermission = false;
  bool get hasBackgroundLocationPermission => _hasBackgroundPermission;

  /// Android 배터리 최적화 예외가 적용됐는지(R-2). Android가 아니면 항상 true.
  /// 거부돼도 트래킹은 그대로 진행한다 — OEM 정책상 기록이 끊길 확률이
  /// 올라갈 뿐이다.
  bool _hasBatteryOptimizationExemption = false;
  bool get hasBatteryOptimizationExemption => _hasBatteryOptimizationExemption;

  /// 이 세션에 워치 지표가 한 번이라도 붙었는지. UI 배너 판단용.
  bool _wearableConnected = false;
  bool get wearableConnected => _wearableConnected;

  /// Garmin Connect 동기화 경유 데이터가 감지됐는지.
  /// true면 UI가 "워치 데이터는 동기화 후 반영됩니다" 안내를 띄운다.
  bool _usesDelayedWearableSync = false;
  bool get usesDelayedWearableSync => _usesDelayedWearableSync;

  /// 자동 일시정지(TR-03) 중인지. 판정은 집계기의 상태기계가 한다
  /// (`RunSessionAggregator.isAutoPaused` 주석에 수동 일시정지와 합치지 않은 이유).
  bool get isAutoPaused => _aggregator?.isAutoPaused ?? false;

  /// **스무딩 이전** 최신 좌표 스트림 — 지도 마커 전용이다(TR-04, C-4).
  ///
  /// [sampleStream]의 좌표는 이동평균 창(기본 5)을 거쳐 약 2 fix(표준 프로파일
  /// 기준 10초) 뒤처진다. 경로 폴리라인은 그 값이 맞다(지그재그가 죽는다).
  /// 하지만 "지금 내가 있는 점"까지 뒤처지면 사용자 체감으로 TR-04의
  /// "5초 이내 최신 위치 반영"을 못 지킨다.
  ///
  /// 정확도 게이트([GpsFilterConfig.maxAccuracyMeters])만 통과시키고 점프 게이트·
  /// 이동평균은 거치지 않는다 — 마커가 튀는 것을 막을 최소한만 남긴 것이다.
  /// **거리 계산에는 절대 쓰지 않는다.**
  Stream<GpsFix> get rawFixStream => _rawFixController.stream;

  @override
  Stream<RunSample> get sampleStream => _sampleController.stream;

  @override
  Stream<RunRecord> get sessionStream => _sessionController.stream;

  // ───────────────────────── 권한 ─────────────────────────

  @override
  Future<void> ensureReady() async {
    if (!await geo.Geolocator.isLocationServiceEnabled()) {
      throw const Failure.serviceDisabled(service: 'location');
    }

    // 1단계: "앱 사용 중 허용"만 요청한다. 처음부터 "항상 허용"을 요청하면
    // iOS/Android 모두 거부율이 급등한다(skill §2).
    var status = await ph.Permission.locationWhenInUse.status;
    if (!status.isGranted) {
      status = await ph.Permission.locationWhenInUse.request();
    }
    if (!status.isGranted) {
      throw Failure.permissionDenied(
        permission: 'location',
        permanentlyDenied: status.isPermanentlyDenied || status.isRestricted,
      );
    }

    // 2단계: 백그라운드("항상 허용") 승격. **실패해도 던지지 않는다** —
    // 화면을 켜둔 채로 뛰는 사용자는 포그라운드 권한만으로 충분하다.
    // 이 값이 false면 Android 포그라운드 서비스 알림도 켜지 않는다.
    _hasBackgroundPermission = await _requestBackgroundLocation();

    // 3단계: Android 배터리 최적화 예외(R-2). 백그라운드 권한을 실제로 받은
    // 경우에만 묻는다 — 포그라운드 전용으로 저하된 사용자에게는 의미가 없는
    // 다이얼로그다. 결과와 무관하게 트래킹은 진행한다.
    if (_hasBackgroundPermission) {
      _hasBatteryOptimizationExemption =
          await batteryOptimizationGuard.ensureExempted();
    }
  }

  Future<bool> _requestBackgroundLocation() async {
    try {
      var status = await ph.Permission.locationAlways.status;
      if (!status.isGranted) {
        status = await ph.Permission.locationAlways.request();
      }
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  // ───────────────────────── 세션 ─────────────────────────

  @override
  Future<RunRecord> start({
    required String userId,
    required ActivityType type,
  }) async {
    if (_aggregator != null) {
      throw const Failure.unknown(message: '이미 진행 중인 러닝 세션이 있습니다.');
    }

    final startedAt = DateTime.now().toUtc();
    final aggregator = RunSessionAggregator(
      // 클라이언트 생성 UUID v4 — 오프라인 업로드 멱등성 계약(모델 §id).
      recordId: _uuid.v4(),
      userId: userId,
      activityType: type,
      startedAt: startedAt,
      filterConfig: filterConfig,
      profile: profile,
      weightKg: weightKg,
    );
    _aggregator = aggregator;

    // 실내 러닝(트레드밀)은 좌표가 없다 — GPS 스트림을 아예 열지 않는다.
    if (type != ActivityType.indoorRun) {
      _positionSub = geo.Geolocator.getPositionStream(
        locationSettings: _locationSettings(),
      ).listen(_onPosition, onError: _onPositionError);
    }

    await _attachWearable(aggregator);

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());

    final initial = aggregator.snapshot(
      now: startedAt,
      status: RunStatus.recording,
    );
    _sessionController.add(initial);
    return initial;
  }

  geo.LocationSettings _locationSettings() {
    final accuracy = switch (profile) {
      TrackingProfile.highAccuracy => geo.LocationAccuracy.best,
      TrackingProfile.standard => geo.LocationAccuracy.high,
      TrackingProfile.batterySaver => geo.LocationAccuracy.medium,
    };
    final distanceFilter = profile.distanceFilterMeters;

    if (Platform.isAndroid) {
      return geo.AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        intervalDuration: Duration(
          milliseconds: (profile.expectedIntervalSeconds * 1000).round(),
        ),
        // Android는 포그라운드 서비스 없이는 화면이 꺼지는 순간 위치 콜백이
        // 끊긴다. 알림 상시 표시는 OS 정책상 필수다.
        // "항상 허용"을 못 받았으면 어차피 백그라운드 위치가 안 오므로
        // 불필요한 알림을 띄우지 않는다.
        foregroundNotificationConfig: _hasBackgroundPermission
            ? const geo.ForegroundNotificationConfig(
                notificationTitle: 'Runnit 러닝 기록 중',
                notificationText: '거리와 페이스를 기록하고 있습니다.',
                notificationChannelName: '러닝 트래킹',
                enableWakeLock: true,
                setOngoing: true,
              )
            : null,
      );
    }

    if (Platform.isIOS || Platform.isMacOS) {
      return geo.AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        // 러닝 중 신호등에 서 있을 때 iOS가 위치 업데이트를 자동 중단하면
        // 재개 시점이 불확실해진다 — 세션이 통째로 비는 사고가 난다.
        pauseLocationUpdatesAutomatically: false,
        activityType: geo.ActivityType.fitness,
        showBackgroundLocationIndicator: true,
        // Info.plist의 UIBackgroundModes=location과 짝을 이룬다.
        // 권한이 whenInUse뿐이면 iOS가 무시하므로 그대로 둬도 안전하다.
        allowBackgroundLocationUpdates: _hasBackgroundPermission,
      );
    }

    return geo.LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
    );
  }

  Future<void> _attachWearable(RunSessionAggregator aggregator) async {
    final source = wearableSource;
    if (source == null) return;
    // 워치 미연동/권한 거부는 **정상 경로**다. 폰 단독으로 계속 진행한다.
    final authorized = await source.ensureAuthorized();
    if (!authorized) return;

    _wearableSub = source.watch().listen(
      (metric) {
        _wearableConnected = true;
        if (metric.source == RunSampleSource.external) {
          _usesDelayedWearableSync = true;
        }
        aggregator.offerWearableMetrics(
          heartRateBpm: metric.heartRateBpm,
          source: metric.source,
          vendor: metric.vendor,
        );
      },
      onError: (Object _) {
        // 헬스 스택 오류로 러닝을 중단시키지 않는다.
      },
      cancelOnError: false,
    );
  }

  void _onPosition(geo.Position position) {
    final aggregator = _aggregator;
    if (aggregator == null) return;

    final fix = GpsFix(
      latitude: position.latitude,
      longitude: position.longitude,
      timestamp: position.timestamp.toUtc(),
      accuracyMeters: position.accuracy,
      altitudeMeters: position.altitude,
      speedMps: position.speed,
      headingDegrees: position.heading,
    );

    // 지도 마커용 원시 좌표 — 정확도 게이트만 통과시킨다(TR-04, [rawFixStream]).
    // 일시정지 중에는 위치를 갱신하지 않는다(멈춰 있음을 화면이 보여야 한다).
    final accuracy = position.accuracy;
    if (!aggregator.isPaused &&
        !accuracy.isNaN &&
        accuracy <= filterConfig.maxAccuracyMeters &&
        !_rawFixController.isClosed) {
      _rawFixController.add(fix);
    }

    final sample = aggregator.addFix(fix);
    if (sample == null) return; // 필터에 걸러진 fix — 조용히 버린다.
    _sampleController.add(sample);
  }

  void _onPositionError(Object error) {
    // 위치 서비스가 러닝 도중 꺼진 경우 등. 세션은 유지하고(누적값 보존)
    // 상위 계층이 판단하도록 스트림에 에러를 흘린다.
    if (!_sessionController.isClosed) {
      _sessionController.addError(
        error is geo.LocationServiceDisabledException
            ? const Failure.serviceDisabled(service: 'location')
            : Failure.unknown(message: error.toString(), cause: error),
      );
    }
  }

  /// 1초마다 벽시계 기반 스냅샷을 방출한다. GPS fix 주기(최대 10초)와 무관하게
  /// UI 타이머가 매끄럽게 흐르게 하려는 것 — 거리 계산과는 무관하다.
  void _tick() {
    final aggregator = _aggregator;
    if (aggregator == null) return;

    final now = DateTime.now().toUtc();
    final snapshot = aggregator.snapshot(
      now: now,
      status: aggregator.isPaused ? RunStatus.paused : RunStatus.recording,
    );
    if (!_sessionController.isClosed) _sessionController.add(snapshot);

    if (onCheckpoint != null &&
        now.difference(_lastCheckpointAt) >= checkpointInterval) {
      _lastCheckpointAt = now;
      final withSamples = aggregator.snapshot(
        now: now,
        status: aggregator.isPaused ? RunStatus.paused : RunStatus.recording,
        includeSamples: true,
      );
      // 저장 실패로 러닝이 죽으면 안 된다.
      unawaited(onCheckpoint!(withSamples).catchError((Object _) {}));
    }
  }

  @override
  Future<void> pause() async {
    final aggregator = _aggregator;
    if (aggregator == null || aggregator.isPaused) return;
    aggregator.pause();
    _sessionController.add(
      aggregator.snapshot(now: DateTime.now().toUtc(), status: RunStatus.paused),
    );
  }

  @override
  Future<void> resume() async {
    final aggregator = _aggregator;
    if (aggregator == null || !aggregator.isPaused) return;
    aggregator.resume();
    _sessionController.add(
      aggregator.snapshot(
        now: DateTime.now().toUtc(),
        status: RunStatus.recording,
      ),
    );
  }

  @override
  Future<RunRecord> stop() async {
    final aggregator = _aggregator;
    if (aggregator == null) {
      throw const Failure.unknown(message: '진행 중인 러닝 세션이 없습니다.');
    }

    final endedAt = DateTime.now().toUtc();
    await _teardown();

    final record = aggregator.snapshot(
      now: endedAt,
      endedAt: endedAt,
      status: RunStatus.completed,
      includeSamples: true,
    );
    _aggregator = null;
    _sessionController.add(record);
    return record;
  }

  @override
  Future<void> discard() async {
    final aggregator = _aggregator;
    await _teardown();
    _aggregator = null;
    if (aggregator != null) {
      _sessionController.add(
        aggregator.snapshot(
          now: DateTime.now().toUtc(),
          status: RunStatus.discarded,
        ),
      );
    }
  }

  Future<void> _teardown() async {
    _ticker?.cancel();
    _ticker = null;
    await _positionSub?.cancel();
    _positionSub = null;
    await _wearableSub?.cancel();
    _wearableSub = null;
  }

  /// provider가 dispose될 때 호출한다.
  Future<void> dispose() async {
    await _teardown();
    await _sampleController.close();
    await _sessionController.close();
    await _rawFixController.close();
  }
}
