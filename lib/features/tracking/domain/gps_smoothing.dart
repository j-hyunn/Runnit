/// GPS 원시 좌표 → 신뢰 가능한 이동거리로 바꾸는 **순수 Dart** 파이프라인.
///
/// 플러그인(geolocator)에 의존하지 않는다 — 합성 로그로 단위 테스트할 수 있어야
/// 하기 때문이다. `dart test`에서 "5분간 정지 → 누적거리 ≈ 0"을 검증하는 것이
/// 이 파일이 존재하는 이유다(skill: references/gps-smoothing.md §검증 방법).
///
/// ## 파이프라인 (순서가 중요하다)
/// 1. **정확도 게이트** — `accuracyMeters > [GpsFilterConfig.maxAccuracyMeters]`인
///    fix는 통째로 버린다. 가장 싸고 가장 효과가 큰 필터.
/// 2. **불연속 처리** — 직전 fix와의 간격이 [GpsFilterConfig.signalGapSeconds]를
///    넘으면(터널/실내) 이동평균 창을 비운다. 유실 구간 앞뒤 좌표를 평균내면
///    존재하지 않는 중간 지점이 만들어진다.
/// 3. **이동평균 스무딩** — 최근 N개 좌표의 평균으로 지그재그를 죽인다.
///    거리 누적과 폴리라인 모두 이 스무딩된 좌표를 쓴다.
/// 4. **점프 제거** — 스무딩 좌표 기준 구간 속도가
///    [GpsFilterConfig.maxPlausibleSpeedMps]를 넘으면 GPS 튐으로 보고 버린다.
///    이때 직전 기준점은 **유지**해서 다음 fix와 다시 비교하고, 이상치를
///    이동평균 창에서도 빼낸다(안 그러면 버린 좌표가 다음 5개 fix를 오염시킨다).
/// 5. **정지/이동 상태기계(히스테리시스)** — 여기가 "정지했는데 거리가 계속
///    늘어나는" 버그를 막는 핵심이다.
///    - `stationary`: 기준점(anchor)에서 [GpsFilterConfig.stationaryExitMeters]
///      이상 **순 변위**가 생기기 전까지 거리를 1m도 누적하지 않는다.
///      탈출하는 순간 anchor→현재 변위를 통째로 한 번에 더하므로 러닝 시작
///      구간을 잃지 않는다. 정지 중 anchor는 EMA로 천천히 따라가서, 도심
///      캐니언에서 수십 초에 걸쳐 GPS가 서서히 흘러도 오탈출하지 않는다.
///    - `moving`: 스무딩 좌표 간 구간 누적으로 바꾼다. 여기서도 구간 속도가
///      [GpsFilterConfig.minMovingSpeedMps] 미만이거나 이동량이 노이즈
///      바닥값 미만이면 그 구간은 버린다.
///    - 되돌아가기: 최근 [GpsFilterConfig.stopWindowSeconds] 동안의 순 변위가
///      [GpsFilterConfig.stationaryEnterMeters] 미만이면 다시 `stationary`.
///
/// ## 왜 구간별 임계값만으로는 부족한가 (이 파일의 이전 버전이 틀렸던 이유)
/// 이동평균을 거친 좌표라도 정지 상태에서 평균 주변을 계속 흔들린다. 구간
/// 임계값(예: 1m)만 두면 그 흔들림 중 임계값을 넘는 것들만 골라서 누적하는
/// 꼴이 되어 **한쪽 방향으로만 더해진다** — 오차가 상쇄되지 않는다.
/// 정확도 6m·1Hz·5분 정지 합성 로그에서 실제로 124m가 쌓였다.
/// 순 변위 기반 상태기계는 왕복 흔들림이 서로 상쇄되므로 이 누적이 원천 봉쇄된다.
library;

import 'dart:collection';
import 'dart:math' as math;

