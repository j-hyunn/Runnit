import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/api/supabase_error.dart';
import '../../../core/error/failure.dart';
import '../../../core/repositories/run_repository.dart';
import '../../../models/models.dart';
import 'local_run_database.dart';

/// [RunRepository]의 **오프라인 우선** 구현.
///
/// ## 저장 순서 (이 순서가 계약이다)
/// `save()` → ① 로컬 SQLite에 먼저 쓴다 ② 완료 기록이면 서버 업로드를 시도한다
/// ③ 실패하면 로컬에 `SyncStatus.pending`으로 남고 `syncPending()` 재시도로 올라간다.
/// 네트워크를 먼저 치면 지하 주차장에서 끝낸 러닝이 통째로 사라진다.
///
/// ## 왜 업로드가 멱등한가
/// `RunRecord.id`가 클라이언트 생성 UUID v4이고 서버 `runs.id`의 PK와 같은
/// 값이라, 재시도가 중복 행을 만들지 않는다(계약서 §2.2 `id` = W:C).
/// 그래서 `upsert`를 쓴다.
///
/// ## 서버가 덮어쓰는 값은 보내지 않는다 — 대신 **되받는다**
/// `avg_pace_sec_per_km`(항상 재계산), `awarded_xp`(서버 산정),
/// `is_flagged`/`flag_reason`(서버 재검증), `created_at`/`updated_at`(트리거)은
/// payload에서 제거한다. `runs_guard` 트리거가 어차피 되돌리지만, 애초에
/// 싣지 않는 편이 의도가 분명하다
/// (`supabase_user_repository.dart`의 `_editablePatch`와 같은 방침).
/// 클라이언트가 계산한 페이스는 **낙관적 표시용**일 뿐이다.
///
/// 그 대신 업로드 응답(`.select(...).single()`)으로 서버가 확정한 같은 컬럼들을
/// 되받아 로컬에 기록한다. 방향이 반대일 뿐 컬럼 집합은 [_serverOwnedKeys] 하나로
/// 같다 — 보낼 때 빼는 것과 받을 때 채우는 것이 어긋나면 `isFlagged`가 영원히
/// `null`로 남아 공유 카드 게이트가 `pending`에서 멈춘다
/// (`gamification/domain/achievement_moment.dart`).
class LocalRunRepository implements RunRepository {
  LocalRunRepository(this._db, this._client);

  final LocalRunDatabase _db;
  final SupabaseClient _client;

  static const String _table = 'runs';

  /// 서버가 소유하는 컬럼. 업로드 payload에서 **제거**하고, 업로드 응답에서
  /// **채택**한다.
  ///
  /// ⚠️ 두 방향을 혼동하지 말 것:
  /// - 보낼 때(`_remotePayload`): 뺀다. 서버가 확정할 값을 클라이언트가 주장하지 않는다.
  /// - 받을 때(`applyServerConfirmation`): 이 키들만 로컬에 덮어쓴다.
  ///
  /// 로컬 저장(`toRow()`의 `summaryJson`)에는 그대로 남아야 한다 — 서버가 확정해 준
  /// 값을 앱 재시작 후에도 알아야 공유/축하 게이트가 동작한다.
  static const Set<String> _serverOwnedKeys = <String>{
    'avg_pace_sec_per_km',
    'awarded_xp',
    'created_at',
    'updated_at',
    // 서버 재검증 결과(PRD §8.4). 클라이언트가 보내면 서버 가드가 되돌리지만,
    // 애초에 보내지 않는 것이 의도를 코드로 남기는 방법이다.
    'is_flagged',
    'flag_reason',
  };

  /// 업로드 응답으로 되받을 컬럼(PostgREST `select=` 인자).
  ///
  /// `.select()`를 인자 없이 쓰면 `samples`까지 통째로 돌아온다 — 1시간 러닝이면
  /// 3600 샘플을 방금 올린 그대로 다시 내려받는 셈이다. 우리가 채택할 컬럼은
  /// [_serverOwnedKeys]뿐이므로 PK와 함께 그것만 요청한다.
  static final String _confirmationColumns =
      <String>['id', ..._serverOwnedKeys].join(',');

  // ─────────────────────────── 쓰기 ───────────────────────────

  @override
  Future<void> save(RunRecord record) async {
    // 진행 중(recording/paused) 체크포인트는 아직 서버로 보낼 대상이 아니다 —
    // 서버 `validate_run`이 미완결 기록을 평가하게 만들 이유가 없다.
    final isFinal = record.status == RunStatus.completed;
    final localStatus = isFinal ? SyncStatus.pending : SyncStatus.local;

    await _writeLocal(record.copyWith(syncStatus: localStatus));
    if (!isFinal) return;

    // 업로드 실패는 `save()`의 실패가 아니다 — 이미 로컬에 안전하게 남았다.
    await _push(record);
  }

