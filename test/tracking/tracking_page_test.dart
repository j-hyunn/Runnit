import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/map/map_surface.dart';
import 'package:runnit/core/error/failure.dart';
import 'package:runnit/core/providers/repository_providers.dart';
import 'package:runnit/core/repositories/run_repository.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/tracking/data/tracking_providers.dart';
import 'package:runnit/features/tracking/domain/run_tracking_service.dart';
import 'package:runnit/features/tracking/presentation/tracking_page.dart';
import 'package:runnit/features/tracking/presentation/tracking_ui_providers.dart';
import 'package:runnit/features/tracking/presentation/widgets/run_map_view.dart';
import 'package:runnit/models/models.dart';

/// 트래킹 화면의 **네 국면**(대기/기록 중/일시정지/요약)과 에러 동선을 검증한다.
///
/// 시뮬레이터에서는 카카오 OAuth 로그인을 완료할 수 없어 `/tracking`에 실제로
/// 진입할 수 없다(gps 노트 §7-4). 그래서 로그인 상태와 트래킹 엔진을 override로
/// 심어 화면만 떼어내 검증한다.
void main() {
  const userId = 'test-user';

  late FakeTrackingService service;
  late FakeRunRepository repository;

  setUp(() {
    service = FakeTrackingService();
    repository = FakeRunRepository();
  });

  tearDown(() => service.dispose());

  Future<void> pumpPage(
    WidgetTester tester, {
    List<Override> extraOverrides = const [],
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 라우터 가드가 이미 게스트를 막지만, 명령 계층도 userId를 요구한다.
          currentUserIdProvider.overrideWithValue(userId),
          isAuthenticatedProvider.overrideWithValue(true),
          runTrackingServiceProvider.overrideWithValue(service),
          runRepositoryProvider.overrideWithValue(repository),
          // 네이버 지도는 NCP 클라이언트 ID로 초기화돼 있어야 렌더된다
          // (`NaverMap.build()`가 assert로 시작한다). 위젯 테스트에는 네이티브
          // 뷰도 키도 없으므로 지도 표면 자체를 스텁으로 갈아끼운다.
          mapSurfaceBuilderProvider.overrideWithValue(stubMapSurfaceBuilder),
          ...extraOverrides,
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const TrackingPage(),
        ),
      ),
    );
    await tester.pump();
  }

  group('대기 국면', () {
    testWidgets('목표 탭·목표 숫자·시작 버튼이 보인다', (tester) async {
      await pumpPage(tester);

      expect(find.text('거리'), findsOneWidget);
      expect(find.text('시간'), findsOneWidget);
      expect(find.text('5.00'), findsOneWidget); // 기본 목표: 5km
      expect(find.text('킬로미터'), findsOneWidget);
      expect(find.text('시작'), findsOneWidget);
      expect(find.text('러닝 설정'), findsOneWidget);
      // 진행 중이 아니므로 컨트롤은 없어야 한다.
      expect(find.text('일시정지'), findsNothing);
    });

    testWidgets('목표 탭을 시간으로 바꾸면 분 단위로 표시된다', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('시간'));
      await tester.pump();

      expect(find.text('30:00'), findsOneWidget); // 기본 목표: 30분
      expect(find.text('분'), findsOneWidget);
      expect(find.text('킬로미터'), findsNothing);
    });

    testWidgets('활동 유형은 항상 야외 러닝으로 시작된다', (tester) async {
      // Figma 디자인 개편으로 활동 유형 선택 UI가 빠졌다 — 사용자 확정 사항.
      // 야외 러닝 고정이 실제로 start()에 전달되는지만 확인한다.
      await pumpPage(tester);

      await tester.tap(find.text('시작'));
      await settle(tester);

      expect(service.startedType, ActivityType.outdoorRun);
    });
  });

  group('미완결 세션 복구', () {
    testWidgets('배너로 저장/버리기 선택지를 준다', (tester) async {
      final interrupted = _record(
        userId,
        status: RunStatus.recording,
        distanceMeters: 3210,
        elapsedSeconds: 1122,
      );
      await pumpPage(
        tester,
        extraOverrides: [
          interruptedRunProvider.overrideWith((ref) async => interrupted),
        ],
      );
      await settle(tester);

      expect(find.textContaining('완료되지 않은 러닝이 있어요'), findsOneWidget);
      expect(find.textContaining('3.21km / 18:42'), findsOneWidget);

      await tester.tap(find.text('버리기'));
      await settle(tester);

      expect(repository.deleted, <String>['run-1']);
    });
  });

  group('에러 동선', () {
    testWidgets('영구 거부는 "설정 열기"를 준다', (tester) async {
      service.readyFailure = const Failure.permissionDenied(
        permission: 'location',
        permanentlyDenied: true,
      );
      await pumpPage(tester);

      await tester.tap(find.text('시작'));
      await settle(tester);

      expect(find.text('설정 열기'), findsOneWidget);
      // 영구 거부에 "다시 시도"를 주면 아무 일도 일어나지 않아 사용자가 갇힌다.
      expect(find.text('권한 허용하기'), findsNothing);
    });

    testWidgets('일시 거부는 재요청 동선을 준다', (tester) async {
      service.readyFailure =
          const Failure.permissionDenied(permission: 'location');
      await pumpPage(tester);

      await tester.tap(find.text('시작'));
      await settle(tester);

      expect(find.text('권한 허용하기'), findsOneWidget);
      expect(find.text('설정 열기'), findsNothing);
    });

    testWidgets('위치 서비스 꺼짐은 별도 문구를 준다', (tester) async {
      service.readyFailure = const Failure.serviceDisabled(service: 'location');
      await pumpPage(tester);

      await tester.tap(find.text('시작'));
      await settle(tester);

      expect(find.textContaining('위치 서비스가 꺼져 있어요'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
    });
  });

  group('목표 진행률', () {
    testWidgets('진행 중에는 목표 대비 퍼센트가 뜬다', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('시작'));
      await settle(tester);

      // 기본 목표는 거리 5km. 2.5km면 정확히 50%.
      service.emit(
        _record(userId, status: RunStatus.recording, distanceMeters: 2500),
      );
      await settle(tester);

      expect(find.textContaining('목표'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
    });

    testWidgets('목표를 넘기면 달성 배지와 스낵바가 뜬다', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('시작'));
      await settle(tester);

      service.emit(
        _record(userId, status: RunStatus.recording, distanceMeters: 5200),
      );
      await settle(tester);

      expect(find.text('목표 달성!'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.textContaining('목표 5.00km를 달성했어요'), findsOneWidget);
    });

    testWidgets('한 번 알린 뒤에는 다음 스냅샷에서 다시 뜨지 않는다', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('시작'));
      await settle(tester);

      service.emit(
        _record(userId, status: RunStatus.recording, distanceMeters: 5200),
      );
      await settle(tester);
      // 스낵바를 닫고, 목표를 넘긴 채로 계속 달리는 다음 스냅샷을 흘려보낸다.
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
          .hideCurrentSnackBar();
      await tester.pump(const Duration(seconds: 1));

      service.emit(
        _record(userId, status: RunStatus.recording, distanceMeters: 6000),
      );
      await settle(tester);

      expect(find.textContaining('목표 5.00km를 달성했어요'), findsNothing);
    });
  });

  group('기록 중 국면', () {
    testWidgets('거리/시간/페이스와 컨트롤이 표시된다', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('시작'));
      await settle(tester);

      service.emit(
        _record(
          userId,
          status: RunStatus.recording,
          distanceMeters: 2345.0,
          elapsedSeconds: 754,
          movingSeconds: 700,
          avgPaceSecPerKm: 298.5,
        ),
      );
      await settle(tester);

      expect(find.text('2.35'), findsOneWidget); // km, 소수 2자리
      expect(find.text('12:34'), findsOneWidget); // 754s → mm:ss
      expect(find.text("4'59\"/km"), findsOneWidget);
      expect(find.text('일시정지'), findsOneWidget);
      expect(find.text('종료'), findsOneWidget);
      // 야외 러닝은 지도가 함께 뜬다.
      expect(find.byType(RunMapView), findsOneWidget);
      // 달리는 중에는 실수 방지를 위해 버리기를 노출하지 않는다.
      expect(find.text('이 러닝 버리기'), findsNothing);
    });

    testWidgets('한 시간을 넘으면 h:mm:ss로 표시된다', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('시작'));
      await settle(tester);

      service.emit(
        _record(userId, status: RunStatus.recording, elapsedSeconds: 3725),
      );
      await settle(tester);

      expect(find.text('1:02:05'), findsOneWidget);
      // 활동 유형이 야외 러닝으로 고정돼 있어 지도가 항상 뜬다.
      expect(find.byType(RunMapView), findsOneWidget);
    });

    // "실내 러닝은 지도 대신 안내가 뜬다" 테스트는 여기서 뺐다. 지도 표시 여부는
    // _TrackingPageState._activityType(고정값)로 판정되는데, Figma 개편으로
    // 대기 화면에서 활동 유형을 바꿀 UI 자체가 없어져 이 화면 흐름으로는
    // indoorRun 경로에 도달할 수 없다(RunMapUnavailable/RunFormat.hasRoute
    // 로직 자체는 그대로 남아 있다 — 다른 유형 진입점이 생기면 테스트를
    // 되살릴 것). 회귀 없이 남겨두면 거짓 안전감을 주므로 삭제를 택했다.

    testWidgets('Garmin 지연 동기화 배너가 뜬다', (tester) async {
      await pumpPage(
        tester,
        extraOverrides: [
          wearableNoticeReaderProvider.overrideWithValue(
            () => const WearableNotice(connected: true, delayedSync: true),
          ),
        ],
      );
      await tester.tap(find.text('시작'));
      await settle(tester);

      service.emit(_record(userId, status: RunStatus.recording));
      await settle(tester);

      expect(
        find.text('워치 데이터는 Garmin Connect 동기화 후 반영돼요.'),
        findsOneWidget,
      );
    });

    testWidgets('러닝 도중 위치 서비스가 꺼져도 누적값은 유지된다', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('시작'));
      await settle(tester);

      service.emit(
        _record(userId, status: RunStatus.recording, distanceMeters: 1500),
      );
      await settle(tester);
      service.emitError(const Failure.serviceDisabled(service: 'location'));
      await settle(tester);

      expect(find.textContaining('위치 서비스가 꺼졌어요'), findsOneWidget);
      expect(find.text('1.50'), findsOneWidget); // 값이 사라지지 않는다
    });
  });

  group('일시정지 국면', () {
    testWidgets('재개/버리기가 나타나고 통계는 유지된다', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('시작'));
      await settle(tester);

      service.emit(
        _record(userId, status: RunStatus.recording, distanceMeters: 3210),
      );
      await settle(tester);

      await tester.tap(find.text('일시정지'));
      await settle(tester);
      expect(service.paused, isTrue);

      service.emit(
        _record(userId, status: RunStatus.paused, distanceMeters: 3210),
      );
      await settle(tester);

      expect(find.text('일시정지됨'), findsOneWidget);
      expect(find.text('재개'), findsOneWidget);
      expect(find.text('이 러닝 버리기'), findsOneWidget);
      expect(find.text('3.21'), findsOneWidget);
    });
  });

  group('요약 국면', () {
    testWidgets('종료 확인 후 최종 기록이 요약된다', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.text('시작'));
      await settle(tester);

      service.emit(_record(userId, status: RunStatus.recording));
      await settle(tester);

      service.finalRecord = _record(
        userId,
        status: RunStatus.completed,
        distanceMeters: 5012,
        elapsedSeconds: 1500,
        movingSeconds: 1450,
        avgPaceSecPerKm: 289.3,
        caloriesKcal: 320,
      );

      await tester.tap(find.text('종료'));
      await settle(tester);
      // 종료는 되돌릴 수 없으므로 반드시 한 번 확인한다.
      expect(find.text('러닝을 종료할까요?'), findsOneWidget);

      await tester.tap(find.text('종료하고 저장'));
      await settle(tester);

      expect(find.text('실내 러닝 완료!'), findsOneWidget);
      expect(find.text('5.01 km'), findsOneWidget);
      expect(find.text('25:00'), findsOneWidget);
      expect(find.text('320 kcal'), findsOneWidget);
      // 종료 흐름은 로컬 저장을 거친다.
      expect(repository.saved.single.status, RunStatus.completed);

      await tester.tap(find.text('확인'));
      await settle(tester);

      // 확인 후에는 다시 대기 국면으로 돌아온다.
      expect(find.text('시작'), findsOneWidget);
      expect(find.text('5.01 km'), findsNothing);
    });
  });
}


