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

  /// 목록 변경 구독(업로드 완료/폐기 반영).
  Stream<List<RunRecord>> watchByUser(String userId, {int limit = 20});

  /// 저장된 러닝의 **제목·메모만** 수정한다 (PRD HI-07 / TRD §4.4).
  ///
  /// 거리·시간·샘플 등 나머지 컬럼은 서버 `trg_runs_guard`가 터미널 상태 행에
  /// 대해 조용히 되돌린다(4xx가 아니다 — 마이그레이션 51). 즉 "수정 가능 필드"의
  /// 목록은 이 시그니처가 곧 전부다.
  ///
  /// 서버가 `btrim` → 길이 절단([kRunTitleMaxLength]/[kRunNoteMaxLength]) →
  /// 빈 문자열은 `null`로 **정규화**하므로, 보낸 값과 확정값이 다를 수 있다.
  /// 그래서 반환값은 인자를 그대로 되돌려주는 것이 아니라 **서버가 확정한 값**이며,
  /// 호출부는 이 반환값을 화면/로컬 캐시에 반영해야 한다.
  ///
  /// `null`을 넘기면 해당 필드를 비운다(= 서버에도 `null`). 한쪽만 고치고 싶다면
  /// 나머지 필드에 현재 값을 그대로 실어 보낸다 — 부분 patch 시맨틱이 아니다.
  Future<RunMeta> updateMeta(String id, {String? title, String? note});

  /// **미완결 세션 폐기 전용.** `recording`/`paused` 상태의 로컬 체크포인트를 지운다
  /// (`TrackingController.discard()`, 미완결 세션 배너의 "버리기").
  ///
  /// ⚠️ **완료된 기록에는 절대 호출하지 말 것** (PRD v1.6 §8.1 — 사용자는 러닝을
  /// 삭제할 수 없다). 서버에는 삭제 정책 자체가 없으므로(마이그레이션 51-3),
  /// 완료 기록에 부르면 **로컬 행만 사라지고 서버 행은 남아** 다음 원격 조회에서
  /// 그대로 되살아난다. 사용자에게 노출되는 삭제 UI를 만들지 않는다.
  Future<void> delete(String id);

  /// 미동기화(local/failed) 기록을 서버로 밀어 올린다. 성공 건수를 반환.
  Future<int> syncPending();
}

/// `runs.title` 상한. 서버 CHECK `runs_title_len`과 같은 값이다(TRD §4.4).
/// 목록/공유 카드에서 줄바꿈 없이 읽히는 한 줄 제목 기준.
const int kRunTitleMaxLength = 60;

/// `runs.note` 상한. 서버 CHECK `runs_note_len`과 같은 값(TRD §4.4).
const int kRunNoteMaxLength = 500;

/// [RunRepository.updateMeta]의 결과 — **서버가 확정한** 제목·메모와 수정 시각.
///
/// [RunRecord] 전체를 되받지 않는 이유는 payload다. 편집 응답으로 `samples`까지
/// 내려받으면 1시간 러닝의 3,600 샘플을 제목 한 줄 고치자고 다시 받는 셈이 된다
/// (`LocalRunRepository._confirmationColumns`와 같은 방침).
class RunMeta {
  const RunMeta({this.title, this.note, this.updatedAt});

  /// 서버 편집 응답(`select('id,title,note,updated_at')`) 파싱.
  factory RunMeta.fromServer(Map<String, dynamic> row) {
    final updatedAt = row['updated_at'];
    return RunMeta(
      title: row['title'] as String?,
      note: row['note'] as String?,
      updatedAt:
          updatedAt is String ? DateTime.parse(updatedAt).toUtc() : null,
    );
  }

  /// 서버 가드와 **같은 규칙**을 클라이언트에서 적용한다: `btrim` → 길이 절단 →
  /// 빈 문자열은 `null`.
  ///
  /// 서버에 아직 올라가지 않은 기록(오프라인 저장분)을 편집할 때 쓴다. 서버 응답이
  /// 없으니 확정값을 만들 주체가 클라이언트뿐인데, 규칙이 갈라지면 나중에
  /// `syncPending()`이 올린 뒤 서버 정규화 결과와 로컬 값이 어긋난다.
  ///
  /// 절단은 UTF-16 코드 유닛이 아니라 **룬 단위**다 — Postgres `left()`가 문자
  /// 단위로 자르므로, BMP 밖 이모지가 섞이면 코드 유닛 기준 절단은 서버와 다른
  /// 길이를 만든다.
  factory RunMeta.normalized({
    String? title,
    String? note,
    DateTime? updatedAt,
  }) =>
      RunMeta(
        title: normalizeRunMetaField(title, kRunTitleMaxLength),
        note: normalizeRunMetaField(note, kRunNoteMaxLength),
        updatedAt: updatedAt,
      );

  final String? title;
  final String? note;
  final DateTime? updatedAt;
}

/// [RunMeta.normalized]의 필드 단위 본체. UI의 미리보기에도 같은 규칙을 쓰라고
/// 밖으로 뺐다.
String? normalizeRunMetaField(String? value, int maxLength) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final runes = trimmed.runes.toList(growable: false);
  if (runes.length <= maxLength) return trimmed;
  return String.fromCharCodes(runes.take(maxLength));
}
