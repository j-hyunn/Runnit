/// 지도 **표면(플랫폼 뷰) 주입점**과, 두 지도 위젯이 공유하는 스타일·오버레이 규칙.
///
/// ## 왜 위젯을 직접 쓰지 않고 한 겹 감싸는가
/// 1. **교체 여지** — PRD §7이 확정한 `flutter_naver_map`은 국내 지도 품질 때문에
///    고른 것이고, 글로벌 확장 시점에는 다른 SDK로 갈아끼워야 한다
///    (ARCHITECTURE §12-#2). 화면 코드가 `NaverMap` 위젯을 직접 부르면 교체
///    지점이 화면 수만큼 늘어난다. 지도 표면 생성을 [mapSurfaceBuilderProvider]
///    하나로 모아 두면 교체 대상이 이 파일 + [MapSurfaceSpec] 변환뿐이다.
/// 2. **테스트** — `NaverMap.build()`는 `assert(FlutterNaverMap.isInitialized)`로
///    시작한다. 위젯 테스트에는 NCP 클라이언트 ID도, 네이티브 뷰도 없으므로
///    이 provider를 [stubMapSurfaceBuilder]로 override해 지도 자리를 빈 상자로
///    대체한다 — 네트워크도 애니메이션도 없어 `pumpAndSettle`이 멈추지 않는다.
///    지도가 붙은 화면(트래킹·기록 상세)의 위젯 테스트는 **반드시** 이 override를
///    깔아야 한다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'map_geo.dart';

/// 지도 표면 하나를 그리는 방법. 화면은 이 함수만 호출한다.
typedef MapSurfaceBuilder = Widget Function(MapSurfaceSpec spec);

/// 지도 표면에 넘길 최소 정보.
///
/// ⚠️ [options]는 **인스턴스를 캐시해서** 넘길 것. `NaverMapViewOptions`는
/// `==`를 재정의하지 않아, 매 빌드마다 새로 만들면 값이 같아도 옵션 갱신
/// 메시지가 네이티브로 계속 날아간다.
@immutable
class MapSurfaceSpec {
  const MapSurfaceSpec({required this.options, this.onMapReady});

  final NaverMapViewOptions options;

  /// 지도를 조작할 수 있게 된 첫 시점. 테스트 스텁에서는 **호출되지 않는다** —
  /// 호출부는 이 콜백이 영영 오지 않아도 화면이 성립하도록 짜야 한다.
  final void Function(NaverMapController controller)? onMapReady;
}

/// 실제 네이버 지도 표면.
Widget naverMapSurfaceBuilder(MapSurfaceSpec spec) => NaverMap(
      options: spec.options,
      onMapReady: spec.onMapReady,
    );

/// 위젯 테스트용 표면. 네이티브 뷰도, 네트워크도, 애니메이션도 없어
/// `pumpAndSettle`이 멈추지 않는다.
Widget stubMapSurfaceBuilder(MapSurfaceSpec spec) =>
    const ColoredBox(color: Color(0xFFE9ECEF));

/// 지도 표면 주입점. 테스트에서 [stubMapSurfaceBuilder]로 override한다.
final mapSurfaceBuilderProvider =
    Provider<MapSurfaceBuilder>((ref) => naverMapSurfaceBuilder);

/// 두 지도 위젯이 공유하는 경로 표현 규칙.
///
/// 트래킹 지도와 기록 상세 지도가 같은 경로를 다른 색·다른 두께로 그리면
/// 사용자는 둘을 다른 데이터로 읽는다. 여기 모아 두고 굵기만 달리한다.
abstract final class RunMapStyle {
  const RunMapStyle._();

  /// 진행 중 경로 — 손가락으로 가려져도 보이도록 조금 더 굵다.
  static const double liveStrokeWidth = 6;

  /// 완결 러닝의 정적 경로.
  static const double staticStrokeWidth = 5;

  /// 회전·기울기를 잠근 기본 옵션.
  ///
  /// 달리는 중에 지도가 돌아가면 방향 감각이 무너지고, 기울기(3D)는 경로
  /// 판독을 방해하기만 한다. 스크롤·줌만 남긴다.
  static NaverMapViewOptions baseOptions({
    required NCameraPosition initialCameraPosition,
    double maxZoom = NaverMapViewOptions.maximumZoom,
    bool scaleBarEnable = true,
    double lightness = 0,
    EdgeInsets contentPadding = EdgeInsets.zero,
  }) {
    return NaverMapViewOptions(
      initialCameraPosition: initialCameraPosition,
      rotationGesturesEnable: false,
      tiltGesturesEnable: false,
      scrollGesturesEnable: true,
      zoomGesturesEnable: true,
      // 실내 지도 레벨 피커는 러닝 경로 판독에 방해만 된다.
      indoorEnable: false,
      indoorLevelPickerEnable: false,
      scaleBarEnable: scaleBarEnable,
      maxZoom: maxZoom,
      lightness: lightness,
      contentPadding: contentPadding,
    );
  }

  /// 경로 폴리라인. 배경이 밝든 어둡든 읽히도록 흰 테두리 대신
  /// 둥근 캡/조인으로 처리한다 — 네이버 SDK의 폴리라인은 테두리 색을
  /// 따로 받지 않는다.
  static NPolylineOverlay routeLine({
    required String id,
    required List<LatLng> route,
    required Color color,
    required double width,
  }) {
    return NPolylineOverlay(
      id: id,
      coords: route.toNaverCoords(),
      color: color,
      width: width,
      lineCap: NLineCap.round,
      lineJoin: NLineJoin.round,
    );
  }

  /// 현재 위치·출발·도착을 나타내는 원형 마커.
  ///
  /// [NCircleOverlay]는 반경이 **미터** 단위라 줌에 따라 크기가 널뛴다.
  /// 화면상 크기를 고정해야 하므로 [MapDot] 위젯을 이미지로 구워 마커에 얹는다.
  static Future<NMarker> dotMarker({
    required BuildContext context,
    required String id,
    required LatLng point,
    required Color color,
    double diameter = 16,
    double borderWidth = 3,
    bool glow = false,
  }) async {
    // 그림자가 잘리지 않도록 이미지 캔버스를 여유 있게 잡는다.
    final canvas = diameter + (glow ? 12 : 4);
    final icon = await NOverlayImage.fromWidget(
      widget: MapDot(
        diameter: diameter,
        color: color,
        borderWidth: borderWidth,
        glow: glow,
      ),
      size: Size(canvas, canvas),
      context: context,
    );
    return NMarker(
      id: id,
      position: point.toNaver(),
      icon: icon,
      size: Size(canvas, canvas),
      // 좌표가 아이콘 **중심**에 오게 한다(기본값은 하단 중앙).
      anchor: const NPoint(0.5, 0.5),
    );
  }
}

/// 지도 마커로 구워지는 점. 흰 테두리 덕에 어떤 지도 배경에서도 읽힌다.
class MapDot extends StatelessWidget {
  const MapDot({
    super.key,
    required this.diameter,
    required this.color,
    this.borderWidth = 3,
    this.glow = false,
  });

  final double diameter;
  final Color color;
  final double borderWidth;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: borderWidth),
          boxShadow: glow
              ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 8)]
              : null,
        ),
      ),
    );
  }
}
