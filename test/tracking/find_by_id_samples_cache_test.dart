import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/core/error/failure.dart';
import 'package:runnit/features/tracking/data/local_run_database.dart';
import 'package:runnit/features/tracking/data/local_run_repository.dart';
import 'package:runnit/models/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// QA I-2 회귀: `findById`가 **samples 없이 캐시된 불완전한 로컬 행**을
/// 상세 조회에 그대로 내주면 안 된다.
///
/// 예전 버그: 로컬 미스 → 원격을 `includeSamples:false`로 가져와 → 그 빈
/// samples 행을 로컬에 영구 캐시 → 이후 `includeSamples:true` 조회가 로컬
/// 히트로 빈 samples를 반환(재조회로도 복구 불가). 상세 화면·공유 카드가
/// 조용히 깨진다.
void main() {
  late LocalRunDatabase db;
  late LocalRunRepository repository;

  setUp(() {
    db = LocalRunDatabase.forTesting(NativeDatabase.memory());
    // 원격은 도달 불가한 주소. "원격을 시도했는가"는 예외 발생 여부로 관찰한다.
    repository = LocalRunRepository(
      db,
      SupabaseClient('http://127.0.0.1:1', 'test-anon-key'),
    );
  });

  tearDown(() async {
    await db.close();
  });

  RunRecord base({
    required List<RunSample> samples,
    String? routePolyline,
  }) =>
      RunRecord(
        id: 'run-1',
        userId: 'user-1',
        startedAt: DateTime.utc(2026, 8, 26, 6),
        endedAt: DateTime.utc(2026, 8, 26, 6, 30),
        activityType: ActivityType.outdoorRun,
        status: RunStatus.completed,
        distanceMeters: 5000,
        elapsedSeconds: 1800,
        movingSeconds: 1750,
        routePolyline: routePolyline,
        syncStatus: SyncStatus.synced,
        samples: samples,
      );

  RunSample sample(int sec) => RunSample(
        timestamp: DateTime.utc(2026, 8, 26, 6, 0, sec),
        latitude: 37.5 + sec * 0.0001,
        longitude: 127.0,
        source: RunSampleSource.phone,
        cumulativeDistanceMeters: sec * 3.0,
      );

  Future<void> insert(RunRecord record) =>
      db.into(db.runRecordRows).insertOnConflictUpdate(record.toRow());

  test('경로가 있는데 samples가 빈 로컬 행은 그대로 내주지 않고 원격을 시도한다',
      () async {
    // routePolyline은 있는데 samples가 비어 있음 = 불완전 캐시.
    await insert(base(samples: const [], routePolyline: 'abc_def'));

    await expectLater(
      repository.findById('run-1', includeSamples: true),
      throwsA(isA<Failure>()), // 로컬로 끝내지 않고 원격을 탔다는 증거
    );
  });

  test('samples가 채워진 로컬 행은 원격 없이 그대로 반환한다', () async {
    await insert(
      base(samples: [sample(1), sample(2), sample(3)], routePolyline: 'abc_def'),
    );

    final record = await repository.findById('run-1', includeSamples: true);

    expect(record, isNotNull);
    expect(record!.samples, hasLength(3));
  });

  test('includeSamples:false는 samples 유무와 무관하게 빈 samples를 반환한다', () async {
    await insert(
      base(samples: [sample(1), sample(2)], routePolyline: 'abc_def'),
    );

    final record = await repository.findById('run-1');

    expect(record, isNotNull);
    expect(record!.samples, isEmpty);
  });

  test('경로가 없는 기록(실내·수동)은 samples가 비어도 불완전으로 보지 않는다',
      () async {
    await insert(base(samples: const [], routePolyline: null)
        .copyWith(activityType: ActivityType.indoorRun));

    final record = await repository.findById('run-1', includeSamples: true);

    expect(record, isNotNull);
    expect(record!.samples, isEmpty);
  });
}