/// 스무딩 파이프라인의 입력. geolocator `Position`을 그대로 받지 않는 이유는
/// 이 파일을 플러그인 없이 테스트 가능하게 유지하기 위해서다.
class GpsFix {
  const GpsFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracyMeters,
    this.altitudeMeters,
    this.speedMps,
    this.headingDegrees,
  });

  final double latitude;
  final double longitude;

  /// 항상 UTC로 정규화해서 넣는다.
  final DateTime timestamp;
  final double? accuracyMeters;
  final double? altitudeMeters;
  final double? speedMps;
  final double? headingDegrees;
}

/// 파이프라인을 통과한 fix. 좌표는 스무딩된 값이다.
class SmoothedFix {
  const SmoothedFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.stepMeters,
    required this.stepSeconds,
    required this.cumulativeDistanceMeters,
    required this.instantSpeedMps,
    required this.isMoving,
    this.accuracyMeters,
    this.altitudeMeters,
    this.headingDegrees,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;

  /// 이번 fix가 누적 거리에 **실제로 더한** 값(m). 정지/점프 판정 시 0.
  final double stepMeters;

  /// 직전 채택 fix와의 시간차(s). 첫 fix는 0.
  final double stepSeconds;

  final double cumulativeDistanceMeters;

  /// 구간 속도(m/s). 기기 제공 speed가 아니라 좌표 미분값이다 — 기기 speed는
  /// 정지 시에도 노이즈가 남아 드리프트 판정 기준으로 쓸 수 없다.
  final double instantSpeedMps;

  /// 이 구간이 이동으로 인정됐는지. false면 `movingSeconds`도 늘지 않는다.
  final bool isMoving;

  final double? accuracyMeters;
  final double? altitudeMeters;
  final double? headingDegrees;
}

/// 배터리 ↔ 정확도 트레이드오프 프로파일. 사용자 설정으로 노출할 것을 전제로
/// 트래킹 서비스 밖에서 주입한다.
enum TrackingProfile {
  /// 대회/기록 갱신용. 1초 간격, 최고 정확도.
  highAccuracy,

  /// 일반 러닝 기본값. 5초 간격.
  standard,

  /// 마라톤/장거리. 10초 간격.
  batterySaver;

  /// 이 프로파일이 기대하는 fix 간격(s). 드리프트 노이즈 바닥값 계산에 쓴다.
  double get expectedIntervalSeconds => switch (this) {
        TrackingProfile.highAccuracy => 1,
        TrackingProfile.standard => 5,
        TrackingProfile.batterySaver => 10,
      };

  /// geolocator `distanceFilter`(m). 프로파일이 길수록 더 크게 잡아
  /// 불필요한 콜백 자체를 줄인다(배터리).
  int get distanceFilterMeters => switch (this) {
        TrackingProfile.highAccuracy => 0,
        TrackingProfile.standard => 3,
        TrackingProfile.batterySaver => 8,
      };
}

/// 필터 임계값 묶음. 근거는 각 필드 주석 참조.
class GpsFilterConfig {
  const GpsFilterConfig({
    this.maxAccuracyMeters = 25,
    this.maxPlausibleSpeedMps = 8.5,
    this.minMovingSpeedMps = 0.6,
    this.minStepMeters = 1.0,
    this.smoothingWindow = 5,
    this.signalGapSeconds = 20,
    this.maxBridgeSeconds = 120,
    this.stationaryExitMeters = 8,
    this.stationaryEnterMeters = 6,
    this.stopWindowSeconds = 10,
    this.stationaryAnchorEma = 0.1,
  });

  /// 이 반경보다 부정확한 fix는 버린다. 25m는 도심 캐니언에서 흔한 값이라
  /// 더 조이면 도심 러닝에서 fix가 거의 남지 않는다.
  final double maxAccuracyMeters;

  /// 8.5 m/s ≈ 30.6 km/h. 우사인 볼트 최고속도(약 12 m/s)보다 낮지만,
  /// 여기는 *구간 평균* 속도라 스프린트도 이 값을 넘지 않는다.
  /// 서버 재검증(`validate_run`)의 `implausible_max_speed`(15 m/s)보다
  /// 클라이언트가 더 보수적인 것은 의도적이다 — 플래그 전에 걸러낸다.
  final double maxPlausibleSpeedMps;

