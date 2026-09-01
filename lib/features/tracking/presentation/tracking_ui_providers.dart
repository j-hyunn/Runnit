import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../models/models.dart';
import '../../history/data/history_providers.dart';
import '../data/geolocator_run_tracking_service.dart';
import '../data/tracking_providers.dart';

/// 트래킹 **화면 전용** provider 모음.
///
/// `data/tracking_providers.dart`(gps-tracking-engineer 소유)는 건드리지 않고,
/// 화면이 필요로 하는 파생 상태만 여기에 둔다.
/// - [liveRouteProvider]           : 지도 폴리라인의 증분 누적
/// - [liveMarkerProvider]           : 지도 마커용 원시(스무딩 이전) 좌표
/// - [wearableNoticeReaderProvider] : 워치 배너 판단(테스트에서 override 가능)
/// - [autoPauseReaderProvider]      : 자동 일시정지 표시 판단(동상)
/// - [storedRunProvider]            : 저장된 러닝의 최신 서버 확정 상태

/// 로컬 DB에 저장된 그 러닝의 **최신 상태**.
///
/// ## 왜 `stop()`의 반환값을 그대로 쓰면 안 되는가
/// `TrackingController.stop()`이 돌려주는 [RunRecord]는 **업로드 이전 스냅샷**이다
/// (`save()`가 `Future<void>`라 서버 확정본을 돌려줄 자리가 없다). 요약 화면이
/// 그 값으로 성취 게이트를 판정하면 `syncStatus`는 영원히 `local`, `isFlagged`는
/// 영원히 `null`이라 **온라인에서도 `pending`에 머문다** — 축하도 공유 버튼도
/// 뜨지 않는다.
///
/// `myRunsProvider`는 drift `watch()` 기반이라 업로드가 끝나 `summaryJson`이
/// 갱신되면 자동으로 재발행된다. 그래서 새 조회를 짜지 않고 이미 있는 그
/// 스트림에서 해당 id만 골라낸다.
///
/// ⚠️ 목록 스트림이라 `samples`가 비어 있다 — **경로가 필요한 곳에서는 쓰지 말 것**
/// (공유 카드의 경로는 손에 쥔 원본 레코드에서 뽑는다). 여기서 읽는 값은
/// `syncStatus` / `isFlagged` / `flagReason`뿐이다.
final storedRunProvider = Provider.family<RunRecord?, String>((ref, runId) {
  final runs = ref.watch(myRunsProvider).valueOrNull;
  if (runs == null) return null;
  for (final run in runs) {
    if (run.id == runId) return run;
  }
  return null;
});

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

/// 지도 **마커**가 따라갈 좌표 — 스무딩 이전 원시 fix다(TR-04, C-4).
///
/// [liveRouteProvider]가 주는 좌표는 이동평균을 거쳐 약 2 fix 뒤처진다. 선은
/// 그 값이 맞지만(지그재그가 죽는다) "지금 내 위치" 점까지 뒤처지면 사용자가
/// 체감하는 반영 지연이 폴링 간격 + 스무딩 지연이 된다.
///
/// 원시 스트림을 못 얻는 구현체(테스트 fake 등)에서는 빈 스트림이며, 이때
/// 지도는 예전처럼 폴리라인 마지막 점으로 마커를 그린다(`RunMapView`).
final liveMarkerProvider = StreamProvider<LatLng>((ref) {
  final service = ref.watch(runTrackingServiceProvider);
  if (service is! GeolocatorRunTrackingService) {
    return const Stream<LatLng>.empty();
  }
  return service.rawFixStream.map((fix) => LatLng(fix.latitude, fix.longitude));
});

/// **자동 일시정지 중인지**를 호출 시점에 읽는 함수(TR-03, C-2).
///
/// [wearableNoticeReaderProvider]와 같은 이유로 값이 아니라 함수를 노출한다 —
/// 판정 근거가 구현체의 가변 상태(집계기 상태기계)라 Riverpod가 변화를 통지하지
/// 못한다. 소비 측([_ActiveBanners])이 초당 틱에 맞춰 다시 읽는다.
final autoPauseReaderProvider = Provider<bool Function()>((ref) {
  return () {
    final service = ref.read(runTrackingServiceProvider);
    if (service is! GeolocatorRunTrackingService) return false;
    return service.isAutoPaused;
  };
});

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
