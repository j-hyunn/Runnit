import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/models.dart';
import '../auth/auth_providers.dart';
import '../providers/repository_providers.dart';
import 'firebase_bootstrap.dart';
import 'push_permission.dart';

/// FCM 토큰 ↔ 로그인 계정 수명주기 동기화.
///
/// **화면이 아니라 앱 수명주기에 붙는다.** 이 일을 알림 feature가 소유하면
/// 알림 화면에 한 번도 들어가지 않은 사용자는 토큰이 등록되지 않아 푸시를
/// 영영 받지 못한다(ARCHITECTURE §7.5.3).
///
/// | 사건 | 동작 |
/// |---|---|
/// | 로그인 완료 | 권한 확인 → `getToken()` → `register_push_token` RPC |
/// | `onTokenRefresh` | 새 토큰 재등록(같은 `device_id`의 옛 토큰은 서버가 정리) |
/// | 로그아웃 | `push_tokens` 행 삭제 + **FCM 토큰 자체 폐기** |
/// | 권한 거부 | 등록하지 않는다. 알림함·설정 화면은 그대로 동작한다 |
///
/// ## 로그아웃에서 FCM 토큰까지 지우는 이유
/// 서버 행 삭제는 세션이 이미 끊긴 뒤라 RLS에 막혀 실패할 수 있다. 그 경우에도
/// `FirebaseMessaging.deleteToken()`이 토큰을 무효화하면 이전 사용자 앞으로 남은
/// 행은 발송 시 `UNREGISTERED`를 받아 서버가 스스로 지운다 — **기기를 넘겨받은
/// 사람에게 이전 사용자의 순위·티어 알림이 가는 사고**를 막는 두 번째 방어선이다.
/// 어느 쪽이 실패해도 로그아웃 자체를 막지 않는다.
class PushTokenSync {
  PushTokenSync(this._ref);

  final Ref _ref;
  StreamSubscription<String>? _refreshSub;
  String? _userId;
  String? _token;

  void start() {
    _ref.listen<String?>(
      currentUserIdProvider,
      _onUserChanged,
      fireImmediately: true,
    );

    if (isFirebaseAvailable) {
      _refreshSub =
          FirebaseMessaging.instance.onTokenRefresh.listen(_onTokenRefresh);
    }
  }

  void _onUserChanged(String? previous, String? next) {
    if (previous == next) return;
    if (previous != null) unawaited(_unregister());
    _userId = next;
    if (next != null) unawaited(registerNow());
  }

  void _onTokenRefresh(String token) {
    _token = token;
    final userId = _userId;
    if (userId != null) unawaited(_upsert(userId, token));
  }

  /// 권한을 갓 승인받은 직후(프라이밍 카드)처럼 **등록을 다시 시도해야 하는**
  /// 지점에서 호출한다. 이미 등록돼 있으면 같은 값을 한 번 더 쓸 뿐이다.
  Future<void> registerNow() async {
    final userId = _userId;
    if (userId == null || !isFirebaseAvailable) return;

    // 권한이 없으면 토큰을 받아도 발송이 도달하지 않는다. 등록 자체를 미룬다.
    final status = await _ref.read(pushPermissionStatusProvider.future);
    if (!status.isGranted) return;

    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      _token = token;
      await _upsert(userId, token);
    } catch (error) {
      // 토큰 획득 실패는 다음 실행에서 자연 복구된다 — 사용자에게 보여줄
      // 것도, 재시도 루프를 돌릴 것도 없다.
      debugPrint('[push] 토큰 등록 실패: $error');
    }
  }

  Future<void> _upsert(String userId, String token) async {
    try {
      await _ref.read(notificationRepositoryProvider).upsertToken(
            PushDeviceToken(
              token: token,
              userId: userId,
              platform: _platform(),
              deviceId: await _deviceId(),
              // 앱 버전은 진단용 선택 필드다. package_info_plus를 이 하나
              // 때문에 추가하지 않는다 — 없으면 서버가 null로 둔다.
              appVersion: null,
            ),
          );
    } catch (error) {
      debugPrint('[push] 토큰 upsert 실패: $error');
    }
  }

  Future<void> _unregister() async {
    final token = _token;
    _token = null;
    if (token != null) {
      try {
        await _ref.read(notificationRepositoryProvider).deleteToken(token);
      } catch (error) {
        debugPrint('[push] 토큰 삭제 실패(무시): $error');
      }
    }
    if (!isFirebaseAvailable) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (error) {
      debugPrint('[push] FCM 토큰 폐기 실패(무시): $error');
    }
  }

  DevicePlatform _platform() =>
      Platform.isIOS ? DevicePlatform.ios : DevicePlatform.android;

  /// 설치 단위 식별자. 토큰이 회전해도 유지되므로 서버가 **같은 기기의 옛
  /// 토큰**을 정리하는 근거가 된다. 저장 실패 시 null(그 경우 정리는 발송
  /// 실패에만 의존한다 — 모델 주석 참조).
  Future<String?> _deviceId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getString(_deviceIdKey);
      if (existing != null) return existing;
      final created = const Uuid().v4();
      await prefs.setString(_deviceIdKey, created);
      return created;
    } catch (error) {
      debugPrint('[push] device_id 확보 실패: $error');
      return null;
    }
  }

  static const _deviceIdKey = 'runnit.push.device_id';

  void dispose() => unawaited(_refreshSub?.cancel());
}

/// 앱 수명 동안 하나. `app.dart`가 `ref.watch`로 살려 둔다.
final pushTokenSyncProvider = Provider<PushTokenSync>((ref) {
  final sync = PushTokenSync(ref);
  ref.onDispose(sync.dispose);
  sync.start();
  return sync;
});