  /// 0.6 m/s ≈ 2.2 km/h. 가장 느린 걷기(약 3 km/h)보다도 낮아
  /// 실제 이동을 잘라먹지 않으면서 정지 드리프트는 확실히 죽인다.
  final double minMovingSpeedMps;

  /// 속도 게이트를 통과해도 절대 이동량이 이보다 작으면 노이즈로 본다.
  final double minStepMeters;

  /// 이동평균 창 크기. 너무 키우면 실제 코너링이 뭉개진다(skill 문서 §3차 필터).
  final int smoothingWindow;

  /// 이보다 긴 공백은 신호 유실로 간주 — 이동평균 창을 리셋한다.
  final double signalGapSeconds;

  /// 유실 구간을 직선 보간으로 이어붙일 수 있는 최대 길이(s).
  /// 2분을 넘는 공백은 이어붙이지 않는다(차량 이동 등 다른 원인일 확률이 높다).
  final double maxBridgeSeconds;

  /// 정지 상태를 벗어나려면 anchor에서 이만큼 순 변위가 필요하다(m).
  /// 실효 임계값은 `max(이 값, 정확도 × 1.5)`다 — 정확도가 나쁠수록 더 크게 움직여야
  /// 이동으로 인정한다. 8m는 러닝 3초, 걷기 6초 거리라 시작 지연이 체감되지 않으면서
  /// 스무딩 후 지터(정확도 6m 기준 표준편차 약 1m)의 8σ 밖이라 오탈출이 사실상 없다.
  final double stationaryExitMeters;

  /// [stopWindowSeconds] 동안의 순 변위가 이 값(m) 미만이면 정지로 복귀한다.
  /// 탈출 임계값보다 낮게 둬서 경계에서 상태가 떨리지 않게 한다(히스테리시스).
  final double stationaryEnterMeters;

  /// 정지 복귀 판정에 쓰는 관측 창(s). 실효값은 fix 간격의 2배 이상으로 늘어난다
  /// (batterySaver 프로파일에서 창 안에 fix가 1개뿐이면 판정이 불가능하므로).
  final double stopWindowSeconds;

  /// 정지 중 anchor를 현재 좌표 쪽으로 끌어당기는 EMA 계수(0~1).
  /// 도심에서 서 있는 동안 GPS가 수십 초에 걸쳐 서서히 흐르는 현상을 흡수한다.
  /// 러너가 실제로 출발하면 EMA(0.1)가 따라잡기 전에 변위가 임계값을 넘는다.
  final double stationaryAnchorEma;
}

/// 지구 반경(m) — WGS84 평균.
const double _earthRadiusMeters = 6371008.8;

/// Haversine 거리(m). geolocator의 `distanceBetween`과 동일한 결과를 주지만
/// 플러그인 없이 계산할 수 있어 테스트 가능하다.
double haversineMeters(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  const deg2rad = math.pi / 180.0;
  final dLat = (lat2 - lat1) * deg2rad;
  final dLon = (lon2 - lon1) * deg2rad;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * deg2rad) *
          math.cos(lat2 * deg2rad) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * _earthRadiusMeters * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// 정지 복귀 판정을 위해 보관하는 최근 스무딩 좌표.
class _TrackPoint {
  const _TrackPoint(this.latitude, this.longitude, this.time);
  final double latitude;
  final double longitude;
  final DateTime time;
}

/// 상태를 가진 스트리밍 필터. fix 하나를 넣으면 채택된 [SmoothedFix] 또는
/// null(버려짐)을 돌려준다.
class GpsTrackFilter {
  GpsTrackFilter({
    this.config = const GpsFilterConfig(),
    this.profile = TrackingProfile.standard,
  });

