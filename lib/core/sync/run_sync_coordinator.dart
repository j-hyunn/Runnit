import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_providers.dart';
import '../providers/repository_providers.dart';

/// [LocalRunRepository.save]는 러닝 종료 시 서버 업로드를 **딱 한 번만**
/// 시도한다(지하 주차장에서 끝낸 러닝을 통째로 날리지 않으려고 로컬 저장을
/// 먼저 하고, 업로드 실패는 `save()`의 실패로 취급하지 않는다). 그 한 번이
/// 실패하면 기록은 로컬에 `SyncStatus.failed`로 남는데, `RunRepository`엔
/// 이걸 다시 밀어 올리는 `syncPending()`이 이미 있지만 **앱 어디서도 부르지
/// 않았다** — 이 코디네이터가 그 역할이다.
///
/// 재시도 신호는 4가지다(백오프는 없다 — 고정 주기 + 이벤트):
/// 1. 로그인 성공 시 — 러닝은 로그인 사용자만 하므로 재시도 대상이 생기는 시점.
/// 2. 앱이 백그라운드→포그라운드로 돌아올 때 — 신호 없다가 회복되는 가장
///    흔한 패턴(러닝 종료 직후 신호 끊김 → 나중에 앱을 다시 열었을 때).
/// 3. 앱이 켜져 있는 동안의 주기 폴백(2분) — 앱을 안 끄고 계속 대기 중인
///    경우까지 커버.
/// 4. 오프라인 → 온라인 전환([connectivityRestoredProvider], QA C-9) — 앱이 켜져
///    있는데 신호만 돌아온 경우를 최대 2분 기다리지 않고 즉시 잡는다.
///
/// ⚠️ **앱이 살아 있어야만 동작한다.** 백그라운드 동기화(WorkManager /
/// BGTaskScheduler)는 아직 없으므로, 러닝을 끝내고 앱을 다시 열지 않은 사용자의
/// 기록은 로컬에만 남는다(데이터 손실은 아니다). TR-08의 "복귀 시 자동 동기화"는
/// 이 전제 위에서 성립한다.
/// TODO(sync): 백그라운드 동기화 도입 검토 — workmanager(Android) /
/// BGTaskScheduler(iOS). 범위·배터리 영향 판단이 필요해 이번 작업에서는 제외했다.
///
/// [RunnitApp]이 시작 시 `ref.watch`로 한 번 읽어 앱 전체 수명 동안 살아있게
/// 한다(autoDispose가 아니므로 한 번 생성되면 계속 유지된다).
class RunSyncCoordinator {
  RunSyncCoordinator(this._ref) {
    _lifecycleListener = AppLifecycleListener(onResume: _trySync);
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _trySync());

    // 연결 감지는 **보조 신호**다. 실패해도(플러그인 없음 등) 나머지 3신호로
    // 동작해야 하므로 에러를 삼킨다.
    _connectivity = _ref
        .read(connectivityRestoredProvider)
        .listen((_) => _trySync(), onError: (Object _) {});

    _ref.listen<String?>(currentUserIdProvider, (previous, next) {
      if (previous == null && next != null) _trySync();
    });
    if (_ref.read(currentUserIdProvider) != null) _trySync();

    _ref.onDispose(() {
      _timer.cancel();
      _lifecycleListener.dispose();
      unawaited(_connectivity.cancel());
    });
  }

  final Ref _ref;
  late final Timer _timer;
  late final AppLifecycleListener _lifecycleListener;
  late final StreamSubscription<void> _connectivity;
  bool _syncing = false;

  Future<void> _trySync() async {
    // 중복 실행 방지(예: 앱 복귀와 주기 타이머가 겹치는 경우) + 게스트는 대상 없음.
    final userId = _ref.read(currentUserIdProvider);
    if (_syncing || userId == null) return;
    _syncing = true;
    try {
      // 현재 로그인 사용자로 좁힌다 — 계정 전환 후 이전 계정 행을 밀어 올려
      // RLS 42501을 무한 반복하지 않기 위해서다(QA C-5).
      await _ref.read(runRepositoryProvider).syncPending(userId: userId);
    } catch (_) {
      // 실패해도 무해하다 — 다음 재시도 시점(로그인/복귀/연결 회복/2분 주기)에
      // 다시 시도한다.
    } finally {
      // 래치는 여기서만 풀린다. 그래서 `syncPending()`이 **반드시 끝나야** 하고,
      // 그 보장은 한 계층 아래 `LocalRunRepository.uploadTimeout`이 한다(QA C-3).
      _syncing = false;
    }
  }
}

/// 오프라인 → 온라인 **전환** 시점만 흘리는 스트림.
///
/// `onConnectivityChanged`는 인터페이스가 바뀔 때마다(와이파이↔셀룰러 등) 값을
/// 내보내므로, 그대로 쓰면 온라인 상태에서도 재시도가 반복 발화한다. 여기서
/// 직전 상태를 기억해 "연결 없음 → 연결 있음"만 통과시킨다.
///
/// ⚠️ 연결됨이 곧 **도달 가능**은 아니다(캡티브 포털). 그래서 이 신호는 기존
/// 3신호를 대체하지 않고 보강만 한다.
///
/// 테스트에서 override할 수 있도록 provider로 분리했다.
final connectivityRestoredProvider = Provider<Stream<void>>((ref) {
  bool online = true; // 앱 시작 직후의 첫 이벤트를 "회복"으로 오인하지 않는다.
  return Connectivity().onConnectivityChanged.where((results) {
    final bool nowOnline =
        results.any((result) => result != ConnectivityResult.none);
    final bool restored = nowOnline && !online;
    online = nowOnline;
    return restored;
  });
});

final runSyncCoordinatorProvider = Provider<RunSyncCoordinator>((ref) {
  return RunSyncCoordinator(ref);
});
