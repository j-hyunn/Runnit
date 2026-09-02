import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:runnit/features/tracking/data/local_run_database.dart';
import 'package:runnit/features/tracking/data/local_run_repository.dart';
import 'package:runnit/models/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 회귀 가드: **원격에서 읽어온 기록은 `synced`여야 한다.**
///
/// `RunRecord.syncStatus`는 기기 로컬 컬럼이라 서버 응답에 없고, 모델 기본값이
/// `SyncStatus.local`이다. `_fromRemote`가 이 값을 확정하지 않으면 방금 서버에서
/// 읽어온 기록이 상세 화면·목록에서 "동기화 대기"로 보인다(ARCHITECTURE §9.1
/// 안내 UI가 이 필드를 읽는다). 필드를 화면에서 아무도 읽지 않던 시절에는
/// 무해했던 결함이라, 되돌려도 조용히 지나갈 위험이 있어 여기서 고정한다.
///
/// `find_by_id_samples_cache_test.dart`는 도달 불가 주소로 "원격을 시도했는가"만
/// 관찰하므로 성공 응답 경로를 덮지 못한다 — 그래서 별도 파일에서 응답을 stub한다.
void main() {
  late LocalRunDatabase db;

  setUp(() {
    db = LocalRunDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// 서버가 돌려주는 `runs` 행. **`sync_status` 키가 없다** — 그게 핵심이다.
  Map<String, dynamic> remoteRow() => <String, dynamic>{
        'id': 'run-1',
        'user_id': 'user-1',
        'started_at': '2026-08-26T06:00:00.000Z',
        'ended_at': '2026-08-26T06:30:00.000Z',
        'activity_type': 'outdoor_run',
        'status': 'completed',
        'distance_meters': 5000,
        'elapsed_seconds': 1800,
        'moving_seconds': 1750,
        'samples': <dynamic>[],
      };

  /// PostgREST `.maybeSingle()`은 단일 객체 응답을 기대한다
  /// (`Accept: application/vnd.pgrst.object+json`).
  LocalRunRepository repositoryReturning(Map<String, dynamic> row) {
    final client = MockClient(
      // `request`를 되돌려줘야 한다 — postgrest가 응답 파싱에서
      // `response.request!.method`를 읽는다.
      (request) async => http.Response(
        jsonEncode(row),
        200,
        request: request,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );
    return LocalRunRepository(
      db,
      SupabaseClient(
        'http://localhost:54321',
        'test-anon-key',
        httpClient: client,
      ),
    );
  }

  test('로컬에 없어 원격에서 가져온 기록은 synced로 확정된다', () async {
    final repository = repositoryReturning(remoteRow());

    final record = await repository.findById('run-1', includeSamples: true);

    expect(record, isNotNull);
    // 모델 기본값(`local`)이 새어 나오면 "동기화 대기"로 오탐한다.
    expect(record!.syncStatus, SyncStatus.synced);
  });

  test('원격 결과를 캐시한 로컬 행도 synced로 남는다', () async {
    final repository = repositoryReturning(remoteRow());

    await repository.findById('run-1', includeSamples: true);

    // 두 번째 조회는 로컬 히트다 — 캐시에 잘못된 상태가 굳었다면 여기서 드러난다.
    final cached = await repository.findById('run-1', includeSamples: true);
    expect(cached!.syncStatus, SyncStatus.synced);
  });
}