  final GpsFilterConfig config;
  final TrackingProfile profile;

  /// 이동평균 창.
  final Queue<GpsFix> _window = Queue<GpsFix>();

  /// 정지 복귀 판정용 최근 좌표(최대 [_effectiveStopWindowSeconds] 구간).
  final Queue<_TrackPoint> _recent = Queue<_TrackPoint>();

  /// 정지 기준점. 정지 중에는 EMA로 천천히 따라간다.
  double? _anchorLat;
  double? _anchorLon;
  DateTime? _anchorTime;

  /// 직전에 **채택된** 스무딩 좌표. 이동 상태의 구간 누적 기준점.
  double? _lastLat;
  double? _lastLon;
  DateTime? _lastTime;

  /// 정확도 게이트를 통과한 마지막 fix 시각. 신호 유실 판정용.
  DateTime? _lastFixTime;

  /// 상태기계. 세션은 항상 정지 상태에서 시작한다 — 출발선에 서 있는
  /// 시간이 거리로 잡히면 안 되기 때문이다.
  bool _stationary = true;

  double _cumulativeMeters = 0;

  /// 누적 이동 시간(s). 정지 구간은 포함하지 않는다.
  double _movingSeconds = 0;

  double get cumulativeDistanceMeters => _cumulativeMeters;
  double get movingSeconds => _movingSeconds;

  /// 현재 정지로 판정 중인지. UI가 "정지 감지됨" 표시를 하고 싶을 때 쓴다.
  bool get isStationary => _stationary;

  /// 일시정지/재개 경계에서 호출한다. 다음 fix가 직전 fix와 이어지지 않도록
  /// 기준점과 창을 모두 비운다 — 그러지 않으면 일시정지 동안 이동한 거리가
  /// 재개 순간 한 번에 누적된다.
  void breakContinuity() {
    _window.clear();
    _recent.clear();
    _anchorLat = null;
    _anchorLon = null;
    _anchorTime = null;
    _lastLat = null;
    _lastLon = null;
    _lastTime = null;
    _lastFixTime = null;
    _stationary = true;
  }

  void reset() {
    breakContinuity();
    _cumulativeMeters = 0;
    _movingSeconds = 0;
  }

  /// 정지 복귀 판정 창(s). 프로파일의 fix 간격이 길면 창 안에 좌표가 2개도
  /// 안 들어와 판정이 불가능해지므로 간격에 비례해 늘린다.
  double get _effectiveStopWindowSeconds => math.max(
        config.stopWindowSeconds,
        profile.expectedIntervalSeconds * 2.5,
      );

  /// 이 fix의 노이즈 바닥값(m). 정확도가 나쁠수록 더 큰 이동만 인정한다.
  /// 폴링 간격이 길수록 한 스텝의 실제 이동량이 크므로 바닥값도 함께 올린다.
  /// **이동 상태에서만** 쓴다 — 정지 판정은 순 변위 기반 상태기계가 맡는다.
  double _noiseFloor(GpsFix fix) {
    final accuracy = fix.accuracyMeters ?? 10;
    // 정확도의 35%를 바닥값으로 삼되, 실제 러닝 한 스텝(간격 × 최소 이동속도)의
    // 절반을 넘지 않게 막는다 — 안 그러면 느린 조깅이 통째로 정지로 잘린다.
    final cap = profile.expectedIntervalSeconds * config.minMovingSpeedMps * 0.5;
    return math.max(config.minStepMeters, math.min(accuracy * 0.35, cap));
  }

  /// 정지 상태를 벗어나는 데 필요한 순 변위(m).
  double _exitThreshold(GpsFix fix) =>
      math.max(config.stationaryExitMeters, (fix.accuracyMeters ?? 10) * 1.5);

  /// 정지 상태로 되돌아가는 순 변위 임계값(m). 탈출 임계값보다 낮다(히스테리시스).
  double _enterThreshold(GpsFix fix) =>
      math.max(config.stationaryEnterMeters, fix.accuracyMeters ?? 10);

