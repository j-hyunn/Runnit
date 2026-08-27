import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/theme/app_tokens.dart';
import '../../../../core/widgets/osm_attribution.dart';
import '../../../tracking/presentation/widgets/run_map_view.dart'
    show mapTileProviderOverride;

/// 완결된 러닝의 **정적 경로 지도** (HI-02).
///
/// 트래킹 화면의 [RunMapView]가 진행 중 스트림을 따라 카메라를 옮기는 것과
/// 달리, 여기서는 저장된 경로 전체가 한 화면에 들어오도록 한 번만 맞춘다
/// (`initialCameraFit`). 경로 좌표는 이미 계산된 것을 받는다 —
/// `runRoutePointsProvider` 참고. 위젯이 직접 디코딩하면 리빌드마다 폴리라인을
/// 다시 푼다.
///
/// 좌표가 2점 미만이면 [SizedBox.shrink]를 반환한다. 호출부는 그 경우
/// [RunMapUnavailable]로 지도 자리를 대신 채우는 것이 낫다.
class RunRouteMap extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    if (route.length < 2) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTokens.rLg),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FlutterMap(
              options: MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: LatLngBounds.fromPoints(route),
                  padding: const EdgeInsets.all(AppTokens.s32),
                ),
                // 제자리 러닝처럼 경계 폭이 0에 가까우면 fit이 최대 줌까지
                // 파고들어 타일이 비어 보인다. 상한을 둬서 막는다.
                maxZoom: 17,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.runnit.app',
                  tileProvider: ref.watch(mapTileProviderOverride),
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: route,
                      strokeWidth: 5,
                      color: scheme.primary,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    _endpoint(route.first, startColor),
                    _endpoint(route.last, finishColor),
                  ],
                ),
              ],
            ),
            // OSM 타일 이용 정책상 출처 표기는 선택이 아니라 필수다.
            const Positioned(right: 0, bottom: 0, child: OsmAttribution()),
          ],
        ),
      ),
    );
  }

  Marker _endpoint(LatLng point, Color color) => Marker(
        point: point,
        width: 16,
        height: 16,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
        ),
      );
}
