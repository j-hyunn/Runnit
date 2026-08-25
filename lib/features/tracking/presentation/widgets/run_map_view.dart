import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/theme/app_tokens.dart';
import '../tracking_ui_providers.dart';

/// 진행 중 경로를 그리는 지도.
///
/// ## 리빌드 범위
/// 이 위젯은 [liveRouteProvider] **하나만** 구독한다. 통계 텍스트(1초마다 갱신되는
/// `activeRunProvider`)와 분리돼 있으므로, 매 초 타이머가 흘러도 지도 타일은
/// 다시 그려지지 않는다. 반대로 새 GPS 샘플이 와도 통계 패널은 건드리지 않는다.
///
/// 지도 타일은 네트워크가 없으면(지하 주차장·기내 등) 회색으로 남지만 폴리라인과
/// 통계는 그대로 동작한다 — 트래킹이 타일 로딩에 종속되지 않게 한 것이다.
class RunMapView extends ConsumerStatefulWidget {
  const RunMapView({super.key, this.dimmed = false});

  /// 일시정지 상태에서 지도를 살짝 눌러 "멈춰 있음"을 시각적으로 알린다.
  final bool dimmed;

  @override
  ConsumerState<RunMapView> createState() => _RunMapViewState();
}

class _RunMapViewState extends ConsumerState<RunMapView> {
  final MapController _controller = MapController();
  bool _mapReady = false;

  /// 서울 시청. 첫 GPS fix가 오기 전 잠깐 보여줄 초기 카메라일 뿐이며,
  /// fix가 들어오는 순간 사용자 위치로 이동한다.
  static const LatLng _fallbackCenter = LatLng(37.5665, 126.9780);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _follow(List<LatLng> route) {
    if (!_mapReady || route.isEmpty) return;
    // 카메라 이동은 프레임 도중 호출하면 안 된다(빌드 중 상태 변경).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.move(route.last, _controller.camera.zoom);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final route = ref.watch(liveRouteProvider);
    _follow(route);

    return Stack(
      fit: StackFit.expand,
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: route.isEmpty ? _fallbackCenter : route.last,
            initialZoom: 16,
            // 달리는 중에 지도를 회전시키면 방향 감각이 무너진다.
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
            ),
            onMapReady: () => _mapReady = true,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.runnit.app',
              tileProvider: ref.watch(mapTileProviderOverride),
            ),
            if (route.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: route,
                    strokeWidth: 6,
                    color: scheme.primary,
                    borderStrokeWidth: 2,
                    borderColor: scheme.onPrimary,
                  ),
                ],
              ),
            if (route.isNotEmpty)
              MarkerLayer(
                markers: [
                  Marker(
                    point: route.last,
                    width: 22,
                    height: 22,
                    child: _CurrentPositionDot(color: scheme.primary),
                  ),
                ],
              ),
          ],
        ),
        if (route.isEmpty) const _WaitingForFixOverlay(),
        if (widget.dimmed)
          IgnorePointer(
            child: ColoredBox(color: scheme.surface.withValues(alpha: 0.45)),
          ),
      ],
    );
  }
}

class _CurrentPositionDot extends StatelessWidget {
  const _CurrentPositionDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 8),
        ],
      ),
    );
  }
}

/// GPS가 첫 좌표를 물기 전 몇 초 동안 지도가 텅 비어 보이는 구간을 설명한다.
/// 아무 표시가 없으면 사용자는 "기록이 안 되고 있다"고 오해한다.
class _WaitingForFixOverlay extends StatelessWidget {
  const _WaitingForFixOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTokens.s16,
          vertical: AppTokens.s12,
        ),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(AppTokens.rMd),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppTokens.s8),
            Text('GPS 신호를 잡는 중', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// 지도 타일 소스 주입점. 기본은 OSM 네트워크 타일이다.
///
/// 위젯 테스트에서는 이 provider를 override해 네트워크 타일 요청을 끊는다 —
/// 그러지 않으면 타일 요청 재시도 때문에 `pumpAndSettle`이 영영 끝나지 않는다.
final mapTileProviderOverride = Provider<TileProvider?>((ref) => null);

/// 실내 러닝처럼 좌표가 없는 활동에서 지도 자리를 대신한다.
class RunMapUnavailable extends StatelessWidget {
  const RunMapUnavailable({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.s24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                size: 40,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppTokens.s12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
