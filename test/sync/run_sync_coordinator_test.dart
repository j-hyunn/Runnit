import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/providers/repository_providers.dart';
import 'package:runnit/core/repositories/run_repository.dart';
import 'package:runnit/core/sync/run_sync_coordinator.dart';
import 'package:runnit/models/models.dart';

/// [RunSyncCoordinator]의 발화 조건 계약.
///
/// 코디네이터는 **로그인 전이 / 앱 복귀 / 2분 주기 / 연결 회복** 네 신호로
/// 재시도를 건다. 이 테스트가 잠그는 것은 그중 코드로 관찰 가능한 것들이다:
/// - 게스트에게는 발화하지 않는다(재시도 대상이 없다).
/// - 이미 도는 동기화가 있으면 중복 발화하지 않는다(복귀+타이머 겹침).
/// - 오프라인→온라인 전환에서 발화한다.
/// - 현재 로그인 사용자로 좁혀 호출한다(계정 전환 시 이전 계정 행 배제, QA C-5).
void main() {
  final StateProvider<String?> userId = StateProvider<String?>((_) => null);

  late _FakeRunRepository repository;
  late StreamController<void> connectivity;
  late ProviderContainer container;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    repository = _FakeRunRepository();
    connectivity = StreamController<void>.broadcast();
    container = ProviderContainer(
      overrides: <Override>[
        runRepositoryProvider.overrideWithValue(repository),
        currentUserIdProvider.overrideWith((Ref ref) => ref.watch(userId)),
        // 실제 연결 감지(connectivity_plus)는 플랫폼 채널이라 테스트에서
        // 수동 스트림으로 갈아 끼운다.
        connectivityRestoredProvider.overrideWithValue(connectivity.stream),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    connectivity.close();
  });

  /// Riverpod의 리스너 통지 + 코디네이터의 비동기 호출이 자리 잡을 시간을 준다.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void login(String? id) => container.read(userId.notifier).state = id;

  test('게스트 상태로 시작하면 동기화를 시도하지 않는다', () async {
    container.read(runSyncCoordinatorProvider);
    await settle();

    expect(repository.syncCalls, 0);
  });

  test('이미 로그인된 상태로 시작하면 즉시 한 번 동기화한다', () async {
    login('user-1');
    container.read(runSyncCoordinatorProvider);
    await settle();

    expect(repository.syncCalls, 1);
  });

  test('게스트 → 로그인 전이에서 동기화가 발화한다', () async {
    container.read(runSyncCoordinatorProvider);
    await settle();
    expect(repository.syncCalls, 0);

    login('user-1');
    await settle();
    expect(repository.syncCalls, 1);
  });

  test('동기화가 도는 동안의 중복 발화는 무시된다', () async {
    repository.hold = true; // syncPending()이 아직 끝나지 않은 상태로 붙잡는다
    login('user-1');
    container.read(runSyncCoordinatorProvider);
    await settle();
    expect(repository.syncCalls, 1);

    // 로그아웃 → 재로그인(= 두 번째 발화 신호). 진행 중이므로 무시돼야 한다.
    login(null);
    await settle();
    login('user-2');
    await settle();
    expect(repository.syncCalls, 1, reason: '재진입 방지 래치');

    // 앞선 요청이 끝나면 다시 발화할 수 있다.
    repository.release();
    await settle();
    login(null);
    await settle();
    login('user-3');
    await settle();
    expect(repository.syncCalls, 2);
  });

  test('실패한 동기화는 삼켜지고 다음 신호에서 재시도된다', () async {
    repository.throwOnSync = true;
    login('user-1');
    container.read(runSyncCoordinatorProvider);
    await settle();
    expect(repository.syncCalls, 1);

    repository.throwOnSync = false;
    login(null);
    await settle();
    login('user-2');
    await settle();
    expect(repository.syncCalls, 2, reason: '예외가 래치를 걸어 두면 안 된다');
  });

  test('타임아웃으로 끝난 동기화 뒤에도 다음 신호가 발화한다', () async {
    // `LocalRunRepository.uploadTimeout`이 걸리면 `syncPending()`은 정상 반환
    // 하거나(건별로 failed 처리) TimeoutException을 던지며 끝난다. 어느 쪽이든
    // 래치가 풀려야 한다 — 이것이 C-3 수정의 코디네이터 측 계약이다.
    repository.timeoutOnSync = true;
    login('user-1');
    container.read(runSyncCoordinatorProvider);
    await settle();
    expect(repository.syncCalls, 1);

    repository.timeoutOnSync = false;
    connectivity.add(null);
    await settle();
    expect(repository.syncCalls, 2, reason: '타임아웃이 래치를 걸어 두면 안 된다');
  });

  test('오프라인 → 온라인 전환에서 동기화가 발화한다', () async {
    login('user-1');
    container.read(runSyncCoordinatorProvider);
    await settle();
    expect(repository.syncCalls, 1);

    connectivity.add(null);
    await settle();
    expect(repository.syncCalls, 2);
  });

  test('현재 로그인 사용자로 좁혀 호출한다', () async {
    login('user-1');
    container.read(runSyncCoordinatorProvider);
    await settle();

    expect(repository.lastUserIds, <String?>['user-1']);
  });

  test('[특성] 코디네이터 래치 자체에는 워치독이 없다', () async {
    // 끝나지 않는 `syncPending()`은 여전히 이후 발화를 막는다. 그 상황을 막는
    // 장치는 코디네이터가 아니라 한 계층 아래의 요청 타임아웃
    // (`LocalRunRepository.uploadTimeout`, `offline_sync_test.dart`)이다.
    // 여기서 워치독을 또 두면 같은 기록을 두 번 밀어 올리게 된다.
    repository.hold = true;
    login('user-1');
    container.read(runSyncCoordinatorProvider);
    await settle();

    for (var i = 0; i < 5; i++) {
      login(null);
      await settle();
      login('user-$i');
      await settle();
    }

    expect(repository.syncCalls, 1);
    repository.release();
  });
}

class _FakeRunRepository implements RunRepository {
  int syncCalls = 0;
  bool throwOnSync = false;
  bool timeoutOnSync = false;

  /// 호출마다 넘어온 `userId`. 계정 전환 필터(C-5) 검증용.
  final List<String?> lastUserIds = <String?>[];

  /// true면 `syncPending()`이 [release] 전까지 완료되지 않는다.
  bool hold = false;
  Completer<void>? _gate;

  void release() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<int> syncPending({String? userId}) async {
    syncCalls += 1;
    lastUserIds.add(userId);
    if (throwOnSync) throw StateError('network down');
    if (timeoutOnSync) throw TimeoutException('upload stalled');
    if (hold) {
      _gate = Completer<void>();
      await _gate!.future;
    }
    return 0;
  }

  @override
  Future<void> save(RunRecord record) async {}

  @override
  Future<void> delete(String id) async {}

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
  Future<RunMeta> updateMeta(String id, {String? title, String? note}) async =>
      const RunMeta();
}
