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
/// `save()` → ① 로컬 SQLite에 먼저 쓴다(여기까지만 await한다) ② 완료 기록이면
/// 서버 업로드를 **백그라운드로** 띄운다 ③ 실패하면 로컬에 `SyncStatus.failed`로
/// 남고 `syncPending()` 재시도로 올라간다.
/// 네트워크를 먼저 치면 지하 주차장에서 끝낸 러닝이 통째로 사라진다.
///
/// ②를 await하지 않는 이유는 UI다 — `save()`를 기다리는 호출부가 러닝 종료
/// 흐름(`TrackingController.stop()` → 요약 화면)이라, 업로드까지 기다리면 요약
/// 화면이 서버 응답에 묶인다(QA C-4). 업로드 실패는 어차피 `save()`의 실패가
/// 아니므로 기다릴 이유도 없다. 테스트는 [uploadSettled]로 그 백그라운드 작업을
/// 관측한다.
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
  LocalRunRepository(
    this._db,
    this._client, {
    this.uploadTimeout = const Duration(seconds: 30),
  });

  final LocalRunDatabase _db;
  final SupabaseClient _client;

  /// 업로드 요청 하나의 상한.
  ///
  /// 스탈된 TCP 연결("연결은 됐는데 응답이 없는" 구간 — 캡티브 포털, 지하철 셀
  /// 전환)에서 요청이 영원히 반환되지 않으면 [syncPending]이 끝나지 않고,
  /// `RunSyncCoordinator`의 재진입 래치가 걸린 채로 앱 수명 내내 큐가 멈춘다
  /// (QA C-3). 비행기 모드처럼 즉시 실패하는 경우는 해당 없다.
  ///
  /// ⚠️ `.timeout()`은 이미 나간 HTTP 요청을 **취소하지 못한다**(소켓은 SDK가
  /// 쥐고 있다). 끊기는 것은 우리 쪽 대기뿐이며, 그것으로 충분하다 — 업로드가
  /// 멱등이라 서버에 늦게 도착한 요청이 성공했더라도 재시도가 중복 행을 만들지
  /// 않는다.
  ///
  /// 30초: 1시간 러닝의 3,600 샘플(압축 전 0.5~1MB)을 저대역에서 올리는 시간을
  /// 감안한 값. 테스트에서만 줄인다.
  final Duration uploadTimeout;

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
    // 그래서 기다리지 않는다(QA C-4): 요약 화면은 로컬 데이터로 즉시 뜨고,
    // 실패는 `failed`로 남아 코디네이터의 다음 신호에서 재시도된다.
    _schedulePush(record);
  }

  /// 진행 중인 백그라운드 업로드의 꼬리. `save()`가 더 이상 업로드를 await하지
  /// 않으므로, 업로드 결과를 관측해야 하는 테스트가 이걸 기다린다.
  ///
  /// 체인으로 이어 붙여 **업로드끼리 겹치지 않게** 직렬화한다 — 같은 기기에서
  /// 연달아 저장된 기록이 동시에 3,600 샘플씩 밀어 올리는 상황을 피한다.
  Future<void> _uploads = Future<void>.value();

  @visibleForTesting
  Future<void> get uploadSettled => _uploads;

  void _schedulePush(RunRecord record) {
    // 이 체인은 아무도 await하지 않으므로 예외를 여기서 삼킨다. `_push()`가 이미
    // 모든 업로드 실패를 `failed`로 흡수하고, 그 뒤에도 던질 수 있는 것은 로컬
    // DB가 닫힌 경우뿐이다(앱 종료) — 그때는 다음 실행의 `syncPending()`이 큐를
    // 다시 집어 든다.
    _uploads = _uploads
        .then((_) => _push(record))
        .then((_) {}, onError: (Object _) {});
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
  /// ## 타임아웃
  /// [uploadTimeout]을 넘기면 `TimeoutException`이 나고, 다른 실패와 똑같이
  /// `failed`로 내려 다음 신호에서 재시도된다 — 멈춘 연결 하나가 큐 전체를
  /// 정지시키지 않게 하는 유일한 장치다(QA C-3).
  Future<bool> _push(RunRecord record) async {
    try {
      final confirmed = await _upsertRemote(record).timeout(uploadTimeout);
      await applyServerConfirmation(record.id, confirmed);
      return true;
    } catch (_) {
      await _markSyncStatus(record.id, SyncStatus.failed);
      return false;
    }
  }

  /// PostgREST 왕복만 떼어 둔다. 빌더는 `Future`를 *구현*할 뿐이라 `.timeout()`을
  /// 빌더에 바로 걸기보다, async 함수로 감싸 진짜 `Future`로 만든 뒤 거는 것이
  /// 안전하다.
  Future<Map<String, dynamic>> _upsertRemote(RunRecord record) async {
    return _client
        .from(_table)
        .upsert(_remotePayload(record))
        .select(_confirmationColumns)
        .single();
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

  /// [userId]를 주면 그 사용자의 행만 올린다 — 계약은 [RunRepository.syncPending]
  /// 참조. 한 기기에서 계정을 바꿨을 때 이전 계정의 행을 현재 세션 JWT로 밀어
  /// 올려 RLS 42501을 무한 반복하는 것을 막는다(QA C-5). 이전 계정 행은 **지우지
  /// 않는다** — 그 계정으로 다시 로그인하면 그대로 올라간다.
  @override
  Future<int> syncPending({String? userId}) async {
    final query = _db.select(_db.runRecordRows)
      ..where(
        (t) =>
            t.status.equals(runStatusWire(RunStatus.completed)) &
            t.syncStatus.isNotValue(syncStatusWire(SyncStatus.synced)),
      );
    if (userId != null) {
      query.where((t) => t.userId.equals(userId));
    }
    query.orderBy(<OrderClauseGenerator<RunRecordRows>>[
      (t) => OrderingTerm.asc(t.startedAt),
    ]);
    final rows = await query.get();

    var uploaded = 0;
    for (final row in rows) {
      final record = runRecordFromRow(row, includeSamples: true);
      if (await _push(record)) uploaded += 1;
    }
    return uploaded;
  }

  /// 제목·메모 편집 (PRD HI-07 / TRD §4.4).
  ///
  /// ## 왜 upsert가 아니라 부분 `update`인가
  /// `_push()`의 전체 행 upsert를 재사용하면 제목 한 줄 고치는 데 3,600 샘플을
  /// 다시 올린다. 서버 가드가 어차피 `title`/`note` 외 전부를 되돌리므로 나머지
  /// 필드를 싣는 것은 순수한 낭비다.
  ///
  /// ## 서버 응답이 곧 확정값
  /// 정규화(`btrim` → 절단 → 빈 문자열은 `null`)를 BEFORE 트리거가 같은
  /// 트랜잭션에서 수행하므로 `.select().single()` 응답이 최종값이다 — 재조회가
  /// 필요 없다(`applyServerConfirmation`과 같은 구조).
  ///
  /// ## 아직 서버에 없는 기록(오프라인 저장분)은 네트워크를 아예 타지 않는다
  /// 분기 근거는 서버 응답이 아니라 **로컬 `sync_status`**다. `synced`가 아닌 행은
  /// 서버에 존재한 적이 없으므로(`save()`가 완료 기록만 올리고, 실패하면
  /// `pending`/`failed`로 남는다) 로컬 편집만으로 완전히 옳다 —
  /// [RunMeta.normalized]가 서버 가드와 같은 규칙을 적용하고, 이후
  /// `syncPending()`이 `_remotePayload`에 담아 title/note까지 함께 올린다.
  ///
  /// 지하 주차장에서 러닝을 끝낸 직후가 정확히 이 국면이다(업로드 실패 → 상세에서
  /// 메모 작성). 여기서 서버를 먼저 치면 오프라인 우선 아키텍처가 겨냥한 바로 그
  /// 상황에서 편집이 막힌다 (QA C-1).
  ///
  /// ## 응답 0행은 로컬 전용 편집이 **아니라** 에러다
  /// `synced`인데 `update ... eq(id)`가 0행이면 서버에 행이 없거나 RLS가 매칭에
  /// 실패한 이상 상태다. 이때 로컬만 고치면 `sync_status`가 `synced`라
  /// `syncPending()`이 재전송하지 않아 **영구 divergence**가 생기는데 사용자에겐
  /// 성공으로 보인다. 그래서 표면화한다 (QA C-2).
  @override
  Future<RunMeta> updateMeta(
    String id, {
    String? title,
    String? note,
  }) async {
    final row = await _rowOf(id);
    // 로컬 행이 없으면(다른 기기 기록을 원격에서만 본 경우) 서버 경로로 간다.
    final uploaded =
        row == null || syncStatusFromWire(row.syncStatus) == SyncStatus.synced;

    if (!uploaded) {
      final meta = RunMeta.normalized(title: title, note: note);
      await _applyMeta(id, meta);
      return meta;
    }

    final confirmed = await guardSupabase(
      () => _client
          .from(_table)
          .update(<String, dynamic>{'title': title, 'note': note})
          .eq('id', id)
          .select(_metaColumns)
          .maybeSingle(),
    );
    if (confirmed == null) {
      throw const Failure.network(
        message: '수정할 기록을 서버에서 찾지 못했습니다.',
      );
    }

    final meta = RunMeta.fromServer(confirmed);
    await _applyMeta(id, meta);
    return meta;
  }

  Future<RunRecordRow?> _rowOf(String id) => (_db.select(_db.runRecordRows)
        ..where((t) => t.id.equals(id))
        ..limit(1))
      .getSingleOrNull();

  /// 편집 응답으로 되받을 컬럼. `samples`가 딸려 오지 않도록 명시한다.
  static const String _metaColumns = 'id,title,note,updated_at';

  /// 확정된 [RunMeta]를 로컬 `summaryJson`에 겹쳐 쓴다.
  ///
  /// [applyServerConfirmation]과 같은 이유로 행 전체를 다시 쓰지 않는다 —
  /// `samplesJson`을 건드리지 않고, 동시에 진행 중인 업로드가 확정한
  /// `awarded_xp`/`is_flagged`를 되돌리지 않기 위해서다.
  ///
  /// `sync_status`는 **바꾸지 않는다.** 서버 편집이 성공했더라도 그 기록이
  /// `pending`(본문 업로드 미완)이면 여전히 pending이어야 하고, 반대로 이미
  /// `synced`인 기록을 편집했다고 pending으로 내리면 `syncPending()`이 3,600
  /// 샘플을 통째로 다시 올린다.
  Future<void> _applyMeta(String id, RunMeta meta) async {
    await _db.transaction(() async {
      final row = await _rowOf(id);
      if (row == null) return;

      final summary = jsonDecode(row.summaryJson) as Map<String, dynamic>;
      summary['title'] = meta.title;
      summary['note'] = meta.note;
      if (meta.updatedAt != null) {
        summary['updated_at'] = meta.updatedAt!.toIso8601String();
      }

      await (_db.update(_db.runRecordRows)..where((t) => t.id.equals(id))).write(
        RunRecordRowsCompanion(
          summaryJson: Value(jsonEncode(summary)),
          updatedAtLocal: Value(DateTime.now().toUtc()),
        ),
      );
    });
  }

  /// 미완결 세션 폐기 전용 — 계약은 [RunRepository.delete] 참조.
  ///
  /// 서버 DELETE를 **부르지 않는다.** 여기 오는 행은 `recording`/`paused`
  /// 체크포인트라 애초에 업로드된 적이 없고(`save()`가 완료 기록만 올린다),
  /// 마이그레이션 51-3이 `runs_delete_own` 정책을 내려 서버 삭제 경로 자체가
  /// 사라졌다(PRD v1.6 — 사용자는 러닝을 삭제할 수 없다). 남겨 두면 폐기할 때마다
  /// 0행짜리 왕복 요청만 나간다.
  @override
  Future<void> delete(String id) async {
    await (_db.delete(_db.runRecordRows)..where((t) => t.id.equals(id))).go();
  }

  // ─────────────────────────── 읽기 ───────────────────────────

  @override
  Future<RunRecord?> findById(String id, {bool includeSamples = false}) async {
    final row = await (_db.select(_db.runRecordRows)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();

    if (row != null) {
      final local = runRecordFromRow(row, includeSamples: includeSamples);
      // 로컬 행에 samples가 없는데 상세용으로 요청됐고, 경로가 있었던
      // 기록이면(routePolyline 존재 = 야외 러닝) 이 행은 samples 없이 캐시된
      // 불완전한 행이다. 로컬 히트로 끝내면 빈 경로/랩이 그대로 나가므로
      // (그리고 재조회로도 복구 불가) 원격에서 온전한 행을 다시 가져온다.
      final incomplete = includeSamples &&
          local.samples.isEmpty &&
          (local.routePolyline?.isNotEmpty ?? false);
      if (!incomplete) return local;
    }

    // 로컬에 없거나(다른 기기 기록) samples가 유실됐다. 원격을 본다.
    return guardSupabase(() async {
      final remote =
          await _client.from(_table).select().eq('id', id).maybeSingle();
      if (remote == null) {
        // 원격에도 없으면: 로컬에 있던 (불완전할 수 있는) 행이라도 돌려준다.
        return row == null
            ? null
            : runRecordFromRow(row, includeSamples: includeSamples);
      }
      final record = _fromRemote(remote, includeSamples: includeSamples);
      // ⚠️ samples 없이 가져온 결과는 로컬에 캐시하지 않는다. 캐시하면 이후
      // findById(includeSamples: true) 조회가 이 빈 행에 막혀 상세/공유 카드가
      // 조용히 깨진다(QA I-2). samples를 실제로 받아온 경우에만 캐시한다.
      //
      // `syncStatus`는 여기서 다시 세우지 않는다 — [_fromRemote]가 단일 진원지다.
      if (includeSamples) {
        await _writeLocal(record);
      }
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
    // `sync_status`는 기기 로컬 컬럼이라 서버 응답에 없고, 모델 기본값은
    // `local`이다 — 그대로 두면 **방금 서버에서 읽어온 기록**이 "동기화 대기"로
    // 보인다(상세 화면 배너·목록 칩이 이 값을 읽는다). 원격에 행이 있다는 것이
    // 곧 업로드 완료이므로 여기서 확정한다.
    return RunRecord.fromJson(json).copyWith(syncStatus: SyncStatus.synced);
  }
}
