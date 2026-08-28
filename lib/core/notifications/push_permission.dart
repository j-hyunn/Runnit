import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import 'firebase_bootstrap.dart';

/// OS 알림 권한 상태.
///
/// `permission_handler`가 아니라 **FirebaseMessaging**을 상태 조회의 출처로
/// 쓴다. iOS에서 `Permission.notification.status`는 "아직 안 물어봄"과 "거부함"을
/// 둘 다 `denied`로 돌려주는데, 이 앱은 그 둘을 반드시 구분해야 하기 때문이다 —
/// [notDetermined]에서만 프라이밍 카드를 띄우고, [denied]에서는 시스템 설정으로
/// 보내야 한다. 여기서 잘못 구분하면 이미 거부한 사용자에게 매 러닝마다 같은
/// 카드를 다시 보여주게 된다.
enum PushPermissionStatus {
  /// 아직 한 번도 묻지 않았다. **프라이밍을 띄울 수 있는 유일한 상태.**
  notDetermined,

  /// 승인됨(iOS provisional 포함 — 조용한 알림이라도 전달은 된다).
  granted,

  /// 거부됨. 앱은 되돌릴 수 없고 시스템 설정으로 안내하는 수밖에 없다.
  denied,

  /// FCM 설정 파일이 없어 푸시 경로 자체가 없는 빌드
  /// ([isFirebaseAvailable] 참조). 권한을 물을 대상이 없으므로 안내도 하지 않는다.
  unavailable,
}

extension PushPermissionStatusX on PushPermissionStatus {
  bool get isGranted => this == PushPermissionStatus.granted;

  /// 설정 화면에 "OS 알림이 꺼져 있어요" 안내를 띄워야 하는가.
  /// [PushPermissionStatus.unavailable]에는 띄우지 않는다 — 사용자가 할 수 있는
  /// 일이 없는 안내는 소음이다.
  bool get needsSystemSettings => this == PushPermissionStatus.denied;
}

/// 현재 OS 알림 권한. 앱 복귀 후 다시 읽으려면 `ref.invalidate`한다.
final pushPermissionStatusProvider =
    FutureProvider<PushPermissionStatus>((ref) async {
  if (!isFirebaseAvailable) return PushPermissionStatus.unavailable;
  try {
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    return _map(settings.authorizationStatus);
  } catch (error) {
    debugPrint('[push] 권한 상태 조회 실패: $error');
    return PushPermissionStatus.unavailable;
  }
});

/// OS 권한 요청. **호출 시점은 첫 러닝 완료 직후 하나뿐**이다(architect §1.3) —
/// 첫 실행 다이얼로그는 거부율이 높고, 한 번 거부되면 앱이 되돌릴 수 없다.
///
/// 요청 후 상태 provider를 무효화해 화면이 즉시 새 상태를 그리게 한다.
Future<PushPermissionStatus> requestPushPermission(WidgetRef ref) async {
  if (!isFirebaseAvailable) return PushPermissionStatus.unavailable;
  try {
    final settings = await FirebaseMessaging.instance.requestPermission();
    return _map(settings.authorizationStatus);
  } catch (error) {
    debugPrint('[push] 권한 요청 실패: $error');
    return PushPermissionStatus.unavailable;
  } finally {
    ref.invalidate(pushPermissionStatusProvider);
  }
}

/// 시스템 설정 앱의 이 앱 페이지를 연다(거부 상태에서의 유일한 복구 경로).
Future<void> openSystemNotificationSettings() => ph.openAppSettings();

PushPermissionStatus _map(AuthorizationStatus status) => switch (status) {
      AuthorizationStatus.authorized ||
      // provisional = iOS의 "조용한 알림" 승인. 전달은 되므로 granted로 본다.
      AuthorizationStatus.provisional =>
        PushPermissionStatus.granted,
      AuthorizationStatus.denied ||
      // Android 13+에서 두 번 거부하면 OS가 더 이상 프롬프트를 띄우지 않는다.
      // 앱 입장에서 할 수 있는 일은 denied와 같다 — 시스템 설정 안내.
      AuthorizationStatus.deniedPermanently =>
        PushPermissionStatus.denied,
      AuthorizationStatus.notDetermined => PushPermissionStatus.notDetermined,
    };
