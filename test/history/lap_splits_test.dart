import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/history/domain/lap_splits.dart';
import 'package:runnit/models/models.dart';

/// `computeLapSplits`의 계약 — 서버 `_run_km_split_seconds` / `_run_time_at_distance`
/// (마이그레이션 41)와 같은 보간 규칙을 쓰는지, 그리고 화면이 의존하는
/// 자투리 구간·폴백 동작이 유지되는지 검증한다.
void main() {
  final t0 = DateTime.utc(2026, 8, 27, 0, 0, 0);

  /// 누적거리를 직접 지정하는 샘플 — 서버가 실제로 보는 입력과 같은 축이다.
  RunSample cum(double meters, int seconds, {int? hr, double? altitude}) =>
      RunSample(
        timestamp: t0.add(Duration(seconds: seconds)),
        cumulativeDistanceMeters: meters,
        latitude: 37.5,
        longitude: 127.0,
        heartRateBpm: hr,
        altitudeMeters: altitude,
        source: RunSampleSource.phone,
      );

  /// 좌표만 있는 샘플 — `cumulativeDistanceMeters` 폴백 경로를 태운다.
  /// 적도 위를 동쪽으로 달리게 해서 Haversine 거리가 경도 차에 비례하게 만든다.
  RunSample coord(double lonDegrees, int seconds) => RunSample(
        timestamp: t0.add(Duration(seconds: seconds)),
        latitude: 0,
        longitude: lonDegrees,
        source: RunSampleSource.phone,
      );

  RunRecord record(List<RunSample> samples) => RunRecord(
        id: 'run-1',
        userId: 'user-1',
        startedAt: t0,
        endedAt: samples.isEmpty ? t0 : samples.last.timestamp,
        activityType: ActivityType.outdoorRun,
        status: RunStatus.completed,
        distanceMeters: samples.isEmpty
            ? 0
            : (samples.last.cumulativeDistanceMeters ?? 0),
        elapsedSeconds:
            samples.isEmpty ? 0 : samples.last.timestamp.difference(t0).inSeconds,
        movingSeconds:
            samples.isEmpty ? 0 : samples.last.timestamp.difference(t0).inSeconds,
        samples: samples,
      );

  group('완전 구간', () {
    test('정확히 3km면 자투리 없이 3랩이 나온다', () {
      // 300s/km 등속. 100m마다 샘플.
      final samples = [
        for (var i = 0; i <= 30; i++) cum(i * 100.0, i * 30),
      ];

      final splits = computeLapSplits(record(samples));

      expect(splits, hasLength(3));
      expect(splits.map((s) => s.index), [1, 2, 3]);
      expect(splits.every((s) => !s.isPartial), isTrue);
      expect(splits.map((s) => s.distanceMeters), everyElement(1000.0));
      expect(splits.map((s) => s.durationSeconds), [300, 300, 300]);
      expect(splits.map((s) => s.paceSecPerKm), everyElement(300.0));
    });

    test('랩마다 페이스가 다르면 그대로 반영된다', () {
      final splits = computeLapSplits(
        record([
          cum(0, 0),
          cum(1000, 300), // 5'00"
          cum(2000, 560), // 4'20"
          cum(3000, 890), // 5'30"
        ]),
      );

      expect(splits.map((s) => s.durationSeconds), [300, 260, 330]);
      // 화면이 "가장 빠른 구간"으로 강조하는 값.
      final fastest =
          splits.map((s) => s.paceSecPerKm).reduce((a, b) => a < b ? a : b);
      expect(fastest, 260.0);
    });
  });

  group('자투리 구간', () {
    test('2.5km면 완전 2랩 + 자투리 1랩이 나온다', () {
      final splits = computeLapSplits(
        record([
          cum(0, 0),
          cum(1000, 300),
          cum(2000, 600),
          cum(2500, 750),
        ]),
      );

      expect(splits, hasLength(3));
      expect(splits[0].isPartial, isFalse);
      expect(splits[1].isPartial, isFalse);

      final partial = splits[2];
      expect(partial.isPartial, isTrue);
      expect(partial.index, 3);
      expect(partial.distanceMeters, 500.0);
      expect(partial.durationSeconds, 150);
      // 자투리도 페이스는 s/km로 환산한다 — 500m를 150초면 300s/km.
      expect(partial.paceSecPerKm, closeTo(300.0, 0.001));
    });

    test('50m 미만의 꼬리는 자투리로 만들지 않는다', () {
      // 종료 직전 좌표 흔들림 수준의 잔여 거리는 페이스가 무의미하게 튄다.
      final splits = computeLapSplits(
        record([cum(0, 0), cum(1000, 300), cum(1020, 306)]),
      );

      expect(splits, hasLength(1));
      expect(splits.single.isPartial, isFalse);
    });

    test('1km를 못 채운 러닝은 자투리 한 랩만 나온다', () {
      final splits = computeLapSplits(
        record([cum(0, 0), cum(600, 180)]),
      );

      expect(splits, hasLength(1));
      expect(splits.single.index, 1);
      expect(splits.single.isPartial, isTrue);
      expect(splits.single.distanceMeters, 600.0);
    });
  });

  group('경계 시각 선형 보간 (서버 _run_time_at_distance와 동일 규칙)', () {
    test('샘플 간격이 60초를 넘어도 km 경계를 보간한다', () {
      // 워치 임포트 시나리오: 0m→1500m 사이에 샘플이 하나도 없다.
      // 무보간이면 1랩 = 300초로 잘못 나온다. 보간하면 1000/1500 * 300 = 200초.
      final splits = computeLapSplits(
        record([cum(0, 0), cum(1500, 300)]),
      );

      expect(splits, hasLength(2));
      expect(splits[0].isPartial, isFalse);
      expect(splits[0].durationSeconds, 200);
      expect(splits[0].paceSecPerKm, closeTo(200.0, 0.001));

      expect(splits[1].isPartial, isTrue);
      expect(splits[1].distanceMeters, 500.0);
      expect(splits[1].durationSeconds, 100);
    });

    test('경계가 두 샘플 사이 임의 비율에 있어도 정확하다', () {
      // 900m(t=90) → 1400m(t=190). 1000m 지점은 (1000-900)/500 = 0.2 →
      // 90 + 100*0.2 = 110초.
      final splits = computeLapSplits(
        record([cum(0, 0), cum(900, 90), cum(1400, 190)]),
      );

      expect(splits[0].durationSeconds, 110);
    });

    test('누적거리가 제자리인 구간(일시정지)이 있어도 깨지지 않는다', () {
      final splits = computeLapSplits(
        record([
          cum(0, 0),
          cum(500, 150),
          cum(500, 400), // 250초 정지
          cum(1000, 550),
        ]),
      );

      expect(splits, hasLength(1));
      // 랩 시간은 정지 시간을 포함한 벽시계 기준이다(샘플 타임스탬프 그대로).
      expect(splits.single.durationSeconds, 550);
    });
  });

  group('거리 원천', () {
    test('cumulativeDistanceMeters가 있으면 그 값을 쓴다', () {
      // 좌표는 전부 같은 지점이라 Haversine으로는 0m다. 그래도 랩이 나온다면
      // 누적거리 축을 쓴 것이다.
      final splits = computeLapSplits(
        record([cum(0, 0), cum(1000, 300), cum(2000, 600)]),
      );

      expect(splits, hasLength(2));
    });

    test('cumulativeDistanceMeters가 없으면 좌표 Haversine으로 폴백한다', () {
      // 적도에서 경도 1° ≈ 111.19km. 3km ≈ 0.026980°.
      const totalLon = 0.0269805;
      final samples = [
        for (var i = 0; i <= 30; i++) coord(totalLon * i / 30, i * 30),
      ];

      final splits = computeLapSplits(record(samples));

      expect(splits, hasLength(3));
      expect(splits.every((s) => !s.isPartial), isTrue);
      // 등속이므로 세 랩 모두 300초 근처.
      for (final s in splits) {
        expect(s.durationSeconds, closeTo(300, 2));
      }
    });

    test('누적거리 샘플이 1개뿐이면 좌표 폴백으로 넘어간다', () {
      final samples = [
        coord(0, 0),
        RunSample(
          timestamp: t0.add(const Duration(seconds: 150)),
          latitude: 0,
          longitude: 0.0134902,
          cumulativeDistanceMeters: 1500, // 혼자만 있는 누적값
          source: RunSampleSource.phone,
        ),
        coord(0.0269805, 300),
      ];

      final splits = computeLapSplits(record(samples));

      // 폴백(Haversine)이 걸렸다면 총 3km → 3랩.
      expect(splits, hasLength(3));
    });
  });

  group('랩을 만들지 않는 경우', () {
    test('샘플이 없으면 빈 리스트', () {
      expect(computeLapSplits(record(const [])), isEmpty);
    });

    test('좌표도 누적거리도 없는 실내 러닝은 빈 리스트', () {
      final samples = [
        for (var i = 0; i <= 10; i++)
          RunSample(
            timestamp: t0.add(Duration(seconds: i * 60)),
            heartRateBpm: 150,
            source: RunSampleSource.watch,
          ),
      ];

      expect(computeLapSplits(record(samples)), isEmpty);
    });

    test('샘플이 1개면 빈 리스트', () {
      expect(computeLapSplits(record([cum(0, 0)])), isEmpty);
    });

    test('총 거리가 100m 미만이면 빈 리스트', () {
      expect(computeLapSplits(record([cum(0, 0), cum(80, 30)])), isEmpty);
    });

    test('시각이 역행하거나 중복된 샘플은 버린다', () {
      final splits = computeLapSplits(
        record([
          cum(0, 0),
          cum(500, 150),
          cum(400, 150), // 같은 초 — 버림
          cum(300, 100), // 역행 — 버림
          cum(1000, 300),
        ]),
      );

      expect(splits, hasLength(1));
      expect(splits.single.durationSeconds, 300);
    });
  });

  group('구간 부가 지표', () {
    test('구간 내 심박 평균을 낸다', () {
      final splits = computeLapSplits(
        record([
          cum(0, 0, hr: 100),
          cum(500, 150, hr: 140),
          cum(1000, 300, hr: 160),
          cum(1500, 450, hr: 180),
          cum(2000, 600, hr: 200),
        ]),
      );

      // 1랩 = (0m, 1000m] 구간의 샘플 → 140, 160.
      expect(splits[0].avgHeartRateBpm, 150);
      // 2랩 = (1000m, 2000m] → 180, 200.
      expect(splits[1].avgHeartRateBpm, 190);
    });

    test('심박이 없으면 null', () {
      final splits = computeLapSplits(
        record([cum(0, 0), cum(1000, 300), cum(2000, 600)]),
      );

      expect(splits.every((s) => s.avgHeartRateBpm == null), isTrue);
    });

    test('상승분만 누적해 고도 게인을 낸다', () {
      final splits = computeLapSplits(
        record([
          cum(0, 0, altitude: 10),
          cum(300, 90, altitude: 20), // +10
          cum(600, 180, altitude: 15), // 하강은 무시
          cum(1000, 300, altitude: 25), // +10
        ]),
      );

      expect(splits.single.elevationGainMeters, closeTo(20.0, 0.001));
    });

    test('구간 경계를 넘는 오르막도 다음 랩에 계산된다', () {
      // 1000m(10m) → 1300m(40m)의 +30은 2랩의 것이다. 구간 시작 직전 샘플을
      // 기준점으로 넣지 않으면 이 상승이 통째로 사라진다.
      final splits = computeLapSplits(
        record([
          cum(0, 0, altitude: 10),
          cum(1000, 300, altitude: 10),
          cum(1300, 390, altitude: 40),
          cum(2000, 600, altitude: 40),
        ]),
      );

      expect(splits[0].elevationGainMeters, closeTo(0.0, 0.001));
      expect(splits[1].elevationGainMeters, closeTo(30.0, 0.001));
    });
  });
}
