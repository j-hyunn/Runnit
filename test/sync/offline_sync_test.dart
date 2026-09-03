import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/tracking/data/local_run_database.dart';
import 'package:runnit/features/tracking/data/local_run_repository.dart';
import 'package:runnit/models/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// TR-08 "오프라인 기록 → 복귀 시 자동 동기화" E2E 회귀 (수용 기준: 100% 업로드,
/// 손실률 0.1% 미만).
///
/// 기존 `run_push_confirmation_test.dart`는 **서버 응답을 이미 받은 뒤**의
/// 로컬 반영(`applyServerConfirmation`)만 검증한다. 여기서는 그 앞 단계 —
/// `save()` → `_push()` → `syncPending()`이 **실제 HTTP를 타는 경로** — 를
/// 가짜 PostgREST 서버로 세운다. 페이로드 경계(스키마 정합·서버 소유 컬럼 제거),
/// 멱등성(같은 `id` 재 upsert), 부분 실패 격리, 앱 재기동 큐 복구가 여기서만
/// 관찰된다.
void main() {
  late _FakePostgrest server;
  late LocalRunDatabase db;
  late LocalRunRepository repository;

  setUp(() async {
    server = await _FakePostgrest.start();
    db = LocalRunDatabase.forTesting(NativeDatabase.memory());
    repository = LocalRunRepository(
      db,
      SupabaseClient(server.url, 'test-anon-key'),
    );
  });

  tearDown(() async {
    await db.close();
    await server.stop();
  });

  RunRecord run({
    String id = 'run-1',
    String userId = 'user-1',
    RunStatus status = RunStatus.completed,
    int startHour = 6,
    int sampleCount = 3,
  }) =>
      RunRecord(
        id: id,
        userId: userId,
        startedAt: DateTime.utc(2026, 9, 1, startHour),
        endedAt: DateTime.utc(2026, 9, 1, startHour, 30),
        activityType: ActivityType.outdoorRun,
        status: status,
        distanceMeters: 5000,
        elapsedSeconds: 1800,
        movingSeconds: 1750,
        // 클라이언트 낙관적 계산값 — 페이로드에서 빠져야 한다.
        avgPaceSecPerKm: 350,
        routePolyline: 'abc_def',
        title: '퇴근 러닝',
        sources: const <RunSampleSource>[RunSampleSource.phone],
        deviceVendors: const <DeviceVendor>[DeviceVendor.phone],
        samples: List<RunSample>.generate(
          sampleCount,
          (int i) => RunSample(
            timestamp: DateTime.utc(2026, 9, 1, startHour, 0, i),
            latitude: 37.5 + i * 0.0001,
            longitude: 127.0,
            source: RunSampleSource.phone,
            cumulativeDistanceMeters: i * 3.0,
          ),
        ),
      );

  /// `save()`는 로컬 저장까지만 await하고 업로드는 백그라운드로 넘긴다(QA C-4).
  /// 업로드 결과를 관찰하는 테스트는 그 백그라운드 작업이 끝날 때까지 기다려야
  /// 한다 — 실제 앱에서 이 자리를 대신하는 것은 `RunSyncCoordinator`의 재시도다.
  Future<void> saveAndSettle(RunRecord record) async {
    await repository.save(record);
    await repository.uploadSettled;
  }

  Future<SyncStatus?> statusOf(String id) async {
    final row = await (db.select(db.runRecordRows)
          ..where((RunRecordRows t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : syncStatusFromWire(row.syncStatus);
  }

  // ───────────────── 1) 오프라인 저장 → 온라인 전환 → 큐 비움 ─────────────────

  test('오프라인에서 끝낸 러닝은 로컬에 남고 복귀 후 syncPending()이 올린다', () async {
    server.offline = true;

    // 러닝 종료. 업로드가 실패해도 save()는 던지지 않는다(로컬 우선 계약).
    await saveAndSettle(run());

    expect(await statusOf('run-1'), isNot(SyncStatus.synced),
        reason: '업로드 실패 기록은 재시도 대상으로 남아야 한다');
    expect(server.rows, isEmpty, reason: '오프라인이므로 서버에 아무것도 없다');
    // 기록 자체는 온전히 살아 있어야 한다(손실 0건).
    final offlineRecord = await repository.findById('run-1', includeSamples: true);
    expect(offlineRecord!.distanceMeters, 5000);
    expect(offlineRecord.samples, hasLength(3));

    // 네트워크 복귀.
    server.offline = false;
    expect(await repository.syncPending(), 1);

    expect(server.rows.keys, <String>['run-1']);
    expect(await statusOf('run-1'), SyncStatus.synced);

    // 큐가 비었다 — 다음 재시도는 요청조차 보내지 않는다.
    final before = server.requestCount;
    expect(await repository.syncPending(), 0);
    expect(server.requestCount, before);
  });

  test('업로드 성공 응답의 서버 확정값이 로컬에 반영된다', () async {
    await saveAndSettle(run());

    final stored = await repository.findById('run-1');
    expect(stored!.syncStatus, SyncStatus.synced);
    // 클라이언트가 보낸 350이 아니라 서버 재계산값이어야 한다.
    expect(stored.avgPaceSecPerKm, _FakePostgrest.serverPace);
    expect(stored.awardedXp, _FakePostgrest.serverXp);
    // null(아직 모름)이 아니라 false(서버가 정상 확정)로 구별돼야 공유 게이트가 열린다.
    expect(stored.isFlagged, isFalse);
  });

  // ───────────────────── 2) 실패 → 재시도 → 중복 없음 ─────────────────────

  test('업로드 중 실패 후 재시도해도 서버 행은 하나뿐이다 (클라 UUID 멱등)', () async {
    server.offline = true;
    await saveAndSettle(run());
    server.offline = false;

    expect(await repository.syncPending(), 1);
    // 이미 synced인데도 한 번 더 강제로 밀어 본다(코디네이터 중복 발화 상황).
    await saveAndSettle(run());

    expect(server.upsertedIds, <String>['run-1', 'run-1'],
        reason: '두 번 전송됐다');
    expect(server.rows, hasLength(1), reason: '같은 id라 서버 행은 하나');
    expect(await statusOf('run-1'), SyncStatus.synced);
  });

  test('응답 채택이 실패해도 큐가 망가지지 않고 재시도로 수렴한다', () async {
    // 서버는 200을 주지만 본문이 깨져 `.single()` 파싱이 실패하는 상황.
    server.corruptResponse = true;
    await saveAndSettle(run());
    expect(await statusOf('run-1'), SyncStatus.failed);
    expect(server.rows, hasLength(1), reason: '서버에는 이미 들어갔다');

    server.corruptResponse = false;
    expect(await repository.syncPending(), 1);
    expect(server.rows, hasLength(1), reason: '재시도가 중복 행을 만들지 않는다');
    expect(await statusOf('run-1'), SyncStatus.synced);
  });

  // ───────────────────────── 3) 부분 실패 격리 ─────────────────────────

  test('한 건이 실패해도 나머지는 올라가고, 실패건만 큐에 남는다', () async {
    server.offline = true;
    await saveAndSettle(run(id: 'run-a', startHour: 6));
    await saveAndSettle(run(id: 'run-b', startHour: 7));
    await saveAndSettle(run(id: 'run-c', startHour: 8));
    server.offline = false;

    // 가운데 건만 서버가 거부(예: CHECK 위반). 뒤 건이 막히면 안 된다.
    server.rejectIds.add('run-b');
    expect(await repository.syncPending(), 2);
    expect(server.rows.keys, containsAll(<String>['run-a', 'run-c']));
    expect(await statusOf('run-a'), SyncStatus.synced);
    expect(await statusOf('run-b'), SyncStatus.failed);
    expect(await statusOf('run-c'), SyncStatus.synced);

    server.rejectIds.clear();
    expect(await repository.syncPending(), 1);
    expect(await statusOf('run-b'), SyncStatus.synced);
    expect(server.rows, hasLength(3));
  });

  test('큐는 startedAt 오름차순 — 오래된 기록부터 올라간다', () async {
    server.offline = true;
    await saveAndSettle(run(id: 'late', startHour: 9));
    await saveAndSettle(run(id: 'early', startHour: 5));
    server.offline = false;

    await repository.syncPending();
    expect(server.upsertedIds, <String>['early', 'late']);
  });

  // ─────────────────── 4) 앱 강제종료 후 재기동 큐 복구 ───────────────────

  test('앱 강제종료 후 새 인스턴스가 미업로드 큐를 복구한다', () async {
    server.offline = true;
    await saveAndSettle(run(id: 'run-kill'));
    server.offline = false;

    // 프로세스 재기동 시뮬레이션 — 같은 DB 파일(여기선 같은 인메모리 executor)에
    // 새 리포지토리를 붙인다. 메모리 상태에 의존하지 않는지 본다.
    final revived = LocalRunRepository(
      db,
      SupabaseClient(server.url, 'test-anon-key'),
    );
    expect(await revived.syncPending(), 1);
    expect(await statusOf('run-kill'), SyncStatus.synced);
    // samples가 유실되지 않고 함께 올라갔다.
    expect((server.rows['run-kill']!['samples'] as List<dynamic>), hasLength(3));
  });

  test('미완결(recording) 체크포인트는 업로드 대상이 아니다', () async {
    await saveAndSettle(run(id: 'ckpt', status: RunStatus.recording));

    expect(server.requestCount, 0, reason: '진행 중 기록은 서버로 나가지 않는다');
    expect(await statusOf('ckpt'), SyncStatus.local);
    expect(await repository.syncPending(), 0);
    expect(server.requestCount, 0);
  });

  // ───────────── 5) 스탈된 연결 · 종료 흐름 비차단 · 계정 전환 ─────────────

  test('응답이 오지 않는 연결은 uploadTimeout에서 끊기고 큐가 계속 돈다', () async {
    // 타임아웃이 없으면 이 테스트는 영원히 끝나지 않는다 — 그게 C-3의 정체다.
    final stalled = LocalRunRepository(
      db,
      SupabaseClient(server.url, 'test-anon-key'),
      uploadTimeout: const Duration(milliseconds: 300),
    );
    server.hang = true;

    final stopwatch = Stopwatch()..start();
    await stalled.save(run(id: 'run-stall'));
    await stalled.uploadSettled;
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: '멈춘 연결은 uploadTimeout에서 끊겨야 한다');
    expect(await statusOf('run-stall'), SyncStatus.failed);

    // 큐가 정지하지 않았다 — 연결이 정상으로 돌아오면 그대로 올라간다.
    server.hang = false;
    expect(await stalled.syncPending(), 1);
    expect(await statusOf('run-stall'), SyncStatus.synced);
    expect(server.rows.keys, contains('run-stall'));
  });

  test('save()는 업로드 응답을 기다리지 않는다 (요약 화면 비차단)', () async {
    // 러닝 종료 → 요약 화면 전환이 서버 응답에 묶이면 안 된다(QA C-4).
    final nonBlocking = LocalRunRepository(
      db,
      SupabaseClient(server.url, 'test-anon-key'),
      uploadTimeout: const Duration(seconds: 1),
    );
    server.hang = true;

    final stopwatch = Stopwatch()..start();
    await nonBlocking.save(run(id: 'run-ui'));
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)),
        reason: 'save()는 로컬 저장까지만 기다린다');
    // 요약 화면이 읽을 로컬 데이터는 이미 온전하다.
    final stored = await nonBlocking.findById('run-ui', includeSamples: true);
    expect(stored!.distanceMeters, 5000);
    expect(stored.samples, hasLength(3));

    // 뒷정리 — 매달린 업로드를 타임아웃까지 흘려보낸다.
    await nonBlocking.uploadSettled;
  });

  test('syncPending(userId:)는 현재 계정 행만 올린다 (계정 전환)', () async {
    server.offline = true;
    await saveAndSettle(run(id: 'a-run', userId: 'user-a', startHour: 6));
    await saveAndSettle(run(id: 'b-run', userId: 'user-b', startHour: 7));
    server.offline = false;

    expect(await repository.syncPending(userId: 'user-b'), 1);
    expect(server.upsertedIds, <String>['b-run'],
        reason: '다른 계정 행을 보내면 RLS 42501로 영구 재시도가 된다');
    expect(await statusOf('a-run'), isNot(SyncStatus.synced));

    // 이전 계정 행은 **지우지 않는다** — 그 계정으로 다시 로그인하면 올라간다.
    expect(await repository.syncPending(userId: 'user-a'), 1);
    expect(await statusOf('a-run'), SyncStatus.synced);
  });

  // ───────── 6) 서버 확정 거리 되받기 (마이그레이션 64 / TRD §14 #27, QA F-4) ─────────

  test('서버가 재계산으로 깎은 거리가 로컬 기록에 반영된다', () async {
    // 64부터 서버는 샘플 재계산 거리를 **상시** 확정값으로 채택한다(밴드 없음).
    // 되받지 않으면 "앱은 5.0km인데 랭킹엔 4.6km"가 정상 기록에서도 생긴다.
    server
      ..recalculatedDistanceMeters = 4600
      ..recalculatedMovingSeconds = 1700;

    await saveAndSettle(run());

    final stored = await repository.findById('run-1');
    expect(stored!.distanceMeters, 4600, reason: '서버 확정 거리를 채택해야 한다');
    expect(stored.movingSeconds, 1700);
    expect(await statusOf('run-1'), SyncStatus.synced);

    // 올릴 때는 **클라이언트 주장값**이 실려야 한다 — 그게 서버 재계산의 입력이다.
    expect(server.lastPayload!['distance_meters'], 5000);

    // 원본 주장값은 client_reported로 함께 내려와 로컬에 남는다(상세 화면용 데이터).
    final summary = jsonDecode(
      (await db.select(db.runRecordRows).getSingle()).summaryJson,
    ) as Map<String, dynamic>;
    expect(
      (summary['client_reported'] as Map<String, dynamic>)['distance_meters'],
      5000,
    );
  });

  test('서버가 거리를 조정하지 않으면 클라이언트 값이 그대로 남는다', () async {
    // 응답에 distance_meters가 없는 경우(= 조정 없음)에도 로컬이 깨지지 않아야 한다.
    await saveAndSettle(run());

    final stored = await repository.findById('run-1');
    expect(stored!.distanceMeters, 5000);
    expect(stored.movingSeconds, 1750);
  });

  // ─────────── 7) 중복 업로드 인플라이트 가드 · 재시도 상한 (TRD §14 #29) ───────────

  /// 현재 [RunRecordRow.syncAttempts]. 상한 로직의 유일한 상태다.
  Future<int> attemptsOf(String id) async {
    final row = await (db.select(db.runRecordRows)
          ..where((RunRecordRows t) => t.id.equals(id)))
        .getSingle();
    return row.syncAttempts;
  }

  test('업로드가 진행 중인 기록은 syncPending()이 다시 올리지 않는다', () async {
    // `save()`의 백그라운드 업로드가 도는 **그 순간** 코디네이터 신호(연결 회복)가
    // 발화하는 상황이 §14 #29의 정체다. 서버 행은 클라 UUID upsert라 중복되지
    // 않지만, 같은 3,600 샘플이 두 번 나가고 두 응답이 같은 로컬 행에
    // `applyServerConfirmation`을 경쟁적으로 써 넣는다.
    final gate = Completer<void>();
    server.gate = gate;

    unawaited(repository.save(run(id: 'run-race')));

    // 업로드가 서버에 도달할 때까지(= 인플라이트가 될 때까지) 양보한다.
    for (var i = 0; i < 200 && server.requestCount == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(server.requestCount, 1, reason: '업로드가 시작되지 않았다');
    expect(repository.inFlightIds, contains('run-race'));

    // 여기가 경합 지점 — 가드가 없으면 두 번째 upsert가 나간다.
    expect(await repository.syncPending(), 0);
    expect(server.requestCount, 1, reason: '같은 행을 두 번 올렸다');

    server.gate = null;
    gate.complete();
    await repository.uploadSettled;

    expect(server.upsertedIds, <String>['run-race']);
    expect(await statusOf('run-race'), SyncStatus.synced);
    expect(repository.inFlightIds, isEmpty, reason: '끝난 뒤에는 비어야 한다');
  });

  test('재시도는 maxSyncAttempts에서 멈춘다 — 무한 재전송 차단 (L-2)', () async {
    // 서버가 구조적으로 거부하는 행. 상한이 없으면 코디네이터의 2분 주기마다
    // 1MB 페이로드가 앱 수명 내내 반복된다.
    server.rejectIds.add('run-doomed');
    await saveAndSettle(run(id: 'run-doomed')); // 시도 1회 소진

    for (var i = 1; i < LocalRunRepository.maxSyncAttempts; i++) {
      expect(await repository.syncPending(), 0);
    }
    expect(await attemptsOf('run-doomed'), LocalRunRepository.maxSyncAttempts);
    final exhausted = server.requestCount;
    expect(exhausted, LocalRunRepository.maxSyncAttempts);

    // 상한 도달 — 이제 요청 자체가 나가지 않는다.
    expect(await repository.syncPending(), 0);
    expect(server.requestCount, exhausted, reason: '상한 뒤에도 재전송이 계속됐다');

    // 기록은 **지워지지 않는다**. 수동 재시도로 되살아난다.
    expect(await statusOf('run-doomed'), SyncStatus.failed);
    expect(await repository.findById('run-doomed'), isNotNull);

    server.rejectIds.clear();
    await repository.resetSyncAttempts('run-doomed');
    expect(await repository.syncPending(), 1);
    expect(await statusOf('run-doomed'), SyncStatus.synced);
  });

  test('업로드에 성공하면 재시도 예산이 0으로 돌아온다', () async {
    // 오래 쓴 기기에서 산발적 실패가 누적돼 멀쩡한 기록이 상한에 걸리면 안 된다.
    server.offline = true;
    await saveAndSettle(run(id: 'run-flaky'));
    expect(await attemptsOf('run-flaky'), 1);

    server.offline = false;
    expect(await repository.syncPending(), 1);
    expect(await attemptsOf('run-flaky'), 0);
  });

  // ────────────────── 8) 페이로드 경계 (모델 ↔ runs 스키마) ──────────────────

  test('업로드 페이로드는 runs 컬럼 집합 안에 있고 전부 snake_case다', () async {
    await saveAndSettle(run());

    final payload = server.lastPayload!;
    expect(payload.keys, everyElement(matches(RegExp(r'^[a-z0-9_]+$'))),
        reason: 'camelCase 키가 섞이면 PostgREST가 42703으로 거부한다');
    expect(
      payload.keys.toSet().difference(_runsColumns),
      isEmpty,
      reason: 'runs 테이블에 없는 컬럼을 보내고 있다 — 마이그레이션 누락',
    );
    // 반대 방향: 티어·랭킹 집계의 입력이 되는 컬럼은 반드시 실려야 한다.
    expect(
      payload.keys,
      containsAll(<String>[
        'id',
        'user_id',
        'started_at',
        'ended_at',
        'activity_type',
        'status',
        'distance_meters',
        'moving_seconds',
        'samples',
        'sources',
        'device_vendors',
      ]),
    );
  });

  test('서버 소유 컬럼은 페이로드에서 제외된다', () async {
    await saveAndSettle(run());

    expect(
      server.lastPayload!.keys,
      isNot(anyElement(isIn(<String>[
        'avg_pace_sec_per_km',
        'awarded_xp',
        'is_flagged',
        'flag_reason',
        'created_at',
        'updated_at',
        // 기기 로컬 전용 — 서버에 컬럼 자체가 없다.
        'sync_status',
      ]))),
    );
  });

  test('samples는 배치로 쪼개지 않고 세션 단위로 한 번에 전송된다', () async {
    // ARCHITECTURE §9: "업로드 큐는 세션 단위(RunRecord 전체)로 관리하며,
    // 부분 업로드로 인한 정합성 문제를 피하기 위해 하나의 트랜잭션으로 전송한다."
    await saveAndSettle(run(sampleCount: 120));

    expect(server.requestCount, 1);
    expect(server.rows['run-1']!['samples'], hasLength(120));
    final first =
        (server.rows['run-1']!['samples'] as List<dynamic>).first as Map<String, dynamic>;
    expect(first.keys, containsAll(<String>['timestamp', 'source', 'latitude']));
    expect(first.keys, everyElement(matches(RegExp(r'^[a-z0-9_]+$'))));
  });
}

