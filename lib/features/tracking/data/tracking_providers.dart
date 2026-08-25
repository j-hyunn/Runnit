import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/supabase_client.dart';
import '../../../core/auth/auth_providers.dart';
import '../../../core/error/failure.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../models/models.dart';
import '../domain/gps_smoothing.dart';
import '../domain/run_tracking_service.dart';
import 'geolocator_run_tracking_service.dart';
import 'health_wearable_source.dart';
import 'local_run_database.dart';
import 'local_run_repository.dart';

/// 트래킹 모듈의 provider 등록 지점 — **flutter-ui-designer가 구독할 계약**.
///
/// 화면은 아래 세 개만 알면 된다:
/// - [trackingControllerProvider] : 시작/일시정지/재개/종료/폐기 명령
/// - [activeRunProvider]          : 1초마다 갱신되는 진행 중 [RunRecord]
/// - [liveRunSampleProvider]      : 새 GPS 샘플(지도 폴리라인 연장용)

/// 로컬 SQLite 핸들. 앱 전체에서 하나만 연다.
final localRunDatabaseProvider = Provider<LocalRunDatabase>((ref) {
  final db = LocalRunDatabase();
  ref.onDispose(db.close);
  return db;
});

/// 배터리 ↔ 정확도 프로파일. 설정 화면이 이 값을 바꾼다.
///
/// ⚠️ **러닝 중에는 바꾸지 말 것.** 값이 바뀌면 [runTrackingServiceProvider]가
/// 재생성되어 진행 중 세션이 사라진다. 설정 UI는 진행 중 세션이 있으면
/// 이 항목을 비활성화한다.
final trackingProfileProvider =
    StateProvider<TrackingProfile>((ref) => TrackingProfile.standard);

/// 워치 지표 소스. 테스트/시뮬레이터에서는 override로 null 구현을 넣으면 된다.
final wearableMetricsSourceProvider = Provider<WearableMetricsSource>((ref) {
  return HealthWearableMetricsSource();
});

/// 대기 화면("러닝 설정" 시트/웨어러블 연동 화면)이 쓰는 연동 상태 —
/// 세션을 시작하지 않고도 "최근에 붙은 기기가 있는지"를 1회 조회한다.
/// `ref.refresh(wearableConnectionProvider)`로 재확인할 수 있다.
final wearableConnectionProvider = FutureProvider<String?>((ref) {
  return ref.watch(wearableMetricsSourceProvider).latestDeviceName();
});

/// **GPS 트래킹 엔진.** UI는 보통 [trackingControllerProvider]를 쓰고,
/// 직접 이 provider를 구독할 일은 스트림 두 개를 꺼낼 때뿐이다.
final runTrackingServiceProvider = Provider<RunTrackingService>((ref) {
  final repository = ref.read(runRepositoryProvider);

  final service = GeolocatorRunTrackingService(
    profile: ref.watch(trackingProfileProvider),
    wearableSource: ref.watch(wearableMetricsSourceProvider),
    // 칼로리 추정용 체중은 세션 시작 시점 값을 한 번만 쓴다.
    // watch로 걸면 프로필 갱신이 진행 중 세션을 날려버린다.
    weightKg: ref.read(currentProfileProvider).valueOrNull?.weightKg,
    // 15초마다 진행 중 기록을 로컬에 남긴다 — 강제 종료돼도 여기까지는 산다.
    onCheckpoint: repository.save,
  );

  ref.onDispose(service.dispose);
  return service;
});

/// 진행 중 세션의 누적 상태. 1초마다 갱신된다.
///
/// ```dart
/// final run = ref.watch(activeRunProvider).valueOrNull;
/// Text(run == null ? '0.00' : (run.distanceMeters / 1000).toStringAsFixed(2));
/// ```
final activeRunProvider = StreamProvider<RunRecord>((ref) {
  return ref.watch(runTrackingServiceProvider).sessionStream;
});

