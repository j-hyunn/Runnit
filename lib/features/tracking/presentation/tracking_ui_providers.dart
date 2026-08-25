import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../models/models.dart';
import '../data/geolocator_run_tracking_service.dart';
import '../data/tracking_providers.dart';

/// 트래킹 **화면 전용** provider 모음.
///
/// `data/tracking_providers.dart`(gps-tracking-engineer 소유)는 건드리지 않고,
/// 화면이 필요로 하는 파생 상태만 여기에 둔다.
/// - [liveRouteProvider]           : 지도 폴리라인의 증분 누적
/// - [wearableNoticeReaderProvider] : 워치 배너 판단(테스트에서 override 가능)

/// 지도에 그릴 경로. [liveRunSampleProvider]가 주는 샘플을 **하나씩 덧붙인다**.
///
/// `activeRunProvider`의 `RunRecord.samples`는 의도적으로 항상 비어 있으므로
/// (gps 노트 §5-5) 경로는 반드시 이 경로로 누적해야 한다. 매 초 전체 리스트를
/// 다시 만들지 않도록 스트림 구독을 지도 위젯 하나로 좁혔다.
class LiveRoute extends Notifier<List<LatLng>> {
  @override
  List<LatLng> build() {
    ref.listen<AsyncValue<RunSample>>(liveRunSampleProvider, (_, next) {
      final sample = next.valueOrNull;
      if (sample == null) return;
      final lat = sample.latitude;
      final lng = sample.longitude;
      // 실내 러닝 샘플은 좌표가 없다 — 그릴 것이 없으므로 건너뛴다.
      if (lat == null || lng == null) return;
      state = <LatLng>[...state, LatLng(lat, lng)];
    });
    return const <LatLng>[];
  }

  /// 새 세션 시작/폐기 시 이전 경로를 지운다.
  void clear() => state = const <LatLng>[];
}

final liveRouteProvider = NotifierProvider<LiveRoute, List<LatLng>>(
  LiveRoute.new,
);

/// 워치 연동 안내 상태. 배너 문구를 고르는 데만 쓴다.
class WearableNotice {
  const WearableNotice({required this.connected, required this.delayedSync});

  /// 이 세션에 워치 지표가 한 번이라도 붙었는지.
  final bool connected;

  /// Garmin Connect 동기화 경유 데이터가 감지됐는지.
  /// true면 "동기화 후 반영" 안내를 띄운다(gps 노트 §5-3, §6).
  final bool delayedSync;

  static const none = WearableNotice(connected: false, delayedSync: false);
}

/// 워치 상태를 **호출 시점에** 읽는 함수를 돌려준다.
///
/// `usesDelayedWearableSync`/`wearableConnected`는 [RunTrackingService] 인터페이스가
/// 아니라 구현체([GeolocatorRunTrackingService])의 가변 필드라 Riverpod가 변화를
/// 알려주지 못한다. 그래서 값을 캐시하지 않고 **매 틱마다 다시 읽는** 함수를 노출한다.
/// 테스트/시뮬레이터에서는 이 provider를 override해 배너를 강제할 수 있다.
final wearableNoticeReaderProvider = Provider<WearableNotice Function()>((ref) {
  return () {
    final service = ref.read(runTrackingServiceProvider);
    if (service is! GeolocatorRunTrackingService) return WearableNotice.none;
    return WearableNotice(
      connected: service.wearableConnected,
      delayedSync: service.usesDelayedWearableSync,
    );
  };
});
