import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/map/map_surface.dart';
import 'package:runnit/core/providers/repository_providers.dart';
import 'package:runnit/core/repositories/run_repository.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/history/presentation/run_detail_page.dart';
import 'package:runnit/features/history/presentation/widgets/lap_table.dart';
import 'package:runnit/features/history/presentation/widgets/pace_chart.dart';
import 'package:runnit/features/history/presentation/widgets/run_route_map.dart';
import 'package:runnit/features/tracking/presentation/widgets/run_map_view.dart';
import 'package:runnit/models/models.dart';

/// 기록 상세(HI-02)의 **상태별 화면**을 검증한다 — 로딩/에러/없는 기록/
/// 경로 없는 실내 러닝/이상치 플래그/랩이 안 나오는 짧은 기록.
///
/// 랩 계산 자체는 `lap_splits_test.dart`가 따로 검증한다. 여기서는 계산 결과가
/// 화면에 붙는지와, 데이터가 없을 때 빈 섹션이 생기지 않는지를 본다.
void main() {
  const runId = 'run-1';
  final t0 = DateTime.utc(2026, 8, 27, 6, 0, 0);

  RunSample sample(double meters, int seconds) => RunSample(
        timestamp: t0.add(Duration(seconds: seconds)),
        latitude: 37.5 + meters / 100000,
        longitude: 127.0,
        cumulativeDistanceMeters: meters,
        source: RunSampleSource.phone,
      );

  RunRecord run({
    List<RunSample> samples = const [],
    ActivityType activityType = ActivityType.outdoorRun,
    double distanceMeters = 3000,
    bool? isFlagged,
    String? note,
  }) =>
      RunRecord(
        id: runId,
        userId: 'user-1',
        startedAt: t0,
        endedAt: t0.add(const Duration(seconds: 900)),
        activityType: activityType,
        status: RunStatus.completed,
        distanceMeters: distanceMeters,
        elapsedSeconds: 900,
        movingSeconds: 900,
        avgPaceSecPerKm: distanceMeters == 0 ? null : 900 / (distanceMeters / 1000),
        samples: samples,
        isFlagged: isFlagged,
        note: note,
      );

  /// 3km 등속 러닝 — 완전 3랩이 나오는 표준 케이스.
  List<RunSample> threeKmSamples() => [
        for (var i = 0; i <= 30; i++) sample(i * 100.0, i * 30),
      ];

  Future<void> pump(
    WidgetTester tester,
    _FakeRunRepository repository,
  ) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          runRepositoryProvider.overrideWithValue(repository),
          // 네이버 지도는 초기화된 SDK와 네이티브 뷰를 요구한다. 위젯 테스트에는
          // 둘 다 없으므로 지도 표면을 스텁으로 갈아끼운다.
          mapSurfaceBuilderProvider.overrideWithValue(stubMapSurfaceBuilder),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const RunDetailPage(runId: runId),
        ),
      ),
    );
  }

  testWidgets('조회 중에는 로딩 인디케이터를 보여준다', (tester) async {
    await pump(tester, _FakeRunRepository.pending());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('조회 실패 시 재시도 버튼을 준다', (tester) async {
    await pump(tester, _FakeRunRepository.failing());
    await tester.pumpAndSettle();

    expect(find.text('기록을 불러오지 못했어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
  });

  testWidgets('없는 기록이면 재시도 없이 안내만 한다', (tester) async {
    await pump(tester, _FakeRunRepository.value(null));
    await tester.pumpAndSettle();

    expect(find.text('기록을 찾을 수 없어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
  });

  testWidgets('경로가 있는 러닝은 지도·랩 테이블·페이스 그래프를 모두 그린다',
      (tester) async {
    await pump(tester, _FakeRunRepository.value(run(samples: threeKmSamples())));
    await tester.pumpAndSettle();

    expect(find.byType(RunRouteMap), findsOneWidget);
    expect(find.byType(RunMapUnavailable), findsNothing);
    expect(find.byType(LapTable), findsOneWidget);
    expect(find.byType(PaceChart), findsOneWidget);

    expect(find.text('구간 (1km)'), findsOneWidget);
    expect(find.text('페이스 그래프'), findsOneWidget);
    // 3랩 — 자투리 라벨은 없어야 한다.
    expect(find.text('1km'), findsOneWidget);
    expect(find.text('2km'), findsOneWidget);
    expect(find.text('3km'), findsOneWidget);
  });

  testWidgets('실내 러닝은 지도 대신 안내를 보여주고 랩 섹션을 만들지 않는다',
      (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(
        run(activityType: ActivityType.indoorRun, samples: const []),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RunRouteMap), findsNothing);
    expect(find.byType(RunMapUnavailable), findsOneWidget);
    expect(find.text('실내 러닝은 경로를 기록하지 않아요.'), findsOneWidget);

    // 제목만 남은 빈 섹션이 생기면 안 된다.
    expect(find.text('구간 (1km)'), findsNothing);
    expect(find.text('페이스 그래프'), findsNothing);
    expect(
      find.text('경로 데이터가 없어 구간·페이스 그래프를 만들 수 없어요.'),
      findsOneWidget,
    );
  });

  testWidgets('1km를 못 채운 짧은 러닝은 랩 테이블만 있고 그래프는 없다',
      (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(
        run(
          distanceMeters: 600,
          samples: [sample(0, 0), sample(300, 90), sample(600, 180)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 자투리 한 랩은 표에 남기고(사용자가 뛴 거리다),
    expect(find.byType(LapTable), findsOneWidget);
    // 막대 하나짜리 그래프는 비교 대상이 없어 그리지 않는다.
    expect(find.text('페이스 그래프'), findsNothing);
    expect(find.byType(PaceChart), findsNothing);
  });

  testWidgets('isFlagged=true면 티어·랭킹 미반영 배너를 띄운다', (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(run(samples: threeKmSamples(), isFlagged: true)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('이 기록은 검토 대상으로 표시되어 티어·랭킹에 반영되지 않았어요.'),
      findsOneWidget,
    );
  });

  testWidgets('isFlagged가 null(검증 전)이면 배너를 띄우지 않는다', (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(run(samples: threeKmSamples())),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('이 기록은 검토 대상으로 표시되어 티어·랭킹에 반영되지 않았어요.'),
      findsNothing,
    );
  });

  testWidgets('메모가 있으면 메모 섹션을, 없으면 아무것도 그리지 않는다',
      (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(
        run(samples: threeKmSamples(), note: '한강 코스 컨디션 좋았음'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('메모'), findsOneWidget);
    expect(find.text('한강 코스 컨디션 좋았음'), findsOneWidget);
  });
}

class _FakeRunRepository implements RunRepository {
  _FakeRunRepository._(this._record, this._mode);

  factory _FakeRunRepository.value(RunRecord? record) =>
      _FakeRunRepository._(record, _Mode.value);

  factory _FakeRunRepository.failing() =>
      _FakeRunRepository._(null, _Mode.failing);

  /// 영영 완료되지 않는 조회 — 로딩 국면을 붙잡아 둔다.
  factory _FakeRunRepository.pending() =>
      _FakeRunRepository._(null, _Mode.pending);

  RunRecord? _record;
  final _Mode _mode;

  /// 편집 시트가 넘긴 인자. 널 여부까지 보려고 튜플로 남긴다.
  (String, String?, String?)? metaEdit;

  /// true면 `updateMeta`가 던진다 — 저장 실패 국면 재현.
  bool failEdit = false;

  @override
  Future<RunMeta> updateMeta(String id, {String? title, String? note}) async {
    metaEdit = (id, title, note);
    if (failEdit) throw Exception('offline');
    // 서버 정규화(trim → 절단 → 빈 문자열은 null)를 그대로 흉내 낸다.
    final meta = RunMeta.normalized(title: title, note: note);
    // 실제 리포지토리가 로컬 행까지 갱신하므로, 재조회도 새 값을 봐야 한다.
    _record = _record?.copyWith(title: meta.title, note: meta.note);
    return meta;
  }

  @override
  Future<RunRecord?> findById(String id, {bool includeSamples = false}) {
    switch (_mode) {
      case _Mode.value:
        return Future<RunRecord?>.value(_record);
      case _Mode.failing:
        return Future<RunRecord?>.error(Exception('boom'));
      case _Mode.pending:
        return Completer<RunRecord?>().future;
    }
  }

  @override
  Future<void> save(RunRecord record) async {}

  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<RunRecord>> listByUser(
    String userId, {
    int limit = 20,
    DateTime? before,
  }) async =>
      const <RunRecord>[];

  @override
  Stream<List<RunRecord>> watchByUser(String userId, {int limit = 20}) =>
      const Stream<List<RunRecord>>.empty();

  @override
  Future<int> syncPending() async => 0;
}

enum _Mode { value, failing, pending }