  /// 파이프라인 본체. 버려진 fix는 null.
  SmoothedFix? add(GpsFix fix) {
    // 1) 정확도 게이트.
    final accuracy = fix.accuracyMeters;
    if (accuracy != null &&
        (accuracy.isNaN || accuracy > config.maxAccuracyMeters)) {
      return null;
    }

    final now = fix.timestamp.toUtc();

    // 2) 신호 유실 감지 — 이동평균 창과 정지판정 창을 비운다. 유실 구간 앞뒤
    //    좌표를 평균내면 존재하지 않는 중간 지점이 만들어진다. 기준점
    //    (_lastLat/_anchorLat)은 살려둬야 복구 직후 fix의 구간 속도를 검사해
    //    유실 구간의 이상치를 걸러낼 수 있다.
    final lastFixTime = _lastFixTime;
    final gapSeconds = lastFixTime == null
        ? 0.0
        : now.difference(lastFixTime).inMilliseconds / 1000;
    // 시계 역행(기기 시간 보정 등)은 버린다.
    if (lastFixTime != null && gapSeconds <= 0) return null;
    if (gapSeconds > config.signalGapSeconds) {
      _window.clear();
      _recent.clear();
    }

    // 3) 이동평균 스무딩.
    _window.addLast(fix);
    while (_window.length > config.smoothingWindow) {
      _window.removeFirst();
    }
    var latSum = 0.0;
    var lonSum = 0.0;
    for (final f in _window) {
      latSum += f.latitude;
      lonSum += f.longitude;
    }
    final smoothLat = latSum / _window.length;
    final smoothLon = lonSum / _window.length;

    final prevLat = _lastLat;
    final prevLon = _lastLon;
    final prevTime = _lastTime;

    // 첫 fix — 기준점만 세우고 거리는 0. 상태는 정지에서 시작한다.
    if (prevLat == null || prevLon == null || prevTime == null) {
      _anchorLat = smoothLat;
      _anchorLon = smoothLon;
      _anchorTime = now;
      _lastLat = smoothLat;
      _lastLon = smoothLon;
      _lastTime = now;
      _lastFixTime = now;
      _stationary = true;
      _recent
        ..clear()
        ..addLast(_TrackPoint(smoothLat, smoothLon, now));
      return SmoothedFix(
        latitude: smoothLat,
        longitude: smoothLon,
        timestamp: now,
        stepMeters: 0,
        stepSeconds: 0,
        cumulativeDistanceMeters: _cumulativeMeters,
        instantSpeedMps: 0,
        isMoving: false,
        accuracyMeters: fix.accuracyMeters,
        altitudeMeters: fix.altitudeMeters,
        headingDegrees: fix.headingDegrees,
      );
    }

    final stepSeconds = now.difference(prevTime).inMilliseconds / 1000;
    final stepMeters = haversineMeters(prevLat, prevLon, smoothLat, smoothLon);

    // 4) 점프 제거 — 기준점을 갱신하지 않고 버린다. 이상치를 이동평균 창에서도
    //    빼내야 다음 [smoothingWindow]개 fix가 오염되지 않는다.
    if (stepSeconds > 0 && stepMeters / stepSeconds > config.maxPlausibleSpeedMps) {
      _window.removeLast();
      return null;
    }

    _lastFixTime = now;
    _pushRecent(_TrackPoint(smoothLat, smoothLon, now));

    // 5) 정지/이동 상태기계.
    var moving = false;
    var countedStep = 0.0;
    var segmentSeconds = 0.0;
    var speed = 0.0;

    if (gapSeconds > config.maxBridgeSeconds) {
      // 유실 구간이 너무 길면 이어붙이지 않는다(차량 이동 등 다른 원인일 확률이
      // 높다). 현재 위치에서 정지 상태로 다시 시작한다.
      _stationary = true;
      _anchorLat = smoothLat;
      _anchorLon = smoothLon;
      _anchorTime = now;
      _recent
        ..clear()
        ..addLast(_TrackPoint(smoothLat, smoothLon, now));
    } else if (_stationary) {
      final anchorSeconds =
          now.difference(_anchorTime ?? now).inMilliseconds / 1000;
      final displacement =
          haversineMeters(_anchorLat!, _anchorLon!, smoothLat, smoothLon);

      if (displacement >= _exitThreshold(fix)) {
        // 출발. anchor→현재 변위를 통째로 더한다 — 임계값에 도달하기까지의
        // 실제 이동을 잃지 않기 위해서다.
        _stationary = false;
        moving = true;
        countedStep = displacement;
        segmentSeconds = math.min(anchorSeconds, config.signalGapSeconds);
        speed = anchorSeconds > 0 ? displacement / anchorSeconds : 0;
      } else {
        // 계속 정지. anchor를 현재 좌표 쪽으로 아주 조금 끌어당긴다.
        _anchorLat = _anchorLat! +
            (smoothLat - _anchorLat!) * config.stationaryAnchorEma;
        _anchorLon = _anchorLon! +
            (smoothLon - _anchorLon!) * config.stationaryAnchorEma;
      }
    } else {
      // 이동 중 — 구간 누적. 구간 속도/이동량이 노이즈 수준이면 그 구간만 버린다.
      speed = stepSeconds > 0 ? stepMeters / stepSeconds : 0;
      if (speed >= config.minMovingSpeedMps && stepMeters >= _noiseFloor(fix)) {
        moving = true;
        countedStep = stepMeters;
        // 유실 구간을 통째로 이동시간에 넣지 않는다 — signalGapSeconds까지만.
        segmentSeconds = math.min(stepSeconds, config.signalGapSeconds);
      }

      // 정지 복귀 판정: 창이 충분히 찼고 그동안의 **순 변위**가 작으면 정지.
      final oldest = _recent.first;
      final windowSpan = now.difference(oldest.time).inMilliseconds / 1000;
      if (windowSpan >= _effectiveStopWindowSeconds) {
        final netMeters = haversineMeters(
          oldest.latitude,
          oldest.longitude,
          smoothLat,
          smoothLon,
        );
        if (netMeters < _enterThreshold(fix)) {
          _stationary = true;
          _anchorLat = smoothLat;
          _anchorLon = smoothLon;
          _anchorTime = now;
        }
      }
    }

    if (moving) {
      _cumulativeMeters += countedStep;
      _movingSeconds += segmentSeconds;
      // 이동 중에는 anchor를 현재 위치에 붙여 둔다 — 정지로 전환되는 순간
      // 곧바로 올바른 기준점이 되도록.
      _anchorLat = smoothLat;
      _anchorLon = smoothLon;
      _anchorTime = now;
    }

    _lastLat = smoothLat;
    _lastLon = smoothLon;
    _lastTime = now;

    return SmoothedFix(
      latitude: smoothLat,
      longitude: smoothLon,
      timestamp: now,
      stepMeters: countedStep,
      stepSeconds: stepSeconds,
      cumulativeDistanceMeters: _cumulativeMeters,
      instantSpeedMps: moving ? speed : 0,
      isMoving: moving,
      accuracyMeters: fix.accuracyMeters,
      altitudeMeters: fix.altitudeMeters,
      headingDegrees: fix.headingDegrees,
    );
  }

  /// 정지판정 창에 좌표를 넣고, 창 밖으로 밀려난 좌표를 버린다.
  /// 창 경계를 걸친 좌표 하나는 남겨 둔다 — 창 전체를 덮는 변위를 재기 위해서다.
  void _pushRecent(_TrackPoint point) {
    _recent.addLast(point);
    final cutoff = point.time.subtract(
      Duration(milliseconds: (_effectiveStopWindowSeconds * 1000).round()),
    );
    while (_recent.length > 2 && _recent.elementAt(1).time.isBefore(cutoff)) {
      _recent.removeFirst();
    }
  }
}
