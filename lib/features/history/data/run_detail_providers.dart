import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/providers/repository_providers.dart';
import '../../../models/models.dart';
import '../../tracking/domain/polyline_codec.dart';
import '../domain/lap_splits.dart';

/// 러닝 상세 화면(HI-02)이 쓰는 단건 조회. **샘플을 포함**해 가져온다
/// (목록 스트림 `myRunsProvider`는 payload 절감을 위해 샘플이 비어 있다).
///
/// `autoDispose`인 이유: 1시간 러닝 한 건이 약 3,600개의 [RunSample]을 물고
/// 있다. 화면을 닫아도 캐시가 남으면 기록을 훑을수록 메모리가 단조 증가한다.
final runDetailProvider =
    FutureProvider.autoDispose.family<RunRecord?, String>((ref, runId) async {
  final repo = ref.watch(runRepositoryProvider);
  return repo.findById(runId, includeSamples: true);
});

/// 상세 화면의 1km 랩 분할. 조회 결과에서 파생한다.
///
/// 별도 provider로 둬서 리빌드마다 샘플 전체를 다시 훑지 않게 한다 —
/// 랩 테이블과 페이스 그래프가 같은 계산 결과를 공유한다.
final runLapSplitsProvider =
    Provider.autoDispose.family<List<LapSplit>, String>((ref, runId) {
  final record = ref.watch(runDetailProvider(runId)).valueOrNull;
  if (record == null) return const [];
  return computeLapSplits(record);
});

/// 지도에 그릴 경로 좌표. 원천 우선순위:
/// 1. `RunRecord.samples`의 좌표 (상세 조회에서 채워진다)
/// 2. `RunRecord.routePolyline` (다운샘플된 썸네일용 인코딩)
///
/// 비어 있거나 1점뿐이면 그릴 경로가 없다는 뜻이다(실내 러닝·GPS 유실).
/// provider로 뺀 이유는 폴리라인 디코딩이 지도 위젯 리빌드마다 반복되지
/// 않게 하기 위해서다.
final runRoutePointsProvider =
    Provider.autoDispose.family<List<LatLng>, String>((ref, runId) {
  final record = ref.watch(runDetailProvider(runId)).valueOrNull;
  if (record == null) return const [];
  return routePointsOf(record);
});

/// [runRoutePointsProvider]의 순수 함수 본체 — 테스트·공유 카드 등
/// provider 밖에서도 같은 규칙을 쓰려면 이쪽을 부른다.
List<LatLng> routePointsOf(RunRecord record) {
  final fromSamples = record.samples
      .where((s) => s.latitude != null && s.longitude != null)
      .map((s) => LatLng(s.latitude!, s.longitude!))
      .toList(growable: false);
  if (fromSamples.length >= 2) return fromSamples;

  final polyline = record.routePolyline;
  if (polyline != null && polyline.isNotEmpty) {
    return decodePolyline(polyline)
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList(growable: false);
  }
  return const [];
}
