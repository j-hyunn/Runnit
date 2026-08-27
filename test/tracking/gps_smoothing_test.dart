import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/tracking/domain/gps_smoothing.dart';
import 'package:runnit/features/tracking/domain/run_session_aggregator.dart';
import 'package:runnit/models/models.dart';

/// 스무딩 파이프라인의 회귀 테스트.
///
/// 핵심은 첫 번째 테스트다 — skill(`references/gps-smoothing.md` §검증 방법)이
/// 지목한 "정지 상태 5분 → 누적 거리 ≈ 0"이 실제로 성립하는지 확인한다.
void main() {
  final base = DateTime.utc(2026, 8, 20, 6);
  const seoulLat = 37.5665;
  const seoulLon = 126.9780;

  /// 위도 기준 [meters]만큼 북쪽으로 이동한 좌표.
  double latPlusMeters(double lat, double meters) => lat + meters / 111320.0;

  group('GpsTrackFilter', () {
    test('정지 상태 5분 — GPS 드리프트가 거리로 누적되지 않는다', () {
      final filter = GpsTrackFilter(profile: TrackingProfile.highAccuracy);
      final random = math.Random(42);

      // 1Hz × 300초. 매 fix가 ±4m 안에서 무작위로 흔들린다(전형적 도심 드리프트).
      for (var i = 0; i < 300; i++) {
        filter.add(
          GpsFix(
            latitude: latPlusMeters(seoulLat, (random.nextDouble() - 0.5) * 8),
            longitude: seoulLon + (random.nextDouble() - 0.5) * 8 / 88000.0,
            timestamp: base.add(Duration(seconds: i)),
            accuracyMeters: 6,
          ),
        );
      }

      // 5분간 서 있었는데 거리가 잡히면 스무딩이 깨진 것이다.
      expect(filter.cumulativeDistanceMeters, lessThan(5.0));
      expect(filter.movingSeconds, lessThan(5.0));
    });

    test('정지 5분 — 난수 시드를 바꿔도 누적 거리가 거의 0이다', () {
      // 시드 하나에서만 통과하는 임계값 튜닝이 아님을 보장한다.
      for (final seed in <int>[1, 7, 99, 2026, 31337]) {
        final filter = GpsTrackFilter(profile: TrackingProfile.standard);
        final random = math.Random(seed);
        for (var i = 0; i < 60; i++) {
          filter.add(
            GpsFix(
              latitude: latPlusMeters(seoulLat, (random.nextDouble() - 0.5) * 8),
              longitude: seoulLon + (random.nextDouble() - 0.5) * 8 / 88000.0,
              timestamp: base.add(Duration(seconds: i * 5)),
              accuracyMeters: 6,
            ),
          );
        }
        expect(
          filter.cumulativeDistanceMeters,
          lessThan(5.0),
          reason: 'seed=$seed 에서 정지 드리프트가 누적됐다',
        );
      }
    });

    test('러닝 중 신호등 정지 90초 — 정지 구간이 거리/이동시간에 들어가지 않는다', () {
      final filter = GpsTrackFilter(profile: TrackingProfile.standard);
      final random = math.Random(11);
      var meters = 0.0;

      // ① 5분 러닝(3 m/s, 5초 간격 = 15m 스텝).
      var t = 0;
      for (var i = 0; i < 60; i++, t += 5) {
        meters += 15;
        filter.add(
          GpsFix(
            latitude: latPlusMeters(seoulLat, meters),
            longitude: seoulLon,
            timestamp: base.add(Duration(seconds: t)),
            accuracyMeters: 6,
          ),
        );
      }
      final distanceAtLight = filter.cumulativeDistanceMeters;
      final movingAtLight = filter.movingSeconds;

      // ② 신호등에서 90초 정지 — 좌표는 제자리에서 흔들리기만 한다.
      for (var i = 0; i < 18; i++, t += 5) {
        filter.add(
          GpsFix(
            latitude: latPlusMeters(seoulLat, meters + (random.nextDouble() - 0.5) * 8),
            longitude: seoulLon + (random.nextDouble() - 0.5) * 8 / 88000.0,
            timestamp: base.add(Duration(seconds: t)),
            accuracyMeters: 6,
          ),
        );
      }

      // 멈춘 직후 잠시는 계속 누적된다. 대부분은 **드리프트가 아니라 이동평균
      // 지연분**이다 — 창(5) 중앙까지의 지연이 (5-1)/2 × 15m = 30m이고,
      // 그건 러너가 실제로 뛴 거리라 잃으면 안 된다. 여기에 정지 판정 창(12.5s)
      // 동안의 잔여분을 더해 40m를 상한으로 둔다. 핵심은 90초 내내 늘지 않는다는 것.
      expect(filter.cumulativeDistanceMeters - distanceAtLight, lessThan(40));
      // 이동시간도 같은 이유로 지연분(4 fix × 5s)까지만 늘고 멈춘다.
      expect(filter.movingSeconds - movingAtLight, lessThanOrEqualTo(20));

      // ③ 재출발 — 정지 구간 때문에 이후 거리를 잃으면 안 된다.
      final distanceAfterLight = filter.cumulativeDistanceMeters;
      for (var i = 0; i < 20; i++, t += 5) {
        meters += 15;
        filter.add(
          GpsFix(
            latitude: latPlusMeters(seoulLat, meters),
            longitude: seoulLon,
            timestamp: base.add(Duration(seconds: t)),
            accuracyMeters: 6,
          ),
        );
      }
      // 20스텝 × 15m = 300m. 재출발 직후에는 이동평균 창에 정지 중 좌표가
      // 남아 있어 스무딩 좌표가 뒤처지므로 약 30m가 늦게 잡힌다 —
      // 정지 진입 때 초과 계상된 30m와 정확히 상쇄되는 값이다(부호만 반대).
      // 그래서 구간별로는 ±30m, **전체 합계로는 오차가 거의 0**이다.
      expect(
        filter.cumulativeDistanceMeters - distanceAfterLight,
        greaterThan(260),
      );
      // 전체 합계 검증: 실제로 뛴 거리는 60스텝 + 20스텝 = 1200m.
      expect(filter.cumulativeDistanceMeters, greaterThan(1140));
      expect(filter.cumulativeDistanceMeters, lessThan(1230));
    });

    test('일정 속도 러닝 — 실제 이동 거리를 5% 오차 안에서 복원한다', () {
      final filter = GpsTrackFilter(profile: TrackingProfile.standard);
      // 5초 간격, 3 m/s(= 5'33"/km) → 매 스텝 15m, 총 300초 동안 900m.
      for (var i = 0; i <= 60; i++) {
        filter.add(
          GpsFix(
            latitude: latPlusMeters(seoulLat, i * 15.0),
            longitude: seoulLon,
            timestamp: base.add(Duration(seconds: i * 5)),
            accuracyMeters: 5,
          ),
        );
      }

      // 이동평균 창(5) 때문에 앞부분이 조금 눌린다 — 그래서 하한을 850m로 둔다.
      expect(filter.cumulativeDistanceMeters, greaterThan(850));
      expect(filter.cumulativeDistanceMeters, lessThan(945));
      expect(filter.movingSeconds, greaterThan(250));
    });

    test('정확도가 나쁜 fix와 순간이동 fix는 버려진다', () {
      final filter = GpsTrackFilter(profile: TrackingProfile.standard);

      // 첫 fix로 기준점을 세운다.
      expect(
        filter.add(
          GpsFix(
            latitude: seoulLat,
            longitude: seoulLon,
            timestamp: base,
            accuracyMeters: 5,
          ),
        ),
        isNotNull,
      );

      // 정확도 60m — 정확도 게이트(25m)에 걸린다.
      expect(
        filter.add(
          GpsFix(
            latitude: latPlusMeters(seoulLat, 10),
            longitude: seoulLon,
            timestamp: base.add(const Duration(seconds: 5)),
            accuracyMeters: 60,
          ),
        ),
        isNull,
      );

      // 5초 만에 2km 이동 = 400 m/s — 점프 게이트에 걸린다.
      expect(
        filter.add(
          GpsFix(
            latitude: latPlusMeters(seoulLat, 2000),
            longitude: seoulLon,
            timestamp: base.add(const Duration(seconds: 10)),
            accuracyMeters: 5,
          ),
        ),
        isNull,
      );

      expect(filter.cumulativeDistanceMeters, 0);
    });
  });

  group('RunSessionAggregator', () {
    RunSessionAggregator makeAggregator() => RunSessionAggregator(
          recordId: 'run-1',
          userId: 'user-1',
          activityType: ActivityType.outdoorRun,
          startedAt: base,
          profile: TrackingProfile.standard,
          weightKg: 70,
        );

    test('일시정지 중에는 movingSeconds도 거리도 늘지 않는다', () {
      final aggregator = makeAggregator();

      for (var i = 0; i <= 20; i++) {
        aggregator.addFix(
          GpsFix(
            latitude: latPlusMeters(seoulLat, i * 15.0),
            longitude: seoulLon,
            timestamp: base.add(Duration(seconds: i * 5)),
            accuracyMeters: 5,
          ),
        );
      }
      final movingBefore = aggregator.movingSeconds;
      final distanceBefore = aggregator.distanceMeters;

      aggregator.pause();
      // 일시정지 동안 들어온 fix는 통째로 무시된다.
      for (var i = 21; i <= 40; i++) {
        expect(
          aggregator.addFix(
            GpsFix(
              latitude: latPlusMeters(seoulLat, i * 15.0),
              longitude: seoulLon,
              timestamp: base.add(Duration(seconds: i * 5)),
              accuracyMeters: 5,
            ),
          ),
          isNull,
        );
      }

      expect(aggregator.movingSeconds, movingBefore);
      expect(aggregator.distanceMeters, distanceBefore);

      // 재개 직후 첫 fix가 일시정지 구간 거리를 한 번에 몰아넣으면 안 된다.
      aggregator.resume();
      aggregator.addFix(
        GpsFix(
          latitude: latPlusMeters(seoulLat, 41 * 15.0),
          longitude: seoulLon,
          timestamp: base.add(const Duration(seconds: 41 * 5)),
          accuracyMeters: 5,
        ),
      );
      expect(aggregator.distanceMeters, distanceBefore);
    });

    test('snapshot — elapsed는 벽시계, moving은 이동 시간, 페이스는 moving 기준', () {
      final aggregator = makeAggregator();
      for (var i = 0; i <= 60; i++) {
        aggregator.addFix(
          GpsFix(
            latitude: latPlusMeters(seoulLat, i * 15.0),
            longitude: seoulLon,
            timestamp: base.add(Duration(seconds: i * 5)),
            accuracyMeters: 5,
            altitudeMeters: 30,
          ),
        );
      }

      final endedAt = base.add(const Duration(seconds: 400));
      final record = aggregator.snapshot(
        now: endedAt,
        endedAt: endedAt,
        status: RunStatus.completed,
        includeSamples: true,
      );

      // 벽시계 400초 > 이동시간(정지·필터 제외분만큼 작다).
      expect(record.elapsedSeconds, 400);
      expect(record.movingSeconds, lessThanOrEqualTo(record.elapsedSeconds));
      expect(
        record.avgPaceSecPerKm,
        closeTo(record.movingSeconds / (record.distanceMeters / 1000), 0.001),
      );
      expect(record.samples, isNotEmpty);
      expect(record.samples.first.source, RunSampleSource.phone);
      expect(record.routePolyline, isNotEmpty);
      expect(record.caloriesKcal, greaterThan(0));
      // 고도가 일정하면 상승고도는 잡히지 않아야 한다(데드밴드).
      expect(record.elevationGainMeters, isNull);
    });

    test('워치 심박이 붙으면 sources에 watch가 들어간다', () {
      final aggregator = makeAggregator();
      aggregator.addFix(
        GpsFix(
          latitude: seoulLat,
          longitude: seoulLon,
          timestamp: base,
          accuracyMeters: 5,
        ),
      );
      aggregator.offerWearableMetrics(heartRateBpm: 152);
      final sample = aggregator.addFix(
        GpsFix(
          latitude: latPlusMeters(seoulLat, 15),
          longitude: seoulLon,
          timestamp: base.add(const Duration(seconds: 5)),
          accuracyMeters: 5,
        ),
      );

      expect(sample?.heartRateBpm, 152);
      final record = aggregator.snapshot(now: base, status: RunStatus.recording);
      expect(record.sources, contains(RunSampleSource.watch));
      expect(record.sources, contains(RunSampleSource.phone));
      expect(record.avgHeartRateBpm, 152);
    });
  });

  // 뱃지 `device_source_count_gte`(애플워치런/가민런 등)와
  // `device_source_diversity_gte`(올라운더)의 원천 데이터.
  group('deviceVendors', () {
    RunSessionAggregator makeAggregator() => RunSessionAggregator(
          recordId: 'r-vendor',
          userId: 'u1',
          activityType: ActivityType.outdoorRun,
          startedAt: base,
        );

    test('폰 단독 세션은 정확히 [phone]이다 — "폰 단독 기록" 판정의 근거', () {
      final aggregator = makeAggregator();
      aggregator.addFix(
        GpsFix(
          latitude: seoulLat,
          longitude: seoulLon,
          timestamp: base,
          accuracyMeters: 5,
        ),
      );

      final record =
          aggregator.snapshot(now: base, status: RunStatus.recording);
      expect(record.deviceVendors, <DeviceVendor>[DeviceVendor.phone]);
    });

    test('fix가 하나도 없어도 phone은 기여자다 (집계기는 폰 세션에서만 돈다)', () {
      final record = makeAggregator()
          .snapshot(now: base, status: RunStatus.recording);
      expect(record.deviceVendors, <DeviceVendor>[DeviceVendor.phone]);
    });

    test('애플워치 심박이 붙으면 [phone, watchApple] — 하이브리드 세션', () {
      final aggregator = makeAggregator();
      aggregator.addFix(
        GpsFix(
          latitude: seoulLat,
          longitude: seoulLon,
          timestamp: base,
          accuracyMeters: 5,
        ),
      );
      aggregator.offerWearableMetrics(
        heartRateBpm: 150,
        vendor: DeviceVendor.watchApple,
      );

      final record =
          aggregator.snapshot(now: base, status: RunStatus.recording);
      // enum 선언 순서로 정렬돼 payload가 결정적이다.
      expect(
        record.deviceVendors,
        <DeviceVendor>[DeviceVendor.phone, DeviceVendor.watchApple],
      );
    });

    test('워치 지표 직후 GPS가 끊겨도 벤더는 남는다 (터널 회귀)', () {
      final aggregator = makeAggregator();
      // fix 없이 심박만 도착 → 이후 fix가 영영 안 와도 워치 기여가 유실되면 안 된다.
      aggregator.offerWearableMetrics(
        heartRateBpm: 148,
        source: RunSampleSource.external,
        vendor: DeviceVendor.watchGarmin,
      );

      final record =
          aggregator.snapshot(now: base, status: RunStatus.recording);
      expect(record.deviceVendors, contains(DeviceVendor.watchGarmin));
    });
  });
}
