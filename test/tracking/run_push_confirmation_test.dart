import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/tracking/data/local_run_database.dart';
import 'package:runnit/features/tracking/data/local_run_repository.dart';
import 'package:runnit/features/gamification/domain/achievement_moment.dart';
import 'package:runnit/models/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 업로드 응답 채택(`LocalRunRepository.applyServerConfirmation`)의 회귀 테스트.
///
/// 배경: `_push()`가 `.upsert(payload)`만 하던 시절에는 서버가 확정한
/// `runs.is_flagged`를 읽어올 경로가 없어 `RunRecord.isFlagged`가 영원히
/// `null`이었고, 그러면 공유 카드 게이트(`achievementGate`)가 `pending`에서
/// 멈춘다(PRD §8.4, `_workspace/20260826_050000_architect_sharing-cards.md` §4.2.1).
///
/// 여기서 검증하는 계약은 방향이 다른 두 가지다:
/// - **보낼 때**: 서버 소유 컬럼을 payload에서 뺀다.
/// - **받을 때**: 서버 소유 컬럼만 로컬에 덮어쓰고, 사용자 소유 필드와
///   samples는 건드리지 않는다.
void main() {
  late LocalRunDatabase db;
  late LocalRunRepository repository;

  setUp(() {
    db = LocalRunDatabase.forTesting(NativeDatabase.memory());
    // 이 테스트는 네트워크를 타지 않는다 — `applyServerConfirmation`은 서버 응답을
    // 이미 받은 뒤의 로컬 반영 단계라 클라이언트를 건드리지 않는다.
    repository = LocalRunRepository(
      db,
      SupabaseClient('http://localhost:54321', 'test-anon-key'),
    );
  });

  tearDown(() async {
    await db.close();
  });

  RunRecord seed({String id = 'run-1'}) => RunRecord(
        id: id,
        userId: 'user-1',
        startedAt: DateTime.utc(2026, 8, 26, 6),
        endedAt: DateTime.utc(2026, 8, 26, 6, 30),
        activityType: ActivityType.outdoorRun,
        status: RunStatus.completed,
        distanceMeters: 5000,
        elapsedSeconds: 1800,
        movingSeconds: 1750,
        // 클라이언트 낙관적 계산값. 서버가 되돌려 준 값으로 교체돼야 한다.
        avgPaceSecPerKm: 350,
        title: '퇴근 러닝',
        syncStatus: SyncStatus.pending,
        samples: <RunSample>[
          RunSample(
            timestamp: DateTime.utc(2026, 8, 26, 6, 0, 1),
            latitude: 37.5,
            longitude: 127.0,
            source: RunSampleSource.phone,
          ),
        ],
      );

  Future<void> insert(RunRecord record) =>
      db.into(db.runRecordRows).insertOnConflictUpdate(record.toRow());

  /// 서버(`trg_runs_guard`)가 돌려주는 형태 — PostgREST가 내려주는 원시 JSON.
  Map<String, dynamic> serverRow({
    required bool isFlagged,
    String? flagReason,
  }) =>
      <String, dynamic>{
        'id': 'run-1',
        'avg_pace_sec_per_km': 350.0,
        'awarded_xp': isFlagged ? 0 : 50,
        'is_flagged': isFlagged,
        'flag_reason': flagReason,
        'created_at': '2026-08-26T06:30:05.000Z',
        'updated_at': '2026-08-26T06:30:05.000Z',
      };

  test('서버가 is_flagged=true를 돌려주면 로컬 RunRecord에 반영된다', () async {
    await insert(seed());

    await repository.applyServerConfirmation(
      'run-1',
      serverRow(isFlagged: true, flagReason: 'speed_out_of_range'),
    );

    final stored = await repository.findById('run-1');
    expect(stored!.isFlagged, isTrue);
    expect(stored.flagReason, 'speed_out_of_range');
    expect(stored.syncStatus, SyncStatus.synced);
    // 이 기록은 축하도 공유도 하면 안 된다.
    expect(
      achievementGate(runSynced: true, runFlagged: stored.isFlagged),
      AchievementGate.flagged,
    );
  });

  test('is_flagged=false는 null과 구별되어 저장된다 — 게이트가 confirmed로 승격', () async {
    await insert(seed());

    // 반영 전에는 "아직 모른다"(null)여야 한다.
    final before = await repository.findById('run-1');
    expect(before!.isFlagged, isNull);
    expect(
      achievementGate(runSynced: true, runFlagged: before.isFlagged),
      AchievementGate.pending,
    );

    await repository.applyServerConfirmation(
      'run-1',
      serverRow(isFlagged: false),
    );

    final after = await repository.findById('run-1');
    expect(after!.isFlagged, isFalse);
    expect(after.flagReason, isNull);
    expect(
      achievementGate(runSynced: true, runFlagged: after.isFlagged),
      AchievementGate.confirmed,
    );
  });

  test('서버 소유 컬럼(awarded_xp/createdAt)도 함께 채택된다', () async {
    await insert(seed());

    await repository.applyServerConfirmation(
      'run-1',
      serverRow(isFlagged: false),
    );

    final stored = await repository.findById('run-1');
    expect(stored!.awardedXp, 50);
    expect(stored.createdAt, DateTime.utc(2026, 8, 26, 6, 30, 5));
    expect(stored.updatedAt, DateTime.utc(2026, 8, 26, 6, 30, 5));
  });

  test('사용자 소유 필드와 samples는 응답 반영으로 사라지지 않는다', () async {
    await insert(seed());
    // 업로드가 도는 동안 사용자가 제목을 고친 상황.
    await insert(seed().copyWith(title: '한강 야간 러닝'));

    await repository.applyServerConfirmation(
      'run-1',
      serverRow(isFlagged: false),
    );

    final stored = await repository.findById('run-1', includeSamples: true);
    expect(stored!.title, '한강 야간 러닝');
    expect(stored.samples, hasLength(1));
    expect(stored.distanceMeters, 5000);
  });

  test('업로드 도중 삭제된 기록은 응답으로 되살아나지 않는다', () async {
    await repository.applyServerConfirmation(
      'run-1',
      serverRow(isFlagged: false),
    );

    final row = await (db.select(db.runRecordRows)
          ..where((t) => t.id.equals('run-1')))
        .getSingleOrNull();
    expect(row, isNull);
  });

  test('응답에 없는 키는 로컬 값을 지우지 않는다', () async {
    await insert(seed());

    // 서버가 일부 컬럼만 돌려준 경우(방어). avg_pace는 그대로 남아야 한다.
    await repository.applyServerConfirmation('run-1', <String, dynamic>{
      'id': 'run-1',
      'is_flagged': false,
    });

    final stored = await repository.findById('run-1');
    expect(stored!.avgPaceSecPerKm, 350);
    expect(stored.isFlagged, isFalse);
  });

  test('채택한 판정은 로컬 summaryJson에 남아 앱 재시작 후에도 읽힌다', () async {
    await insert(seed());
    await repository.applyServerConfirmation(
      'run-1',
      serverRow(isFlagged: true, flagReason: 'pace_out_of_range'),
    );

    // 재시작 시뮬레이션 — 메모리 캐시 없이 행에서 직접 되살린다.
    final row = await (db.select(db.runRecordRows)
          ..where((t) => t.id.equals('run-1')))
        .getSingle();
    final summary = jsonDecode(row.summaryJson) as Map<String, dynamic>;
    expect(summary['is_flagged'], isTrue);
    expect(summary['flag_reason'], 'pace_out_of_range');
    expect(runRecordFromRow(row).isFlagged, isTrue);
  });
}
