import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Firebase(=FCM) 초기화 경계.
///
/// ## 설정 파일이 없어도 앱은 떠야 한다
/// `Firebase.initializeApp()`은 네이티브 설정 파일
/// (`android/app/google-services.json` / `ios/Runner/GoogleService-Info.plist`)이
/// 없으면 예외를 던진다. 그 예외가 `main()`을 뚫고 나가면 **FCM 프로젝트를 아직
/// 만들지 않은 개발 환경에서 앱 전체가 기동하지 않는다.** 지도 초기화
/// (`initializeNaverMap`)와 같은 규약으로 여기서 삼킨다 — 푸시만 조용히 꺼지고
/// 나머지(알림함·설정 화면 포함)는 그대로 동작한다.
///
/// 알림함은 `notifications` 테이블을 읽는 화면이라 FCM과 무관하게 동작한다.
/// 즉 **푸시 없이도 놓친 알림을 볼 수 있다** — architect §1.2가 인박스를 만든
/// 이유가 이것이다.
bool _initialized = false;

/// FCM SDK를 실제로 쓸 수 있는가. false면 토큰 등록·메시지 수신 경로는 전부
/// no-op이 된다(에러가 아니라 부재로 다룬다).
bool get isFirebaseAvailable => _initialized;

/// `main()`에서 `runApp` 이전에 한 번 호출한다. **절대 예외를 던지지 않는다.**
Future<void> initializeFirebase() async {
  if (_initialized) return;
  try {
    await Firebase.initializeApp();
    _initialized = true;
  } catch (error) {
    _initialized = false;
    debugPrint(
      '[firebase] 초기화를 건너뜁니다(푸시 비활성): $error\n'
      '  → google-services.json / GoogleService-Info.plist 를 넣으면 활성화됩니다.',
    );
  }
}

/// 테스트 전용 — 위젯 테스트가 Firebase 없이도 코드 경로를 타게 한다.
@visibleForTesting
void debugSetFirebaseAvailable(bool value) => _initialized = value;
