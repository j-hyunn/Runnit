import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/map/map_geo.dart';
import '../../../../core/map/map_surface.dart';
import '../../../../core/theme/app_tokens.dart';

/// 완결된 러닝의 **정적 경로 지도** (HI-02).
///
/// 트래킹 화면의 `RunMapView`가 진행 중 스트림을 따라 카메라를 옮기는 것과
/// 달리, 여기서는 저장된 경로 전체가 한 화면에 들어오도록 지도가 준비된 순간
/// 한 번만 맞춘다(`NCameraUpdate.fitBounds`). 경로 좌표는 이미 계산된 것을
/// 받는다 — `runRoutePointsProvider` 참고. 위젯이 직접 디코딩하면 리빌드마다
/// 폴리라인을 다시 푼다.
///
/// 좌표가 2점 미만이면 [SizedBox.shrink]를 반환한다. 호출부는 그 경우
/// `RunMapUnavailable`로 지도 자리를 대신 채우는 것이 낫다.
class RunRouteMap extends ConsumerStatefulWidget {
  const RunRouteMap({
    super.key,
    required this.route,
    this.height = 240,
  });

  /// 시간 오름차순 경로 좌표.
  final List<LatLng> route;
  final double height;

  /// 출발점 — 앱 강조색(초록).
  static const Color startColor = Color(0xFF00C84B);

  /// 도착점 — 출발점과 헷갈리지 않도록 대비되는 색.
  static const Color finishColor = Color(0xFFE0648E);

  @override
  ConsumerState<RunRouteMap> createState() => _RunRouteMapState();
}

class _RunRouteMapState extends ConsumerState<RunRouteMap> {
  /// 경로 전체가 화면에 들어오게 맞출 때 가장자리에 남길 여백.
  static const EdgeInsets _fitPadding = EdgeInsets.all(AppTokens.s32);

  /// 제자리 러닝처럼 경계 폭이 0에 가까우면 fit이 최대 줌까지 파고들어
  /// 지도가 비어 보인다. 상한을 둬서 막는다.
  static const double _maxZoom = 17;

  bool _drawn = false;

  /// `NaverMapViewOptions`는 `==`를 재정의하지 않는다 — 인스턴스를 캐시하지
  /// 않으면 리빌드마다 옵션 갱신 메시지가 네이티브로 날아간다.
  late final NaverMapViewOptions _options = RunMapStyle.baseOptions(
    initialCameraPosition: NCameraPosition(
      target: widget.route.first.toNaver(),
      zoom: 14,
    ),
    maxZoom: _maxZoom,
    // 240px 카드에 축척 바까지 얹으면 네이버 로고와 겹쳐 읽히지 않는다.
    scaleBarEnable: false,
  );

  @override
  Widget build(BuildContext context) {
    if (widget.route.length < 2) return const SizedBox.shrink();

    final builder = ref.watch(mapSurfaceBuilderProvider);

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTokens.rLg),
      child: SizedBox(
        height: widget.height,
        child: builder(
          MapSurfaceSpec(options: _options, onMapReady: _onMapReady),
        ),
      ),
    );
  }

  Future<void> _onMapReady(NaverMapController controller) async {
    // 지도 준비 콜백은 위젯 첫 빌드에 한 번이지만, 방어적으로 한 번만 그린다.
    if (_drawn) return;
    _drawn = true;

    // context를 읽는 작업(테마 색·마커 이미지 굽기)을 await 이전에 몰아 둔다.
    final lineColor = Theme.of(context).colorScheme.primary;
    final start = await RunMapStyle.dotMarker(
      context: context,
      id: 'run-route-start',
      point: widget.route.first,
      color: RunRouteMap.startColor,
    );
    if (!mounted) return;
    final finish = await RunMapStyle.dotMarker(
      context: context,
      id: 'run-route-finish',
      point: widget.route.last,
      color: RunRouteMap.finishColor,
    );
    if (!mounted) return;

    await controller.addOverlayAll(<NAddableOverlay>{
      RunMapStyle.routeLine(
        id: 'run-route',
        route: widget.route,
        color: lineColor,
        width: RunMapStyle.staticStrokeWidth,
      ),
      start,
      finish,
    });

    final bounds = widget.route.toNaverBounds();
    if (bounds != null) {
      await controller.updateCamera(
        NCameraUpdate.fitBounds(bounds, padding: _fitPadding),
      );
    }
  }
}
