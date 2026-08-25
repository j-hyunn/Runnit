import '../../../models/models.dart';

/// GPS/웨어러블 트래킹 엔진의 계약 — **gps-tracking-engineer 담당**.
///
/// ## 모듈 경계 원칙
/// 트래킹 모듈은 백엔드/게이미피케이션 모듈에 직접 의존하지 않는다.
/// 결과를 [sampleStream] / [sessionStream]으로 방출할 뿐이며,
/// 저장·뱃지 판정은 이 스트림을 구독하는 상위 계층이 담당한다.
/// 덕분에 트래킹 로직을 게이미피케이션과 독립적으로 테스트할 수 있고,
/// 향후 소스가 늘어나도(트레드밀 등) 하위 모듈 수정이 없다.
abstract interface class RunTrackingService {
  /// 수집되는 샘플의 실시간 스트림. 폰/워치 구분은 [RunSample.source]로만.
  Stream<RunSample> get sampleStream;

  /// 진행 중 세션의 누적 상태 스트림(거리/시간/페이스 갱신).
  /// samples는 비어 있을 수 있다(UI가 매 프레임 전체 리스트를 받지 않도록).
  Stream<RunRecord> get sessionStream;

  /// 권한/서비스 상태 점검 및 요청. 실패 시 Failure를 던진다.
  Future<void> ensureReady();

  /// 새 세션 시작. 반환값은 status=recording인 초기 레코드.
  Future<RunRecord> start({required String userId, required ActivityType type});

  Future<void> pause();
  Future<void> resume();

  /// 세션 종료. 최종 집계(거리/페이스/고도/폴리라인)가 끝난 레코드를 반환한다.
  /// 반환된 레코드는 status=completed이며 samples가 채워져 있다.
  Future<RunRecord> stop();

  /// 진행 중 세션 폐기(저장하지 않음).
  Future<void> discard();
}