/// `pumpAndSettle`을 쓸 수 없다: 지도의 "GPS 신호를 잡는 중" 스피너가 무한
/// 애니메이션이라 영원히 안정되지 않는다. 고정 시간만큼 프레임을 흘려보낸다.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

RunRecord _record(
  String userId, {
  required RunStatus status,
  double distanceMeters = 0,
  int elapsedSeconds = 0,
  int movingSeconds = 0,
  double? avgPaceSecPerKm,
  int? caloriesKcal,
  ActivityType activityType = ActivityType.indoorRun,
}) {
  return RunRecord(
    id: 'run-1',
    userId: userId,
    startedAt: DateTime.utc(2026, 8, 20, 9),
    activityType: activityType,
    status: status,
    distanceMeters: distanceMeters,
    elapsedSeconds: elapsedSeconds,
    movingSeconds: movingSeconds,
    avgPaceSecPerKm: avgPaceSecPerKm,
    caloriesKcal: caloriesKcal,
  );
}

/// 플러그인(geolocator/health) 없이 [RunTrackingService] 계약만 흉내 낸다.
class FakeTrackingService implements RunTrackingService {
  final StreamController<RunSample> _samples =
      StreamController<RunSample>.broadcast();
  final StreamController<RunRecord> _sessions =
      StreamController<RunRecord>.broadcast();

