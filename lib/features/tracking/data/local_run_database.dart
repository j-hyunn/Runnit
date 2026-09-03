import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../models/models.dart';

part 'local_run_database.g.dart';

/// 러닝 기록의 로컬(오프라인) 저장 테이블.
///
/// ## 왜 컬럼을 다 펴지 않고 JSON 두 덩어리로 두는가
/// 이 테이블의 유일한 소비자는 [RunRecord] 하나이고, 로컬에서 필요한 질의는
/// "내 기록 최신순", "id 단건", "미동기화 목록" 세 가지뿐이다. 25개 필드를
/// 전부 컬럼으로 펴면 모델이 바뀔 때마다 마이그레이션이 필요해지는데,
/// 그 대가로 얻는 것이 없다. 대신 **질의에 실제로 쓰이는 키만** 컬럼으로
/// 승격하고 나머지는 모델의 `toJson`을 그대로 담는다.
///
/// [summaryJson]과 [samplesJson]을 나눈 이유는 payload 때문이다 —
/// 목록 조회는 samples가 항상 비어야 하는데(`RunRepository.listByUser` 계약),
/// 한 덩어리로 저장하면 1시간 러닝 3600 샘플을 매번 파싱한 뒤 버려야 한다.
class RunRecordRows extends Table {
  /// 클라이언트 생성 UUID v4. 서버 `runs.id`와 동일한 값이라 업로드가 멱등이다.
  TextColumn get id => text()();

  TextColumn get userId => text()();

  /// 정렬 키. `startedAt`은 UTC로만 저장한다.
  DateTimeColumn get startedAt => dateTime()();

  /// [RunStatus]의 wire 문자열. 완료 건만 서버로 올리기 위한 필터.
  TextColumn get status => text()();

  /// [SyncStatus]의 wire 문자열. 서버에는 존재하지 않는 기기 로컬 상태다.
  TextColumn get syncStatus => text()();

  /// samples를 뺀 [RunRecord]의 JSON.
  TextColumn get summaryJson => text()();

  /// `List<RunSample>`의 JSON 배열.
  TextColumn get samplesJson => text()();

  /// 로컬 갱신 시각. 체크포인트 저장이 얼마나 최신인지 판단용.
  DateTimeColumn get updatedAtLocal => dateTime()();

  /// 서버 업로드를 **실패한 누적 횟수**. 성공하면 0으로 되돌아간다.
  ///
  /// 이 컬럼이 없을 때 `syncPending()`은 `synced`가 아닌 행을 **영원히** 다시
  /// 올렸다(TRD §14 L-2). 서버가 구조적으로 거부하는 행(스키마 드리프트, CHECK
  /// 위반) 하나가 2분마다 1MB짜리 샘플을 재전송하는 상태가 앱 수명 내내 이어진다.
  /// [LocalRunRepository.maxSyncAttempts]가 그 상한이다.
  IntColumn get syncAttempts => integer().withDefault(const Constant(0))();

  /// 마지막 업로드 시도 시각. 상한에 걸린 행을 진단·복구(수동 재시도)할 때
  /// "언제부터 못 올라가고 있는가"를 답하는 유일한 근거다.
  DateTimeColumn get lastSyncAttemptAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DriftDatabase(tables: <Type>[RunRecordRows])
class LocalRunDatabase extends _$LocalRunDatabase {
  LocalRunDatabase() : super(_openConnection());

  /// 테스트에서 인메모리 DB를 주입하기 위한 생성자.
  LocalRunDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  /// v1 → v2: 재시도 상한용 컬럼 2개 추가(TRD §14 #29 / L-2).
  ///
  /// 기존 행은 `sync_attempts = 0`으로 시작한다 — 이미 여러 번 실패했던 행이라도
  /// 앱 업데이트 직후 한 번은 다시 기회를 받는 편이 낫다(상한의 목적은 무한
  /// 재전송을 끊는 것이지 기록을 버리는 것이 아니다).
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) => m.createAll(),
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await m.addColumn(runRecordRows, runRecordRows.syncAttempts);
            await m.addColumn(runRecordRows, runRecordRows.lastSyncAttemptAt);
          }
        },
      );

  static QueryExecutor _openConnection() {
    return LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      return NativeDatabase.createInBackground(
        File(p.join(dir.path, 'runnit_runs.sqlite')),
      );
    });
  }
}

/// [RunRecord] ↔ 행 변환. 모델 파일을 건드리지 않기 위해 확장으로 둔다.
extension RunRecordRowMapper on RunRecord {
  RunRecordRowsCompanion toRow({DateTime? now}) {
    final json = toJson();
    // samples는 별도 컬럼으로 뺀다 — 위 클래스 주석 참조.
    json.remove('samples');
    return RunRecordRowsCompanion.insert(
      id: id,
      userId: userId,
      startedAt: startedAt.toUtc(),
      status: runStatusWire(status),
      syncStatus: syncStatusWire(syncStatus),
      summaryJson: jsonEncode(json),
      samplesJson: jsonEncode(
        samples.map((RunSample s) => s.toJson()).toList(growable: false),
      ),
      updatedAtLocal: (now ?? DateTime.now()).toUtc(),
    );
  }
}

/// 행 → 모델. [includeSamples]가 false면 samples 컬럼을 파싱조차 하지 않는다.
RunRecord runRecordFromRow(RunRecordRow row, {bool includeSamples = false}) {
  final json = jsonDecode(row.summaryJson) as Map<String, dynamic>;
  json['samples'] = includeSamples
      ? (jsonDecode(row.samplesJson) as List<dynamic>)
      : <dynamic>[];
  return RunRecord.fromJson(json).copyWith(
    syncStatus: syncStatusFromWire(row.syncStatus),
  );
}

/// enum ↔ wire 문자열. `@JsonValue` 맵은 생성 코드의 private 심볼이라
/// 질의 계층에서 못 쓴다(`core/api/wire_enums.dart`와 같은 이유).
String runStatusWire(RunStatus status) => switch (status) {
      RunStatus.recording => 'recording',
      RunStatus.paused => 'paused',
      RunStatus.completed => 'completed',
      RunStatus.discarded => 'discarded',
    };

String syncStatusWire(SyncStatus status) => switch (status) {
      SyncStatus.local => 'local',
      SyncStatus.pending => 'pending',
      SyncStatus.synced => 'synced',
      SyncStatus.failed => 'failed',
    };

SyncStatus syncStatusFromWire(String value) => switch (value) {
      'pending' => SyncStatus.pending,
      'synced' => SyncStatus.synced,
      'failed' => SyncStatus.failed,
      _ => SyncStatus.local,
    };