/// `runs` 테이블의 컬럼 집합. 마이그레이션 01 + 36(`device_vendors`) +
/// 39(`awarded_points` → `awarded_xp`) 기준.
///
/// 모델에 필드를 추가하면서 마이그레이션을 빠뜨리면 이 집합과 어긋나 위 테스트가
/// 깨진다 — 그게 이 상수의 목적이다.
const Set<String> _runsColumns = <String>{
  'id',
  'user_id',
  'started_at',
  'ended_at',
  'activity_type',
  'status',
  'distance_meters',
  'elapsed_seconds',
  'moving_seconds',
  'avg_pace_sec_per_km',
  'max_speed_mps',
  'elevation_gain_meters',
  'elevation_loss_meters',
  'avg_heart_rate_bpm',
  'max_heart_rate_bpm',
  'calories_kcal',
  'avg_cadence_spm',
  'samples',
  'route_polyline',
  'title',
  'note',
  'sources',
  'device_vendors',
  'awarded_xp',
  'created_at',
  'updated_at',
  'is_flagged',
  'flag_reason',
  // 64: 서버 재계산 직전의 클라이언트 주장값(서버 전용, 클라이언트는 보내지 않는다).
  'client_reported',
};

/// `runs` upsert만 흉내 내는 최소 PostgREST.
///
/// 실제 서버를 세우는 이유: `_push()`가 실제로 무엇을 직렬화해 보내는지는
/// HTTP 바이트에서만 관찰할 수 있다. 목 클라이언트로는 `toJson()`을 다시
/// 호출해 비교하게 되어 "같은 코드로 같은 코드를 검증"하는 순환이 된다.
class _FakePostgrest {
  _FakePostgrest._(this._server) {
    unawaited(_serve());
  }

