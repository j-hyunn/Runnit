import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../../core/map/map_geo.dart';
import '../../../../core/map/map_surface.dart';
import '../../../../core/theme/app_tokens.dart';
import '../tracking_ui_providers.dart';

/// 진행 중 경로를 그리는 지도 (Naver Map).
///
/// ## 리빌드 범위
/// 이 위젯의 `build`는 [liveRouteProvider]를 **`watch`하지 않는다.** GPS 샘플은
/// `ref.listen`으로 받아 폴리라인·마커·카메라를 **명령형으로** 갱신한다 —
/// 초당 몇 번씩 오는 좌표 때문에 네이티브 지도 뷰가 재생성되면 프레임이 날아간다.
/// "GPS 신호를 잡는 중" 안내만 [_WaitingForFixOverlay]라는 별도 구독 단위로
/// 떼어 두어, 첫 fix가 들어올 때 그 조각만 사라진다.
///
/// 통계 텍스트(1초마다 갱신되는 `activeRunProvider`)와도 분리돼 있어, 매 초
/// 타이머가 흘러도 지도는 다시 그려지지 않는다.
///
/// ## 선과 점의 좌표가 다르다 (TR-04)
/// - **폴리라인**: [liveRouteProvider] — 스무딩된 좌표. 지그재그가 죽는다.
/// - **현재 위치 마커·카메라**: [liveMarkerProvider] — 스무딩 **이전** 원시 fix.
///   이동평균 창(5) 때문에 스무딩 좌표는 약 2 fix 뒤처지는데, 그 지연이 마커에
///   실리면 "5초 이내 최신 위치 반영"(TR-04)을 체감상 못 지킨다.
/// 원시 스트림이 없는 구현(테스트 fake)에서는 마커도 폴리라인 마지막 점을 쓴다.
///
/// 지도 타일은 네트워크가 없으면(지하 주차장·기내 등) 비어 보이지만 폴리라인과
/// 통계는 그대로 동작한다 — 트래킹이 타일 로딩에 종속되지 않게 한 것이다.
class RunMapView extends ConsumerStatefulWidget {
  const RunMapView({super.key, this.dimmed = false});

  /// 일시정지 상태에서 지도를 살짝 눌러 "멈춰 있음"을 시각적으로 알린다.
  final bool dimmed;

  @override
  ConsumerState<RunMapView> createState() => _RunMapViewState();
}

class _RunMapViewState extends ConsumerState<RunMapView> {
  static const String _routeOverlayId = 'live-route';
  static const String _positionOverlayId = 'live-position';

  /// 서울 시청. 첫 GPS fix가 오기 전 잠깐 보여줄 초기 카메라일 뿐이며,
  /// fix가 들어오는 순간 사용자 위치로 이동한다.
  static const LatLng _fallbackCenter = LatLng(37.5665, 126.9780);

  NaverMapController? _controller;
  NPolylineOverlay? _routeLine;
  NMarker? _positionMarker;

  /// 마커 아이콘을 굽는 작업이 여러 번 겹치지 않게 막는다.
  bool _buildingMarker = false;

  /// 원시 fix([liveMarkerProvider])가 한 번이라도 들어왔는지. 들어온 뒤에는
  /// 마커·카메라를 그쪽에만 맡긴다 — 폴리라인(스무딩 좌표)의 마지막 점으로
  /// 되돌리면 마커가 앞뒤로 튄다.
  bool _followingRawFix = false;

  /// 첫 프레임의 카메라 위치. 매 빌드마다 옵션 인스턴스를 새로 만들면
  /// (`NaverMapViewOptions`는 `==`가 없다) 옵션 갱신이 계속 네이티브로 날아간다.
  late final LatLng _initialCenter =
      ref.read(liveRouteProvider).lastOrNull ?? _fallbackCenter;

  late final NaverMapViewOptions _normalOptions = RunMapStyle.baseOptions(
    initialCameraPosition: NCameraPosition(
      target: _initialCenter.toNaver(),
      zoom: 16,
    ),
  );