  Failure? readyFailure;
  RunRecord? finalRecord;
  ActivityType? startedType;
  bool paused = false;
  bool discarded = false;

  void emit(RunRecord record) => _sessions.add(record);
  void emitError(Object error) => _sessions.addError(error);

  void dispose() {
    _samples.close();
    _sessions.close();
  }

  @override
  Stream<RunSample> get sampleStream => _samples.stream;

  @override
  Stream<RunRecord> get sessionStream => _sessions.stream;

  @override
  Future<void> ensureReady() async {
    final failure = readyFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<RunRecord> start({
    required String userId,
    required ActivityType type,
  }) async {
    startedType = type;
    final initial = _record(
      userId,
      status: RunStatus.recording,
      activityType: type,
    );
    _sessions.add(initial);
    return initial;
  }

  @override
  Future<void> pause() async => paused = true;

  @override
  Future<void> resume() async => paused = false;

  @override
  Future<RunRecord> stop() async =>
      finalRecord ?? _record('u', status: RunStatus.completed);

  @override
  Future<void> discard() async => discarded = true;
}

class FakeRunRepository implements RunRepository {
  final List<RunRecord> saved = <RunRecord>[];
  final List<String> deleted = <String>[];

  @override
  Future<RunMeta> updateMeta(String id, {String? title, String? note}) async =>
      RunMeta.normalized(title: title, note: note);

  @override
  Future<void> save(RunRecord record) async => saved.add(record);

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<RunRecord?> findById(String id, {bool includeSamples = false}) async =>
      null;

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
  Future<int> syncPending({String? userId}) async => 0;
}
