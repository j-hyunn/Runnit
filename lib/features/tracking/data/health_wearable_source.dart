import 'dart:async';
import 'dart:io' show Platform;

import 'package:health/health.dart';

import '../../../models/models.dart';

/// 러닝 중 워치 지표(현재는 심박수)를 폰으로 끌어오는 어댑터.
///
/// ## 왜 스트림이 아니라 폴링인가
/// HealthKit도 Health Connect도 "지금 이 순간의 심박수"를 밀어주는 공개
/// 스트림 API가 없다. 둘 다 *저장소*이고, 워치가 쓴 값을 폰이 읽는 구조다.
/// 그래서 [pollInterval]마다 최근 [lookback] 구간을 조회해 가장 최신
/// 데이터포인트를 취한다(skill: android-health-connect.md §4).
///
/// ## 기기별 경로 (skill §3)
/// - **Apple Watch**: HealthKit에 거의 실시간으로 쓰인다 → 지연 수 초.
///   `source = watch`.
/// - **Garmin**: Garmin Connect 앱이 HealthKit(iOS)/Health Connect(Android)로
///   **동기화한 뒤에야** 보인다 → 러닝 중에는 대개 아무것도 안 보인다.
///   `sourceName`에 garmin이 들어가면 `source = external`로 표기해
///   (`RunSampleSource.external` = 사후 임포트, enums.dart 주석) 소비 측이
///   실시간 값이 아님을 구분할 수 있게 한다.
///   → UI는 "워치 데이터는 동기화 후 반영됩니다" 안내를 띄워야 한다.
///
/// ## 폴백이 정상 경로다
/// 워치가 없거나 권한이 거부돼도 **에러가 아니다.** [ensureAuthorized]가 false를
/// 돌려주면 트래킹 서비스는 폰 GPS 단독으로 그대로 진행한다.
class WearableMetricSample {
  const WearableMetricSample({
    required this.heartRateBpm,
    required this.source,
    this.deviceName,
  });

  final int heartRateBpm;
  final RunSampleSource source;

  /// HealthKit/Health Connect가 알려주는 기록 주체 앱/기기 이름
  /// (예: `Garmin Connect`, `Apple Watch`). UI 안내 문구에 쓴다.
  final String? deviceName;
}

abstract interface class WearableMetricsSource {
  /// 건강 데이터 권한을 요청한다. **위치 권한과 별개 플로우**(skill §2-3).
  /// 거부/미지원이면 false — 예외를 던지지 않는다.
  Future<bool> ensureAuthorized();

  /// 러닝 중 심박수 폴링 스트림. 값이 없으면 아무것도 방출하지 않는다.
  Stream<WearableMetricSample> watch();

  /// 러닝을 시작하지 않은 **대기 화면에서도** "연동된 기기가 있는지"를
  /// 보여주기 위한 1회성 조회. [watch]와 달리 세션 상태와 무관하다 —
  /// `GeolocatorRunTrackingService.wearableConnected`는 진행 중 세션에서
  /// 실제로 심박수 샘플을 한 번이라도 받아야만 true가 되는 값이라 대기
  /// 화면에는 쓸 수 없다. 권한이 없거나 최근 데이터가 없으면 null.
  Future<String?> latestDeviceName({Duration lookback = const Duration(days: 7)});
}

class HealthWearableMetricsSource implements WearableMetricsSource {
  HealthWearableMetricsSource({
    this.pollInterval = const Duration(seconds: 10),
    this.lookback = const Duration(seconds: 60),
  });

  final Duration pollInterval;
  final Duration lookback;

  final Health _health = Health();
  bool _configured = false;
  bool _authorized = false;

  static const List<HealthDataType> _types = <HealthDataType>[
    HealthDataType.HEART_RATE,
  ];

  @override
  Future<bool> ensureAuthorized() async {
    if (!Platform.isIOS && !Platform.isAndroid) return false;
    try {
      if (!_configured) {
        await _health.configure();
        _configured = true;
      }
      if (!_health.isDataTypeAvailable(HealthDataType.HEART_RATE)) {
        return false;
      }
      // iOS는 READ 권한 부여 여부를 앱에 알려주지 않는다(사생활 보호 설계).
      // 따라서 true는 "다이얼로그가 오류 없이 떴다"는 뜻일 뿐이다 —
      // 실제 판단은 조회 결과가 비었는지로 한다(skill: ios-healthkit.md §함정).
      _authorized = await _health.requestAuthorization(
        _types,
        permissions: const <HealthDataAccess>[HealthDataAccess.READ],
      );
      return _authorized;
    } catch (_) {
      // 헬스 스택 부재(Health Connect 미설치 등)는 실패가 아니라 폴백 신호다.
      return false;
    }
  }

  @override
  Stream<WearableMetricSample> watch() async* {
    if (!_authorized) return;

    String? lastUuid;
    while (true) {
      await Future<void>.delayed(pollInterval);
      final now = DateTime.now();
      List<HealthDataPoint> points;
      try {
        points = await _health.getHealthDataFromTypes(
          types: _types,
          startTime: now.subtract(lookback),
          endTime: now,
        );
      } catch (_) {
        continue; // 일시적 조회 실패로 러닝을 중단시키지 않는다.
      }
      if (points.isEmpty) continue;

      points.sort((a, b) => a.dateTo.compareTo(b.dateTo));
      final latest = points.last;
      if (latest.uuid == lastUuid) continue;
      lastUuid = latest.uuid;

      final value = latest.value;
      if (value is! NumericHealthValue) continue;
      final bpm = value.numericValue.round();
      if (bpm <= 0 || bpm > 260) continue;

      yield WearableMetricSample(
        heartRateBpm: bpm,
        source: sourceFor(latest.sourceName),
        deviceName: latest.sourceName,
      );
    }
  }

  @override
  Future<String?> latestDeviceName({
    Duration lookback = const Duration(days: 7),
  }) async {
    final authorized = await ensureAuthorized();
    if (!authorized) return null;
    try {
      final now = DateTime.now();
      final points = await _health.getHealthDataFromTypes(
        types: _types,
        startTime: now.subtract(lookback),
        endTime: now,
      );
      if (points.isEmpty) return null;
      points.sort((a, b) => a.dateTo.compareTo(b.dateTo));
      return points.last.sourceName;
    } catch (_) {
      return null;
    }
  }

  /// 기록 주체 이름 → [RunSampleSource]. Garmin Connect 동기화분은
  /// 실시간이 아니므로 `external`로 구분한다.
  static RunSampleSource sourceFor(String? sourceName) {
    final name = (sourceName ?? '').toLowerCase();
    if (name.contains('garmin')) return RunSampleSource.external;
    return RunSampleSource.watch;
  }
}
