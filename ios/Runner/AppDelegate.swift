import Flutter
import UIKit

// ── 지도(flutter_naver_map / PRD §7) ─────────────────────────────────────
// NCP Client ID는 여기가 아니라 Dart에서 넘긴다 —
// `lib/core/map/naver_map_config.dart`의 `initializeNaverMap()`이
// `FlutterNaverMap().init(clientId: "YOUR_NAVER_MAP_CLIENT_ID")`로
// 네이티브 SDK(NMapsMap)를 초기화한다. (NCP 콘솔에서 발급, 배포 전 교체)
// 1.3.1+ 신규 NCP 인증 방식에서는 Info.plist의 `NMFClientId` /
// AppDelegate 초기화가 필요 없으므로 여기에 키를 심지 말 것 — 중복 선언은
// 레거시 인증 경로를 깨운다.
// iOS 최소 배포 타깃은 12.0 이상이어야 한다(현재 프로젝트는 15.0).

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