/// 새로 채택된 GPS 샘플 하나하나. 지도 폴리라인을 **증분으로** 늘릴 때 쓴다
/// (매 프레임 전체 리스트를 다시 그리지 않기 위해 세션 스트림과 분리돼 있다).
final liveRunSampleProvider = StreamProvider<RunSample>((ref) {
  return ref.watch(runTrackingServiceProvider).sampleStream;
});

/// 러닝 **종료 이벤트 버스**. 뱃지 판정(gamification)과 업로드 후처리가
/// 여기를 구독한다. 이벤트에는 최종 [RunRecord] 전체가 실린다 —
/// 구독 측이 다시 계산할 필요가 없어야 한다(skill §7).
final _runCompletionBusProvider = Provider<StreamController<RunRecord>>((ref) {
  final controller = StreamController<RunRecord>.broadcast();
  ref.onDispose(controller.close);
  return controller;
});

/// 완료된 러닝 스트림. `ref.listen(runCompletedProvider, ...)`로 구독한다.
final runCompletedProvider = StreamProvider<RunRecord>((ref) {
  return ref.watch(_runCompletionBusProvider).stream;
});

/// 앱 재시작 시 복구 가능한 미완결 세션(강제 종료/OS kill 대비).
final interruptedRunProvider = FutureProvider<RunRecord?>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  final repository = ref.watch(runRepositoryProvider);
  if (repository is! LocalRunRepository) return null;
  return repository.findInterrupted(userId);
});

/// 화면이 호출하는 명령 계층. 상태는 "마지막으로 알려진 세션"이며,
/// 아직 시작 전이면 `AsyncData(null)`이다.
///
/// ```dart
/// final controller = ref.read(trackingControllerProvider.notifier);
/// await controller.start();                 // 권한 요청 + 세션 시작
/// await controller.pause();  await controller.resume();
/// final record = await controller.stop();   // 로컬 저장 + 업로드 시도 + 종료 이벤트
/// ```
class TrackingController extends AsyncNotifier<RunRecord?> {
  @override
  Future<RunRecord?> build() async => null;

  RunTrackingService get _service => ref.read(runTrackingServiceProvider);

  /// 권한을 확보하고 새 세션을 시작한다.
  /// 권한 거부 시 `state`가 `AsyncError(Failure.permissionDenied)`가 된다.
  Future<void> start({
    ActivityType type = ActivityType.outdoorRun,
  }) async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) {
      // 라우터 가드가 게스트를 이미 막지만, 명령 계층에서도 방어한다.
      state = AsyncError(
        const Failure.unauthorized(message: '로그인이 필요합니다.'),
        StackTrace.current,
      );
      return;
    }

    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _service.ensureReady();
      return _service.start(userId: userId, type: type);
    });
  }

  Future<void> pause() => _service.pause();
  Future<void> resume() => _service.resume();

  /// 세션을 끝내고 **로컬에 먼저 저장한 뒤** 업로드를 시도한다.
  /// 저장이 끝난 다음에야 종료 이벤트를 발행한다 — 뱃지 판정이 아직 저장되지
  /// 않은 기록을 보고 판단하는 상황을 막기 위해서다.
  Future<RunRecord?> stop() async {
    final record = await _service.stop();
    await ref.read(runRepositoryProvider).save(record);
    state = AsyncData(record);

    final bus = ref.read(_runCompletionBusProvider);
    if (!bus.isClosed) bus.add(record);
    return record;
  }

  Future<void> discard() async {
    final current = state.valueOrNull;
    await _service.discard();
    if (current != null) {
      // 체크포인트로 이미 로컬에 남았을 수 있다 — 흔적을 지운다.
      await ref.read(runRepositoryProvider).delete(current.id);
    }
    state = const AsyncData(null);
  }
}

final trackingControllerProvider =
    AsyncNotifierProvider<TrackingController, RunRecord?>(
  TrackingController.new,
);

/// [LocalRunRepository] 조립. `core/providers/repository_providers.dart`의
/// `runRepositoryProvider`가 이 함수를 쓴다.
LocalRunRepository buildLocalRunRepository(Ref ref) {
  return LocalRunRepository(
    ref.watch(localRunDatabaseProvider),
    ref.watch(supabaseClientProvider),
  );
}
