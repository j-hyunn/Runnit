import '../../models/models.dart';

/// 러닝 기록의 영속화 계약.
///
/// 구현체는 두 곳에 존재한다:
/// - `features/tracking/data/local_run_repository.dart` (drift, 오프라인 우선)
/// - `features/history/data/supabase_run_repository.dart` (backend-engineer)
///
/// 어느 구현이든 이 시그니처를 지키면 상위 계층 수정 없이 교체 가능하다.
abstract interface class RunRepository {
  /// 완결된 러닝 저장(로컬 우선 저장 후 동기화). id는 클라이언트 생성 UUID.
  Future<void> save(RunRecord record);

  /// 단건 조회. samples 포함 여부는 [includeSamples]로 제어(목록 payload 절감).
  Future<RunRecord?> findById(String id, {bool includeSamples = false});

  /// 사용자 기록 목록. 최신순. samples는 항상 비어 있다.
  Future<List<RunRecord>> listByUser(
    String userId, {
    int limit = 20,
    DateTime? before,
  });

  /// 목록 변경 구독(업로드 완료/삭제 반영).
  Stream<List<RunRecord>> watchByUser(String userId, {int limit = 20});

  Future<void> delete(String id);

  /// 미동기화(local/failed) 기록을 서버로 밀어 올린다. 성공 건수를 반환.
  Future<int> syncPending();
}
