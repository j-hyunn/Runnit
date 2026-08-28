/// 앱 내부 좌표 모델 ↔ 지도 SDK 좌표 타입 **변환 경계**.
///
/// Runnit의 내부 표준 좌표는 `latlong2`의 [LatLng]다. 공유 카드
/// (`sharing/domain/share_card_builder.dart`), 경로 디코딩
/// (`tracking/domain/polyline_codec.dart`), 히스토리 경로 provider 등
/// 도메인 전반이 이 타입에 묶여 있으므로, 지도 SDK를 바꿀 때 도메인 코드가
/// 흔들리지 않도록 **변환은 오직 지도 위젯 경계에서만** 일어난다.
///
/// 즉, `NLatLng`는 이 파일과 `lib/core/map/*`, 그리고 지도 위젯
/// (`run_map_view.dart` / `run_route_map.dart`) 밖으로 새어 나가지 않는다.
/// 나중에 다른 SDK로 교체하면 이 파일과 [MapSurfaceBuilder] 구현만 갈아끼운다.
library;

import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:latlong2/latlong.dart';

extension AppLatLngToNaver on LatLng {
  /// 앱 내부 좌표 → 네이버 지도 좌표.
  NLatLng toNaver() => NLatLng(latitude, longitude);
}

extension AppLatLngListToNaver on Iterable<LatLng> {
  /// 경로 전체를 네이버 좌표 리스트로 옮긴다.
  List<NLatLng> toNaverCoords() =>
      <NLatLng>[for (final p in this) NLatLng(p.latitude, p.longitude)];

  /// 경로를 감싸는 최소 사각 영역. 점이 없으면 `null`.
  NLatLngBounds? toNaverBounds() {
    final coords = toNaverCoords();
    if (coords.isEmpty) return null;
    return NLatLngBounds.from(coords);
  }
}

extension NaverLatLngToApp on NLatLng {
  /// 네이버 지도 좌표 → 앱 내부 좌표.
  LatLng toApp() => LatLng(latitude, longitude);
}
