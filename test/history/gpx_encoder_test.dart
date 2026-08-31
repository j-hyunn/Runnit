import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/history/domain/gpx_encoder.dart';
import 'package:runnit/models/models.dart';

/// GPX 1.1 직렬화(HI-09) 단위 테스트 — 정상 경로, 고도/심박 유무, XML 이스케이프,
/// 실내 러닝(좌표 없음), 좌표 null 샘플 스킵.
void main() {
  final t0 = DateTime.utc(2026, 8, 27, 6, 0, 0);

  RunSample sample(
    int seconds, {
    double? lat = 37.5,
    double? lon = 127.0,
    double? ele,
    int? hr,
    int? cad,
  }) =>
      RunSample(
        timestamp: t0.add(Duration(seconds: seconds)),
        latitude: lat,
        longitude: lon,
        altitudeMeters: ele,
        heartRateBpm: hr,
        cadenceSpm: cad,
        source: RunSampleSource.phone,
      );

  RunRecord run({
    required List<RunSample> samples,
    String? title,
    ActivityType activityType = ActivityType.outdoorRun,
  }) =>
      RunRecord(
        id: 'run-1',
        userId: 'user-1',
        startedAt: t0,
        endedAt: t0.add(const Duration(seconds: 600)),
        activityType: activityType,
        status: RunStatus.completed,
        distanceMeters: 2000,
        elapsedSeconds: 600,
        movingSeconds: 600,
        title: title,
        samples: samples,
      );

  test('정상 경로 — gpx 헤더/metadata/trkpt 구조를 만든다', () {
    final gpx = encodeRunAsGpx(run(samples: [
      sample(0, lat: 37.5001234, lon: 127.0009876),
      sample(30, lat: 37.5011234, lon: 127.0019876),
    ]));

    expect(gpx, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
    expect(gpx, contains('<gpx version="1.1" creator="Runnit"'));
    expect(gpx, contains('<metadata>'));
    expect(gpx, contains('<time>2026-08-27T06:00:00Z</time>'));
    expect(gpx, contains('<trkpt lat="37.5001234" lon="127.0009876">'));
    expect(gpx, contains('<time>2026-08-27T06:00:30Z</time>'));
    expect(gpx, contains('<type>running</type>'));
    expect(gpx.trim(), endsWith('</gpx>'));
    // 좌표만 있는 샘플엔 ele/extensions가 없다.
    expect(gpx, isNot(contains('<ele>')));
    expect(gpx, isNot(contains('<extensions>')));
  });

  test('고도·심박·케이던스가 있으면 해당 요소를 포함한다', () {
    final gpx = encodeRunAsGpx(run(samples: [
      sample(0, ele: 12.34, hr: 150, cad: 172),
      sample(30, ele: 15.0, hr: 155),
    ]));

    expect(gpx, contains('<ele>12.3</ele>'));
    expect(gpx, contains('<gpxtpx:TrackPointExtension>'));
    expect(gpx, contains('<gpxtpx:hr>150</gpxtpx:hr>'));
    expect(gpx, contains('<gpxtpx:cad>172</gpxtpx:cad>'));
  });

  test('제목의 XML 특수문자를 이스케이프한다', () {
    final gpx = encodeRunAsGpx(run(
      title: 'Tom & <Jerry> "run" \'x\'',
      samples: [sample(0), sample(30)],
    ));

    expect(gpx, contains('<name>Tom &amp; &lt;Jerry&gt; &quot;run&quot; &apos;x&apos;</name>'));
    expect(gpx, isNot(contains('<Jerry>')));
  });

  test('제목이 없으면 날짜 기반 이름을 쓴다', () {
    final gpx = encodeRunAsGpx(run(samples: [sample(0), sample(30)]));
    expect(gpx, contains('<name>Runnit 2026-08-27</name>'));
  });

  test('좌표 null 샘플은 trkpt에서 제외된다', () {
    final gpx = encodeRunAsGpx(run(samples: [
      sample(0),
      sample(15, lat: null, lon: null, hr: 140),
      sample(30),
    ]));

    expect('<trkpt'.allMatches(gpx).length, 2);
  });

  test('실내 러닝(좌표 없음)은 내보낼 경로가 없다', () {
    final indoor = run(
      activityType: ActivityType.indoorRun,
      samples: [
        sample(0, lat: null, lon: null),
        sample(30, lat: null, lon: null),
      ],
    );
    expect(hasExportableRoute(indoor), isFalse);
  });

  test('좌표 샘플이 1개뿐이면 트랙으로 부족하다', () {
    expect(hasExportableRoute(run(samples: [sample(0)])), isFalse);
    expect(hasExportableRoute(run(samples: [sample(0), sample(30)])), isTrue);
  });

  test('walk는 gpx type이 walking', () {
    final gpx = encodeRunAsGpx(run(
      activityType: ActivityType.walk,
      samples: [sample(0), sample(30)],
    ));
    expect(gpx, contains('<type>walking</type>'));
  });
}