  /// 일시정지 표시는 **화면을 덮는 딤 대신 지도 자체를 어둡게** 해서 만든다.
  /// 전면 딤 오버레이는 네이버 SDK가 그리는 로고·저작권 표기까지 덮어버리는데,
  /// 그 표기는 가리면 안 된다(이용약관).
  late final NaverMapViewOptions _dimmedOptions = RunMapStyle.baseOptions(
    initialCameraPosition: NCameraPosition(
      target: _initialCenter.toNaver(),
      zoom: 16,
    ),
    lightness: -0.35,
  );

  @override
  Widget build(BuildContext context) {
    // watch가 아니라 listen — 좌표가 와도 이 위젯은 리빌드되지 않는다.
    ref.listen<List<LatLng>>(liveRouteProvider, (_, next) => _syncRoute(next));
    // 마커·카메라는 스무딩 이전 좌표를 따라간다(TR-04). 선만 스무딩 좌표다.
    ref.listen<AsyncValue<LatLng>>(liveMarkerProvider, (_, next) {
      final point = next.valueOrNull;
      if (point == null) return;
      _followingRawFix = true;
      _moveTo(point);
    });

    final builder = ref.watch(mapSurfaceBuilderProvider);

    return Stack(
      fit: StackFit.expand,
      children: [
        builder(
          MapSurfaceSpec(
            options: widget.dimmed ? _dimmedOptions : _normalOptions,
            onMapReady: _onMapReady,
          ),
        ),
        const _WaitingForFixOverlay(),
      ],
    );
  }

  void _onMapReady(NaverMapController controller) {
    _controller = controller;
    _syncRoute(ref.read(liveRouteProvider));
  }

  /// 폴리라인·현재 위치 마커·카메라를 한 번에 맞춘다.
  Future<void> _syncRoute(List<LatLng> route) async {
    final controller = _controller;
    if (controller == null || route.isEmpty) return;

    final line = _routeLine;
    if (route.length >= 2) {
      if (line == null) {
        final created = RunMapStyle.routeLine(
          id: _routeOverlayId,
          route: route,
          color: Theme.of(context).colorScheme.primary,
          width: RunMapStyle.liveStrokeWidth,
        );
        _routeLine = created;
        await controller.addOverlay(created);
      } else {
        // 오버레이를 다시 만들지 않고 좌표만 갈아끼운다 — 매 샘플마다
        // add/delete를 반복하면 경로가 깜빡인다.
        line.setCoords(route.toNaverCoords());
      }
    }

    // 원시 fix가 마커를 이미 몰고 있으면 여기서는 선만 갱신한다.
    if (!_followingRawFix) await _moveTo(route.last);
  }

  /// 현재 위치 마커와 카메라를 한 점으로 옮긴다.
  Future<void> _moveTo(LatLng point) async {
    final controller = _controller;
    if (controller == null) return;

    await _syncPositionMarker(controller, point);

    // 카메라 이동은 빌드 중에 호출하면 안 된다(빌드 도중 상태 변경).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // zoom을 넘기지 않으면 사용자가 맞춰 둔 줌 배율이 유지된다.
      controller.updateCamera(
        NCameraUpdate.scrollAndZoomTo(target: point.toNaver()),
      );
    });
  }

  Future<void> _syncPositionMarker(
    NaverMapController controller,
    LatLng point,
  ) async {
    final marker = _positionMarker;
    if (marker != null) {
      marker.setPosition(point.toNaver());
      return;
    }
    if (_buildingMarker) return;
    _buildingMarker = true;
    try {
      final created = await RunMapStyle.dotMarker(
        context: context,
        id: _positionOverlayId,
        point: point,
        color: Theme.of(context).colorScheme.primary,
        diameter: 22,
        glow: true,
      );
      if (!mounted) return;
      _positionMarker = created;
      await controller.addOverlay(created);
    } finally {
      _buildingMarker = false;
    }
  }
}

/// GPS가 첫 좌표를 물기 전 몇 초 동안 지도가 텅 비어 보이는 구간을 설명한다.
/// 아무 표시가 없으면 사용자는 "기록이 안 되고 있다"고 오해한다.
///
/// 지도 본체와 분리된 구독 단위다 — 첫 fix가 들어오면 이 조각만 사라지고
/// 네이티브 지도 뷰는 건드리지 않는다.
class _WaitingForFixOverlay extends ConsumerWidget {
  const _WaitingForFixOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasFix = ref.watch(
      liveRouteProvider.select((route) => route.isNotEmpty),
    );
    if (hasFix) return const SizedBox.shrink();

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
