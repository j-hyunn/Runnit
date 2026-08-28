/// 네이버 지도 SDK 초기화 (PRD §7 — 지도 SDK는 Naver Map).
///
/// `flutter_naver_map` 1.3.1+는 **Dart에서 한 번 초기화**하는 방식이다
/// (AndroidManifest `meta-data` / iOS `AppDelegate`에 키를 심던 구 방식은
/// 레거시 인증 API 전용이고, 2025-07-01부터 무료 이용량이 끊겼다).
/// 그래서 클라이언트 ID는 이 파일 한 곳에만 존재한다.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';

/// NCP(Naver Cloud Platform) Maps 애플리케이션의 Client ID.
///
/// ⚠️ **배포 전 반드시 실제 키로 교체해야 한다.**
/// NCP 콘솔 > Services > Application Services > Maps > Application 등록
/// (Dynamic Map 선택, Android 패키지명 `com.runnit.runnit` / iOS Bundle ID 등록)
/// 후 "인증정보"의 Client ID를 여기에 넣거나,
/// `--dart-define=NAVER_MAP_CLIENT_ID=xxxx`로 주입한다.
const String naverMapClientId = String.fromEnvironment(
  'NAVER_MAP_CLIENT_ID',
  // NCP 콘솔 > Application Services > Maps 에서 발급한 Client ID.
  // 클라이언트 ID는 앱 바이너리에 포함되는 값이라 비밀이 아니다(도메인/번들 ID로
  // 사용이 제한된다). 키 로테이션이 필요하면 --dart-define 으로 덮어쓴다.
  defaultValue: 'aiwnlgolgp',
);

/// 클라이언트 ID가 아직 플레이스홀더인지.
///
/// 키가 없으면 인증이 실패하고 지도는 회색으로 남는다. 앱의 나머지 기능
/// (트래킹·기록·랭킹)은 지도와 무관하게 동작해야 하므로 **초기화 실패로
/// 앱을 죽이지 않는다**.
bool get isNaverMapClientIdConfigured =>
    naverMapClientId != 'YOUR_NAVER_MAP_CLIENT_ID' && naverMapClientId.isNotEmpty;

/// 첫 `NaverMap` 위젯이 그려지기 전에 반드시 한 번 실행돼야 한다.
Future<void> initializeNaverMap() async {
  if (!isNaverMapClientIdConfigured) {
    debugPrint(
      '[NaverMap] Client ID가 플레이스홀더입니다. NCP 콘솔에서 발급한 키로 '
      '교체하거나 --dart-define=NAVER_MAP_CLIENT_ID=... 로 주입하세요. '
      '지도는 인증 실패로 표시되지 않습니다.',
    );
  }

  // 초기화는 네이티브 플러그인 채널을 탄다 — 플러그인이 등록되지 않은 환경
  // (`MissingPluginException`)이나 네이티브 초기화 실패(`PlatformException`)에서
  // 던지는 예외가 `main()`까지 올라가면 **`runApp()` 전에 앱이 죽는다.**
  // 지도는 트래킹·기록·랭킹의 전제 조건이 아니므로, 실패하면 지도만 포기하고
  // 나머지는 정상 동작시킨다(파일 상단 계약).
  try {
    await FlutterNaverMap().init(
      clientId: naverMapClientId,
      onAuthFailed: (ex) {
        // 인증 실패를 조용히 넘기면 "지도가 왜 회색이지?"로 시간을 날린다.
        switch (ex) {
          case NQuotaExceededException(:final message):
            debugPrint('[NaverMap] 사용량 초과: $message');
          default:
            debugPrint('[NaverMap] 인증 실패: $ex');
        }
      },
    );
  } catch (error, stack) {
    debugPrint(
      '[NaverMap] SDK 초기화 실패 — 지도는 표시되지 않지만 트래킹·기록·랭킹은 '
      '그대로 동작합니다: $error',
    );
    debugPrintStack(stackTrace: stack, label: '[NaverMap]');
  }
}