  static Future<_FakePostgrest> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakePostgrest._(server);
  }

  final HttpServer _server;

  /// 서버가 확정해 돌려주는 값 — 클라이언트가 보낸 값과 일부러 다르게 둔다.
  static const double serverPace = 361.5;
  static const int serverXp = 50;

  /// 마이그레이션 64의 샘플 재계산 결과를 흉내 낸다. null이 아니면 응답에
  /// `distance_meters`/`moving_seconds`/`client_reported`를 실어 보낸다 —
  /// 서버가 거리를 깎았을 때 클라이언트가 그것을 되받는지 보기 위한 것(QA F-4).
  double? recalculatedDistanceMeters;
  int? recalculatedMovingSeconds;

  /// 네트워크 없음. 소켓을 그대로 끊어 실제 오프라인과 같은 실패를 만든다.
  bool offline = false;

  /// 200을 주지만 본문이 `.single()` 계약을 어기는 상황.
  bool corruptResponse = false;

  /// 응답을 **보류**시키는 게이트. 완료시킬 때까지 서버가 응답을 쓰지 않는다.
  ///
  /// [hang]과 다르다: hang은 영원히 매달려 타임아웃을 검증하는 반면, 이쪽은
  /// "업로드가 진행 중인 순간"을 테스트가 붙잡아 두기 위한 장치다(인플라이트
  /// 가드 검증).
  Completer<void>? gate;

  /// **스탈된 연결**. 소켓은 살아 있는데 응답이 영원히 오지 않는다(캡티브 포털,
  /// 지하철 셀 전환). 오프라인(`offline`)처럼 즉시 실패하지 않는다는 점이 핵심 —
  /// 타임아웃이 없으면 여기서 클라이언트가 영원히 멈춘다(QA C-3).
  bool hang = false;

  /// 서버가 거부(4xx)할 run id — 부분 실패 시나리오용.
  final Set<String> rejectIds = <String>{};

  /// 서버 테이블. id가 PK이므로 재 upsert는 덮어쓸 뿐 행을 늘리지 않는다.
  final Map<String, Map<String, dynamic>> rows = <String, Map<String, dynamic>>{};

  /// 도착한 upsert의 id 순서. 멱등성·정렬 검증용.
  final List<String> upsertedIds = <String>[];

  int requestCount = 0;
  Map<String, dynamic>? lastPayload;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> stop() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final HttpRequest request in _server) {
      requestCount += 1;

      if (hang) {
        // 응답을 쓰지도, 닫지도 않는다 — 요청이 그대로 매달린다.
        continue;
      }

      // 요청이 "도착했고 아직 응답 전"인 상태로 테스트가 붙잡아 둘 수 있게 한다.
      final Completer<void>? held = gate;
      if (held != null) await held.future;

      if (offline) {
        // 응답 헤더도 쓰지 않고 소켓을 파괴 → 클라이언트에는 연결 실패로 보인다.
        final Socket socket = await request.response.detachSocket();
        socket.destroy();
        continue;
      }

      final String body = await utf8.decoder.bind(request).join();
      final dynamic decoded = body.isEmpty ? null : jsonDecode(body);
      final Map<String, dynamic> payload = decoded is List
          ? decoded.first as Map<String, dynamic>
          : decoded as Map<String, dynamic>;
      lastPayload = payload;

      final String id = payload['id'] as String;
      upsertedIds.add(id);

      if (rejectIds.contains(id)) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<String, dynamic>{
            'code': '23514',
            'message': 'new row violates check constraint',
          }));
        await request.response.close();
        continue;
      }

      // upsert = 같은 PK면 덮어쓴다. 여기가 멱등성의 서버측 근거다.
      rows[id] = payload;

      // 마이그레이션 64의 재계산 결과(있으면). 실제 서버와 같은 모양으로,
      // 원본 주장값은 client_reported 에 담아 함께 내려보낸다.
      final Map<String, dynamic> recalc = recalculatedDistanceMeters == null
          ? <String, dynamic>{}
          : <String, dynamic>{
              'distance_meters': recalculatedDistanceMeters,
              'moving_seconds':
                  recalculatedMovingSeconds ?? payload['moving_seconds'],
              'client_reported': <String, dynamic>{
                'distance_meters': payload['distance_meters'],
                'moving_seconds': payload['moving_seconds'],
              },
            };

      request.response
        ..statusCode = HttpStatus.created
        ..headers.contentType = ContentType.json
        ..write(
          corruptResponse
              // `.single()`은 객체 하나를 기대한다 — 배열이면 파싱이 깨진다.
              ? jsonEncode(<dynamic>[])
              : jsonEncode(<String, dynamic>{
                  'id': id,
                  'avg_pace_sec_per_km': serverPace,
                  'awarded_xp': serverXp,
                  'is_flagged': false,
                  'flag_reason': null,
                  'created_at': '2026-09-01T06:30:05.000Z',
                  'updated_at': '2026-09-01T06:30:05.000Z',
                  ...recalc,
                }),
        );
      await request.response.close();
    }
  }
}
