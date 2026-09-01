import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

/// Android 배터리 최적화 **예외** 요청 (PRD TR-02 신뢰성 / A-6 리스크 R-2).
///
/// ## 왜 필요한가
/// 포그라운드 서비스와 상시 알림만으로는 부족하다. 샤오미·화웨이·오포·일부
/// 삼성 기기는 OEM 전력 관리가 그 위에 한 겹 더 있어서, 화면이 꺼진 채
/// 수십 분이 지나면 포그라운드 서비스째로 재우거나 죽인다. 그러면 60분
/// 러닝의 뒷부분이 통째로 비고(TR-02 수용 기준 "데이터 손실 0" 위반),
/// 사용자에게는 "앱이 거리를 덜 셌다"로만 보인다.
///
/// `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 예외를 받아두면 표준 Doze는 확실히
/// 빠지고, OEM 전력 관리에도 대부분 같은 화이트리스트가 쓰인다. **보장은
/// 아니다** — OEM 자체 설정(예: MIUI "자동 시작")은 별도이며 코드로 열 수 없다.
///
/// ## 물어보는 규칙 (소음을 만들지 않는다)
/// - Android에서만 동작한다. iOS에는 대응 개념이 없다.
/// - 이미 예외를 받았으면 아무것도 하지 않는다.
/// - **한 번 물어보고 끝이다.** 거부한 사용자에게 러닝마다 같은 시스템
///   다이얼로그를 띄우는 것은 설득이 아니라 소음이다
///   (알림 권한 프라이밍과 같은 원칙 — `notification_permission_primer.dart`).
/// - 실패·예외는 삼킨다. 이 요청 때문에 러닝이 시작되지 않으면 안 된다.
///
/// 호출 시점은 `GeolocatorRunTrackingService.ensureReady()`의 **맨 끝**,
/// 즉 "항상 허용" 위치 권한까지 받은 뒤다. 그 조합이어야 사용자가 다이얼로그의
/// 맥락("백그라운드에서 계속 기록")을 이해한다.
class BatteryOptimizationGuard {
  const BatteryOptimizationGuard();

  static const String _askedKey = 'runnit.tracking.battery_opt_asked';

  /// 예외가 이미 적용돼 있으면 true. 요청 결과가 승인이면 true.
  /// 물어보지 않았거나 거부·실패면 false.
  Future<bool> ensureExempted() async {
    if (!Platform.isAndroid) return true;

    try {
      if (await ph.Permission.ignoreBatteryOptimizations.isGranted) return true;

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_askedKey) ?? false) return false;

      // 물어봤다는 사실을 **요청 전에** 적는다. 요청 도중 앱이 죽어도
      // 다음 러닝에서 같은 다이얼로그가 다시 뜨지 않게 하기 위해서다.
      await prefs.setBool(_askedKey, true);

      final status = await ph.Permission.ignoreBatteryOptimizations.request();
      return status.isGranted;
    } catch (_) {
      // 권한이 매니페스트에 없거나 OEM이 인텐트를 막은 기기 등.
      // 트래킹은 그대로 진행한다(포그라운드 서비스만으로도 대부분 동작한다).
      return false;
    }
  }
}
