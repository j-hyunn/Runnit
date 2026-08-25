import 'dart:async';

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
/// 연결 상태를 직접 감지하는 패키지(connectivity_plus 등)를 새로 추가하는
/// 대신, 이미 있는 신호 3가지로 "재시도해볼 만한 시점"을 충분히 커버한다:
/// 1. 로그인 성공 시 — 러닝은 로그인 사용자만 하므로 재시도 대상이 생기는 시점.
/// 2. 앱이 백그라운드→포그라운드로 돌아올 때 — 신호 없다가 회복되는 가장
///    흔한 패턴(러닝 종료 직후 신호 끊김 → 나중에 앱을 다시 열었을 때).
/// 3. 앱이 켜져 있는 동안의 주기 폴백(2분) — 앱을 안 끄고 계속 대기 중인
///    경우까지 커버.
///
/// [RunnitApp]이 시작 시 `ref.watch`로 한 번 읽어 앱 전체 수명 동안 살아있게
/// 한다(autoDispose가 아니므로 한 번 생성되면 계속 유지된다).
class RunSyncCoordinator {
  RunSyncCoordinator(this._ref) {
    _lifecycleListener = AppLifecycleListener(onResume: _trySync);
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => _trySync());

    _ref.listen<String?>(currentUserIdProvider, (previous, next) {
      if (previous == null && next != null) _trySync();
    });
    if (_ref.read(currentUserIdProvider) != null) _trySync();

    _ref.onDispose(() {
      _timer.cancel();
      _lifecycleListener.dispose();
    });
  }

  final Ref _ref;
  late final Timer _timer;
  late final AppLifecycleListener _lifecycleListener;
  bool _syncing = false;

  Future<void> _trySync() async {
    // 중복 실행 방지(예: 앱 복귀와 주기 타이머가 겹치는 경우) + 게스트는 대상 없음.
    if (_syncing || _ref.read(currentUserIdProvider) == null) return;
    _syncing = true;
    try {
      await _ref.read(runRepositoryProvider).syncPending();
    } catch (_) {
      // 실패해도 무해하다 — 다음 재시도 시점(로그인/복귀/2분 주기)에 다시 시도한다.
    } finally {
      _syncing = false;
    }
  }
}

final runSyncCoordinatorProvider = Provider<RunSyncCoordinator>((ref) {
  return RunSyncCoordinator(ref);
});
