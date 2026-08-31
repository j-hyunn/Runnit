import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/core/error/failure.dart';
import 'package:runnit/features/tracking/data/local_run_database.dart';
import 'package:runnit/features/tracking/data/local_run_repository.dart';
import 'package:runnit/models/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// QA C-1·C-2 회귀: `updateMeta`의 분기 근거는 **로컬 `sync_status`**여야 한다.
///
/// - 아직 서버에 없는 기록(`pending`/`failed`/`local`)은 네트워크를 아예 타지
///   않는다. 오프라인에서 메모를 못 쓰면 오프라인 우선 아키텍처가 겨냥한 국면에서
///   막히는 셈이다.
/// - `synced` 기록은 반드시 서버를 친다. 응답이 0행이면 로컬만 고치지 않고
///   에러로 표면화한다 — 그러지 않으면 `syncPending()`이 재전송하지 않는 채
///   영구 divergence가 생기는데 사용자에겐 성공으로 보인다.
///
/// 원격 주소를 도달 불가로 두어 **"네트워크를 탔는가"를 예외 발생 여부로 관찰**한다
/// (`find_by_id_samples_cache_test.dart`와 같은 수법).
void main() {
  late LocalRunDatabase db;
  late LocalRunRepository repository;

  setUp(() {
    db = LocalRunDatabase.forTesting(NativeDatabase.memory());
    repository = LocalRunRepository(
      db,
      SupabaseClient('http://127.0.0.1:1', 'test-anon-key'),
    );
  });

  tearDown(() async {
    await db.close();
  });

  RunRecord run(SyncStatus syncStatus) => RunRecord(
        id: 'run-1',
        userId: 'user-1',
        startedAt: DateTime.utc(2026, 8, 31, 6),
        endedAt: DateTime.utc(2026, 8, 31, 6, 30),
        activityType: ActivityType.outdoorRun,
        status: RunStatus.completed,
        distanceMeters: 5000,
        elapsedSeconds: 1800,
        movingSeconds: 1750,
        syncStatus: syncStatus,
      );

  Future<void> insert(RunRecord record) =>
      db.into(db.runRecordRows).insertOnConflictUpdate(record.toRow());

  Future<Map<String, dynamic>> summaryOf(String id) async {
    final row = await (db.select(db.runRecordRows)
          ..where((t) => t.id.equals(id)))
        .getSingle();
    return jsonDecode(row.summaryJson) as Map<String, dynamic>;
  }

  test('미업로드(pending) 기록은 네트워크 없이 로컬에서 편집된다', () async {
    await insert(run(SyncStatus.pending));

    final meta = await repository.updateMeta(
      'run-1',
      title: '  지하 주차장 러닝  ',
      note: '',
    );

    // 서버 가드와 같은 규칙: btrim → 절단 → 빈 문자열은 null.
    expect(meta.title, '지하 주차장 러닝');
    expect(meta.note, isNull);

    final summary = await summaryOf('run-1');
    expect(summary['title'], '지하 주차장 러닝');
    expect(summary['note'], isNull);
    // 동기화 큐에서 빠지면 `syncPending()`이 이 값을 못 올린다.
    final row = await (db.select(db.runRecordRows)
          ..where((t) => t.id.equals('run-1')))
        .getSingle();
    expect(row.syncStatus, syncStatusWire(SyncStatus.pending));
  });

  test('업로드된(synced) 기록은 서버를 거치고, 실패하면 로컬을 바꾸지 않는다',
      () async {
    await insert(run(SyncStatus.synced));

    await expectLater(
      repository.updateMeta('run-1', title: '한강 러닝', note: '좋았음'),
      throwsA(isA<Failure>()), // 도달 불가 주소를 쳤다는 증거
    );

    // 서버 확정 전에 로컬만 앞서가면 영구 divergence가 된다.
    final summary = await summaryOf('run-1');
    expect(summary['title'], isNull);
    expect(summary['note'], isNull);
  });
}
