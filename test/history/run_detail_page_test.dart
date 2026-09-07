import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/map/map_surface.dart';
import 'package:runnit/core/providers/repository_providers.dart';
import 'package:runnit/core/repositories/run_repository.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/history/data/gpx_export_service.dart';
import 'package:runnit/features/history/data/run_detail_providers.dart';
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
    // 모델 기본값은 `local`이지만 여기서는 "이미 올라간 기록"을 표준으로 둔다 —
    // 그러지 않으면 모든 케이스에 동기화 배너가 따라붙어 검증 대상이 흐려진다.
    SyncStatus syncStatus = SyncStatus.synced,
    RunStatus status = RunStatus.completed,
    ClientReportedRun? clientReported,
  }) =>
      RunRecord(
        id: runId,
        userId: 'user-1',
        startedAt: t0,
        endedAt: t0.add(const Duration(seconds: 900)),
        activityType: activityType,
        status: status,
        syncStatus: syncStatus,
        distanceMeters: distanceMeters,
        elapsedSeconds: 900,
        movingSeconds: 900,
        avgPaceSecPerKm: distanceMeters == 0 ? null : 900 / (distanceMeters / 1000),
        samples: samples,
        isFlagged: isFlagged,
        note: note,
        clientReported: clientReported,
      );

  /// 3km 등속 러닝 — 완전 3랩이 나오는 표준 케이스.
  List<RunSample> threeKmSamples() => [
        for (var i = 0; i <= 30; i++) sample(i * 100.0, i * 30),
      ];

  Future<void> pump(
    WidgetTester tester,
    _FakeRunRepository repository, {
    Size size = const Size(420, 1400),
    GpxExportService? gpxService,
    // 넘기면 `myRunsProvider`가 살아난다 — 상세 화면이 목록 스트림에서 최신
    // `syncStatus`를 골라 오는 경로(`runSyncStatusProvider`)를 켜는 스위치.
    String? userId,
    // 자동 재시도 예산 소진 여부. 실제 원천은 drift 행의 `sync_attempts`인데
    // (`LocalRunRepository.watchSyncRetryExhausted`, 회귀는
    // `test/sync/offline_sync_test.dart` §10) 그 컬럼은 [RunRecord]에 없어
    // 여기 fake로는 재현할 수 없다. 화면 쪽 관심사는 "이 술어가 true일 때
    // 무엇이 보이는가"뿐이므로 provider 경계에서 갈아끼운다.
    bool retryExhausted = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          runRepositoryProvider.overrideWithValue(repository),
          if (userId != null) currentUserIdProvider.overrideWithValue(userId),
          if (gpxService != null)
            gpxExportServiceProvider.overrideWithValue(gpxService),
          if (retryExhausted)
            runSyncRetryExhaustedProvider(runId)
                .overrideWith((ref) => Stream<bool>.value(true)),
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

  // ARCHITECTURE §9.1 — 지각 업로드는 마감된 과거 시즌·주에 소급되지 않는다.
  // 업로드 전에 그 사실을 알리는 배너가 정확히 미동기화 완료 러닝에만 붙는지.
  testWidgets('업로드가 끝난 기록에는 동기화 배너를 띄우지 않는다', (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(run(samples: threeKmSamples())),
    );
    await tester.pumpAndSettle();

    expect(find.text('동기화 대기 중'), findsNothing);
  });

  for (final status in [SyncStatus.local, SyncStatus.pending]) {
    testWidgets('$status 완료 러닝에는 티어·랭킹 미반영을 알리는 배너를 띄운다',
        (tester) async {
      await pump(
        tester,
        _FakeRunRepository.value(
          run(samples: threeKmSamples(), syncStatus: status),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('동기화 대기 중'), findsOneWidget);
      expect(
        find.textContaining('이번 시즌 티어와 주간 랭킹에 반영되지 않아요'),
        findsOneWidget,
      );
      // 재시도 문구는 실제로 실패한 적이 있을 때만.
      expect(find.textContaining('업로드에 실패해'), findsNothing);
    });
  }

  testWidgets('failed면 재시도 중이라는 사실까지 밝힌다', (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(
        run(samples: threeKmSamples(), syncStatus: SyncStatus.failed),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('동기화 대기 중'), findsOneWidget);
    expect(find.textContaining('업로드에 실패해'), findsOneWidget);
  });

  // 상세 조회는 단발 FutureProvider라, 화면을 열어 둔 채 업로드가 끝나도
  // 스냅샷은 그대로다. 목록 스트림에서 최신 상태를 골라 오는 경로가 없으면
  // 배너가 재진입 전까지 남는다(QA O-3).
  testWidgets('열어 둔 채 업로드가 끝나면 배너가 그 자리에서 사라진다', (tester) async {
    final repository = _FakeRunRepository.value(
      run(samples: threeKmSamples(), syncStatus: SyncStatus.pending),
    );
    await pump(tester, repository, userId: 'user-1');
    repository.runsStream.add([
      run(syncStatus: SyncStatus.pending),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('동기화 대기 중'), findsOneWidget);

    // 업로드 완료 — drift watch()가 갱신된 행을 재발행하는 상황.
    repository.runsStream.add([run(syncStatus: SyncStatus.synced)]);
    await tester.pumpAndSettle();

    expect(find.text('동기화 대기 중'), findsNothing);
  });

  testWidgets('목록 스트림이 모르는 기록은 조회 시점 상태로 판정한다', (tester) async {
    // 상한(200건) 밖의 오래된 기록·다른 기기 기록이 이 경우다.
    final repository = _FakeRunRepository.value(
      run(samples: threeKmSamples(), syncStatus: SyncStatus.local),
    );
    await pump(tester, repository, userId: 'user-1');
    repository.runsStream.add(const <RunRecord>[]);
    await tester.pumpAndSettle();

    expect(find.text('동기화 대기 중'), findsOneWidget);
  });

  // ───── 수동 재시도 (TRD §14 #29 잔여 F-5) ─────
  //
  // 상한(maxSyncAttempts=10)에 걸린 행은 `syncPending()`이 질의 단계에서
  // 제외한다 — 자동 재시도가 멈춘 줄 모르는 사용자에게는 "동기화 대기"가
  // 영원히 걸려 있다. `resetSyncAttempts`가 유일한 탈출구이고, 그것을 부르는
  // UI가 여기다.

  testWidgets('예산이 남아 있으면 다시 시도 버튼을 주지 않는다', (tester) async {
    // 코디네이터가 어차피 할 일을 사용자에게 시키면 안 된다.
    await pump(
      tester,
      _FakeRunRepository.value(
        run(samples: threeKmSamples(), syncStatus: SyncStatus.failed),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('업로드에 실패해'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
  });

  testWidgets('재시도 상한에 걸리면 문구를 바꾸고 다시 시도 버튼을 준다',
      (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(
        run(samples: threeKmSamples(), syncStatus: SyncStatus.failed),
      ),
      retryExhausted: true,
    );
    await tester.pumpAndSettle();

    expect(find.text('동기화 대기 중'), findsOneWidget);
    expect(find.textContaining('여러 번 시도했지만 올리지 못했어요'), findsOneWidget);
    // "기다리면 자동으로 올라간다"는 이 상태에서 거짓이다.
    expect(find.textContaining('업로드에 실패해 다시 시도하고 있어요'), findsNothing);
    expect(find.text('다시 시도'), findsOneWidget);
  });

  testWidgets('다시 시도를 누르면 큐를 즉시 태우고 진행 중임을 알린다', (tester) async {
    final repository = _FakeRunRepository.value(
      run(samples: threeKmSamples(), syncStatus: SyncStatus.failed),
    );
    await pump(tester, repository, retryExhausted: true);
    await tester.pumpAndSettle();

    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();

    // 예산만 되돌리면 다음 코디네이터 신호(최대 2분)까지 아무 일도 안 일어나
    // 버튼이 먹통처럼 보인다 — 그 자리에서 한 번 태운다.
    expect(repository.syncPendingCalls, <String?>['user-1']);
    expect(find.text('다시 시도하고 있어요'), findsOneWidget);
  });

  testWidgets('업로드가 끝난 기록에는 상한 상태여도 배너 자체가 없다', (tester) async {
    // 배너 노출 조건은 `isSyncPending` 하나다 — 예산 소진은 그 안에서
    // 문구를 가르는 두 번째 축일 뿐이다.
    await pump(
      tester,
      _FakeRunRepository.value(run(samples: threeKmSamples())),
      retryExhausted: true,
    );
    await tester.pumpAndSettle();

    expect(find.text('동기화 대기 중'), findsNothing);
    expect(find.text('다시 시도'), findsNothing);
  });

  // ───── 확정 거리 병기 (TRD §14 #27 잔여 G-3 / F-4) ─────

  testWidgets('서버가 거리를 깎았으면 확정값 옆에 기기 기록을 병기한다',
      (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(
        run(
          samples: threeKmSamples(),
          distanceMeters: 2700,
          clientReported: const ClientReportedRun(distanceMeters: 3000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 주 숫자는 언제나 확정 거리다 — 히스토리·랭킹·공유 카드가 쓰는 값과
    // 갈리면 안 된다.
    expect(find.text('2.70 km'), findsOneWidget);
    expect(find.text('기기 기록 3.00 km'), findsOneWidget);
    // 앰버 배너 배타 규칙(플래그 > 동기화 대기)에 세 번째로 끼어들지 않는다.
    expect(find.text('동기화 대기 중'), findsNothing);

    // 랩·페이스·경로는 로컬 samples(원본 거리) 기준이라 확정 거리와 갈린다.
    expect(
      find.textContaining('랩·페이스·경로는 기기가 기록한 원본 거리 기준이에요'),
      findsOneWidget,
    );
    expect(find.textContaining('확정 거리 2.70 km가 반영돼요'), findsOneWidget);
  });

  testWidgets('조정이 없으면 병기도 안내도 없다', (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(run(samples: threeKmSamples())),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('기기 기록'), findsNothing);
    expect(find.textContaining('랩·페이스·경로는'), findsNothing);
  });

  testWidgets('표시 임계(10m) 이하의 미세 조정은 병기하지 않는다', (tester) async {
    // 서버는 1m 차이부터 client_reported를 남긴다. 그것까지 병기하면 상시
    // 노출돼 정말 깎인 기록의 신호를 덮는다(아키텍트 문서 §2).
    await pump(
      tester,
      _FakeRunRepository.value(
        run(
          samples: threeKmSamples(),
          distanceMeters: 2995,
          clientReported: const ClientReportedRun(distanceMeters: 3000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('기기 기록'), findsNothing);
    expect(find.textContaining('랩·페이스·경로는'), findsNothing);
  });

  testWidgets('플래그된 기록에서도 병기는 살아 있다', (tester) async {
    // 배너로 만들었다면 플래그 배너에 밀려 사라졌을 정보다 — 인라인으로 둔
    // 이유가 이것이다.
    await pump(
      tester,
      _FakeRunRepository.value(
        run(
          samples: threeKmSamples(),
          distanceMeters: 2700,
          isFlagged: true,
          clientReported: const ClientReportedRun(distanceMeters: 3000),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('이 기록은 검토 대상으로 표시되어 티어·랭킹에 반영되지 않았어요.'),
      findsOneWidget,
    );
    expect(find.text('기기 기록 3.00 km'), findsOneWidget);
  });

  testWidgets('플래그와 미동기화가 겹치면 플래그 배너만 띄운다', (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(
        run(
          samples: threeKmSamples(),
          isFlagged: true,
          syncStatus: SyncStatus.failed,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('이 기록은 검토 대상으로 표시되어 티어·랭킹에 반영되지 않았어요.'),
      findsOneWidget,
    );
    expect(find.text('동기화 대기 중'), findsNothing);
  });

  testWidgets('플래그 + 미동기화 + 재시도 소진이면 플래그 배너 아래 재시도 액션을 준다',
      (tester) async {
    final repository = _FakeRunRepository.value(
      run(
        samples: threeKmSamples(),
        isFlagged: true,
        syncStatus: SyncStatus.failed,
      ),
    );
    await pump(tester, repository, retryExhausted: true);
    await tester.pumpAndSettle();

    expect(
      find.text('이 기록은 검토 대상으로 표시되어 티어·랭킹에 반영되지 않았어요.'),
      findsOneWidget,
    );
    expect(find.text('동기화 대기 중'), findsNothing);
    expect(find.text('다시 시도'), findsOneWidget);

    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(repository.syncPendingCalls, <String?>['user-1']);
  });

  testWidgets('메모가 있으면 메모 섹션에 그대로 보여준다', (tester) async {
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

  testWidgets('메모가 없으면 메모 섹션 자리에서 바로 편집으로 들어갈 수 있다',
      (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(run(samples: threeKmSamples())),
    );
    await tester.pumpAndSettle();

    expect(find.text('메모'), findsOneWidget);
    expect(find.text('메모 추가하기'), findsOneWidget);
  });

  testWidgets('편집 시트에서 저장하면 정규화된 값이 화면에 반영된다', (tester) async {
    final repository = _FakeRunRepository.value(run(samples: threeKmSamples()));
    await pump(tester, repository);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // 수정 가능한 것은 제목·메모뿐이다 — 삭제 버튼이 있으면 안 된다
    // (PRD v1.6 §8.1: 러닝은 삭제할 수 없다).
    expect(find.text('기록 수정'), findsOneWidget);
    expect(find.text('삭제'), findsNothing);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    // 서버 CHECK(runs_title_len 60 / runs_note_len 500)와 같은 상한을
    // 입력 단계에서 먼저 막는다.
    expect(tester.widget<TextField>(fields.at(0)).maxLength, 60);
    expect(tester.widget<TextField>(fields.at(1)).maxLength, 500);

    await tester.enterText(fields.at(0), '  한강 저녁 러닝  ');
    await tester.enterText(fields.at(1), '컨디션 좋았음');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    // 시트는 닫히고, 리포지토리에는 사용자가 친 원문이 그대로 넘어간다
    // (trim·절단은 서버가 확정한다).
    expect(find.text('기록 수정'), findsNothing);
    expect(repository.metaEdit, ('run-1', '  한강 저녁 러닝  ', '컨디션 좋았음'));
    expect(find.text('기록을 수정했어요'), findsOneWidget);
    // 화면은 보낸 값이 아니라 **확정값**(trim된 제목)을 그린다.
    expect(find.text('한강 저녁 러닝'), findsOneWidget);
    expect(find.text('컨디션 좋았음'), findsOneWidget);
  });

  testWidgets('경로가 있으면 오버플로 메뉴에 GPX 내보내기가 있다', (tester) async {
    await pump(tester, _FakeRunRepository.value(run(samples: threeKmSamples())));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('GPX 내보내기'), findsOneWidget);
  });

  testWidgets('iPad 공유 앵커는 화면 전체가 아니라 오버플로 버튼 사각형이다',
      (tester) async {
    // iPad 12.9" 세로. 여기서 앵커가 화면 전체가 되면 팝오버가 버튼과 무관한
    // 곳에서 뜬다(QA A-6) — 화면이 클수록 어긋남이 눈에 띈다.
    const screen = Size(1024, 1366);
    final gpx = _FakeGpxExportService();
    await pump(
      tester,
      _FakeRunRepository.value(run(samples: threeKmSamples())),
      size: screen,
      gpxService: gpx,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPX 내보내기'));
    await tester.pumpAndSettle();

    expect(gpx.calls, 1);
    final origin = gpx.lastOrigin;
    expect(origin, isNotNull);

    // 1) 화면 전체가 아니다 — 버그의 증상이 정확히 이것이었다.
    expect(origin, isNot(Offset.zero & screen));
    expect(origin!.width, lessThan(screen.width / 4));
    expect(origin.height, lessThan(screen.height / 4));

    // 2) 실제 오버플로 버튼과 겹친다.
    final button = tester.getRect(find.byIcon(Icons.more_vert));
    expect(origin.overlaps(button), isTrue);
    // 헤더는 화면 오른쪽 위 — 앵커도 거기 있어야 한다.
    expect(origin.center.dx, greaterThan(screen.width / 2));
    expect(origin.center.dy, lessThan(screen.height / 4));
  });

  testWidgets('경로가 없는 실내 러닝은 오버플로 메뉴 자체가 없다', (tester) async {
    await pump(
      tester,
      _FakeRunRepository.value(
        run(activityType: ActivityType.indoorRun, samples: const []),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('제목 입력은 grapheme이 아니라 룬(코드포인트) 기준으로 잘린다',
      (tester) async {
    final repository = _FakeRunRepository.value(run(samples: threeKmSamples()));
    await pump(tester, repository);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // 👨‍👩‍👧‍👦 = 1 grapheme / 7 코드포인트. Flutter 기본 maxLength는 grapheme으로
    // 세므로 10개(70 코드포인트)를 통과시키고, 서버가 60 코드포인트에서 잘라
    // 이모지를 반토막 낸다(QA C-3). 룬 기준 포매터는 8개(56)까지만 받는다.
    const family = '👨‍👩‍👧‍👦';
    await tester.enterText(find.byType(TextField).at(0), family * 10);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField).at(0));
    final text = field.controller!.text;
    expect(text.runes.length, lessThanOrEqualTo(60));
    expect(text.characters.length, 8); // 56 코드포인트 — 9번째는 63이라 못 들어간다
    // 카운터도 같은 단위여야 한다.
    expect(find.text('56/60'), findsOneWidget);
  });

  testWidgets('저장에 실패하면 시트를 닫지 않고 입력을 남긴 채 안내한다',
      (tester) async {
    final repository = _FakeRunRepository.value(run(samples: threeKmSamples()))
      ..failEdit = true;
    await pump(tester, repository);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), '지하 주차장에서 종료');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();

    expect(
      find.text('저장하지 못했어요. 네트워크를 확인하고 다시 시도해 주세요.'),
      findsOneWidget,
    );
    // 방금 쓴 메모가 사라지면 안 된다 — 그래서 스낵바가 아니라 인라인이다.
    expect(find.text('기록 수정'), findsOneWidget);
    expect(find.text('지하 주차장에서 종료'), findsOneWidget);
  });
}

/// 파일 I/O·플랫폼 채널 없이 `origin`만 받아 적는다 — 앵커 계산이 관심사다.
class _FakeGpxExportService implements GpxExportService {
  Rect? lastOrigin;
  int calls = 0;

  @override
  Future<GpxExportOutcome> exportAndShare(RunRecord record, {Rect? origin}) async {
    calls++;
    lastOrigin = origin;
    return GpxExportOutcome.presented;
  }
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

  /// 활동 목록 스트림. 상세 화면은 여기서 최신 `syncStatus`를 골라 온다
  /// (`runSyncStatusProvider`) — 업로드가 끝나면 배너가 그 자리에서 사라져야
  /// 하므로, 테스트가 임의 시점에 새 목록을 밀어 넣을 수 있어야 한다.
  final runsStream = StreamController<List<RunRecord>>.broadcast();

  @override
  Stream<List<RunRecord>> watchByUser(String userId, {int limit = 20}) =>
      runsStream.stream;

  /// 수동 재시도가 큐를 즉시 태웠는지. 인자까지 남긴다 — 계정 전환 후 남의
  /// 행을 밀어 올리지 않도록 호출부가 `userId`를 좁혀야 한다(QA C-5).
  final syncPendingCalls = <String?>[];

  @override
  Future<int> syncPending({String? userId}) async {
    syncPendingCalls.add(userId);
    return 0;
  }
}

enum _Mode { value, failing, pending }