  Future<void> _writeLocal(RunRecord record) async {
    try {
      await _db
          .into(_db.runRecordRows)
          .insertOnConflictUpdate(record.toRow());
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        Failure.storage(message: error.toString()),
        stackTrace,
      );
    }
  }

  /// 단건 업로드. 성공하면 true, 실패하면 로컬 상태를 `failed`로 내리고 false.
  ///
  /// ## 왜 `.select().single()`까지 하는가
  /// `is_flagged`·`awarded_xp`·`avg_pace_sec_per_km`은 `trg_runs_guard`가
  /// **BEFORE 트리거에서 동기적으로** 확정한다(마이그레이션 39-6). 즉 이 응답에는
  /// 이미 판정 결과가 들어 있다 — 별도 재조회도, realtime 구독도 필요 없다.
  /// 응답을 안 받으면 `RunRecord.isFlagged`가 영원히 `null`이고, 그러면 요약
  /// 화면의 `achievementGate(runFlagged: null)`가 `pending`에서 멈춘다.
  ///
  /// ## 에러 처리 의미의 변화
  /// `single()`은 행이 정확히 1개가 아니면 던진다. 우리 경우 0행은 사실상
  /// RLS(`runs_select_own`) 거부뿐이고, PK가 `id`라 2행은 나올 수 없다.
  /// 새로 생긴 실패 지점 — 응답 파싱/로컬 반영 실패 — 이 오프라인 큐를 망가뜨리지
  /// 않는 이유는 **업로드가 멱등**이기 때문이다: 서버에는 이미 들어갔더라도
  /// 로컬이 `failed`로 남아 `syncPending()`이 같은 `id`로 다시 upsert하고,
  /// 그때 응답을 다시 받아 반영한다. 중복 행도, 잃어버린 판정도 없다.
  Future<bool> _push(RunRecord record) async {
    try {
      final confirmed = await _client
          .from(_table)
          .upsert(_remotePayload(record))
          .select(_confirmationColumns)
          .single();
      await applyServerConfirmation(record.id, confirmed);
      return true;
    } catch (_) {
      await _markSyncStatus(record.id, SyncStatus.failed);
      return false;
    }
  }

  static Map<String, dynamic> _remotePayload(RunRecord record) {
    final json = record.toJson();
    for (final key in _serverOwnedKeys) {
      json.remove(key);
    }
    return json;
  }

  /// 업로드 응답의 [_serverOwnedKeys]만 로컬 행에 덮어쓰고 `synced`로 올린다.
  ///
  /// 메모리에 있던 [RunRecord]를 통째로 다시 쓰지 않고 **DB의 현재 `summaryJson`을
  /// 읽어 그 위에 겹치는** 이유는 두 가지다.
  /// 1. 업로드가 도는 동안 사용자가 제목/메모를 고쳤을 수 있다. 통째로 쓰면 그
  ///    수정이 조용히 되돌아간다.
  /// 2. `samplesJson` 컬럼을 아예 건드리지 않아, 3600 샘플을 재직렬화하지 않는다.
  ///
  /// 행이 사라졌으면(업로드 중 `delete()`) 아무것도 하지 않는다 — 되살리지 않는다.
  @visibleForTesting
  Future<void> applyServerConfirmation(
    String id,
    Map<String, dynamic> confirmed,
  ) async {
    await _db.transaction(() async {
      final row = await (_db.select(_db.runRecordRows)
            ..where((t) => t.id.equals(id))
            ..limit(1))
          .getSingleOrNull();
      if (row == null) return;

      final summary = jsonDecode(row.summaryJson) as Map<String, dynamic>;
      for (final key in _serverOwnedKeys) {
        if (confirmed.containsKey(key)) summary[key] = confirmed[key];
      }

      await (_db.update(_db.runRecordRows)..where((t) => t.id.equals(id))).write(
        RunRecordRowsCompanion(
          syncStatus: Value(syncStatusWire(SyncStatus.synced)),
          summaryJson: Value(jsonEncode(summary)),
          updatedAtLocal: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  Future<void> _markSyncStatus(String id, SyncStatus status) async {
    await (_db.update(_db.runRecordRows)..where((t) => t.id.equals(id))).write(
      RunRecordRowsCompanion(syncStatus: Value(syncStatusWire(status))),
    );
  }

  @override
  Future<int> syncPending() async {
    final rows = await (_db.select(_db.runRecordRows)
          ..where(
            (t) =>
                t.status.equals(runStatusWire(RunStatus.completed)) &
                t.syncStatus.isNotValue(syncStatusWire(SyncStatus.synced)),
          )
          ..orderBy(<OrderClauseGenerator<RunRecordRows>>[
            (t) => OrderingTerm.asc(t.startedAt),
          ]))
        .get();

    var uploaded = 0;
    for (final row in rows) {
      final record = runRecordFromRow(row, includeSamples: true);
      if (await _push(record)) uploaded += 1;
    }
    return uploaded;
  }

  @override
  Future<void> delete(String id) async {
    await (_db.delete(_db.runRecordRows)..where((t) => t.id.equals(id))).go();
    // 서버에 없던 기록이면 0행 삭제로 조용히 끝난다. RLS가 남의 기록을 막는다.
    await guardSupabase(() => _client.from(_table).delete().eq('id', id));
  }

  // ─────────────────────────── 읽기 ───────────────────────────

  @override
  Future<RunRecord?> findById(String id, {bool includeSamples = false}) async {
    final row = await (_db.select(_db.runRecordRows)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
    if (row != null) {
      return runRecordFromRow(row, includeSamples: includeSamples);
    }

    // 로컬에 없다 = 다른 기기에서 뛴 기록. 원격을 한 번 본다.
    return guardSupabase(() async {
      final remote =
          await _client.from(_table).select().eq('id', id).maybeSingle();
      if (remote == null) return null;
      final record = _fromRemote(remote, includeSamples: includeSamples);
      // 다음 조회부터는 로컬에서 답하도록 캐시해 둔다.
      await _writeLocal(record.copyWith(syncStatus: SyncStatus.synced));
      return record;
    });
  }

  @override
  Future<List<RunRecord>> listByUser(
    String userId, {
    int limit = 20,
    DateTime? before,
  }) async {
    final query = _db.select(_db.runRecordRows)
      ..where((t) => t.userId.equals(userId))
      ..where((t) => t.status.equals(runStatusWire(RunStatus.completed)));
    if (before != null) {
      query.where((t) => t.startedAt.isSmallerThanValue(before.toUtc()));
    }
    query
      ..orderBy(<OrderClauseGenerator<RunRecordRows>>[
        (t) => OrderingTerm.desc(t.startedAt),
      ])
      ..limit(limit);

    final rows = await query.get();
    // 계약: 목록의 samples는 항상 비어 있다.
    return rows
        .map((row) => runRecordFromRow(row))
        .toList(growable: false);
  }

  @override
  Stream<List<RunRecord>> watchByUser(String userId, {int limit = 20}) {
    final query = _db.select(_db.runRecordRows)
      ..where((t) => t.userId.equals(userId))
      ..where((t) => t.status.equals(runStatusWire(RunStatus.completed)))
      ..orderBy(<OrderClauseGenerator<RunRecordRows>>[
        (t) => OrderingTerm.desc(t.startedAt),
      ])
      ..limit(limit);

    // drift의 watch()는 테이블 변경을 감지해 자동 재실행한다 —
    // 업로드 완료로 sync_status만 바뀌어도 UI가 갱신된다.
    return query.watch().map(
          (rows) =>
              rows.map((row) => runRecordFromRow(row)).toList(growable: false),
        );
  }

  /// 앱 재시작 시 복구할 미완결 세션. 제조사 배터리 정책이 프로세스를 죽여도
  /// 마지막 체크포인트까지는 남아 있다(skill: android-health-connect.md §함정).
  /// [RunRepository] 인터페이스 밖의 부가 기능이라 구현체에만 둔다.
  Future<RunRecord?> findInterrupted(String userId) async {
    final row = await (_db.select(_db.runRecordRows)
          ..where((t) => t.userId.equals(userId))
          ..where(
            (t) =>
                t.status.equals(runStatusWire(RunStatus.recording)) |
                t.status.equals(runStatusWire(RunStatus.paused)),
          )
          ..orderBy(<OrderClauseGenerator<RunRecordRows>>[
            (t) => OrderingTerm.desc(t.startedAt),
          ])
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : runRecordFromRow(row, includeSamples: true);
  }

  RunRecord _fromRemote(
    Map<String, dynamic> row, {
    required bool includeSamples,
  }) {
    final json = Map<String, dynamic>.of(row);
    if (!includeSamples) {
      json['samples'] = <dynamic>[];
    } else if (json['samples'] is String) {
      // PostgREST가 jsonb를 문자열로 돌려주는 드문 경우 방어.
      json['samples'] = jsonDecode(json['samples'] as String);
    }
    return RunRecord.fromJson(json);
  }
}
