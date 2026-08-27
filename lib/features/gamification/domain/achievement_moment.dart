import '../../../models/enums.dart';

/// 공유 카드(HI-08 · HI-10)를 **언제 확정적으로 띄워도 되는가**를 판정하는
/// 순수 함수 모음.
///
/// 배경: PRD §8.1/§8.4는 "검증 통과 기록만" 티어·랭킹·뱃지에 반영하라고
/// 못박는다. 공유 카드는 앱 밖으로 나가는 산출물이라 뒤집히면 회수할 수 없다.
/// 따라서 **서버가 확정한 사실만** 공유 대상이 된다.
///
/// 여기의 함수는 전부 입력→출력만 의존한다(부수효과·시계·네트워크 없음).
/// 판정 근거 문서: `_workspace/20260826_105607_gamification_sharing-trigger-timing.md`

/// 요약 화면이 성취 블록을 어떤 상태로 그려야 하는지.
enum AchievementGate {
  /// 서버 확정 완료 — 축하 연출 + **공유 버튼 노출**.
  confirmed,

  /// 아직 업로드/검증 전(오프라인 등) — 잠정 수치는 보여주되
  /// "확정" 문구와 **공유 버튼은 금지**. 동기화되면 [confirmed]로 승격된다.
  pending,

  /// 서버가 이 기록을 플래그했다(PRD §8.4) — 축하도 공유도 없다.
  /// 회수 애니메이션 없이 조용히 성취 블록을 생략한다(TRD §11 "설명 없이 박탈하지 않음").
  flagged,
}

/// 요약 화면 성취 블록의 게이트 상태.
///
/// - [runSynced]: 해당 러닝이 서버 upsert에 성공했는가.
/// - [runFlagged]: 서버가 돌려준 `runs.is_flagged`. 아직 모르면 null.
///   (⚠️ 2026-08-26 현재 `RunRecord`에 이 필드가 없다 — 문서 §4 참조)
AchievementGate achievementGate({
  required bool runSynced,
  bool? runFlagged,
}) {
  if (!runSynced) return AchievementGate.pending;
  if (runFlagged == true) return AchievementGate.flagged;
  if (runFlagged == null) return AchievementGate.pending;
  return AchievementGate.confirmed;
}

/// 티어 승급 축하를 띄워도 되는가.
///
/// 서버(`recompute_season_tier`)는 러닝 업로드와 **같은 트랜잭션**에서
/// `profiles.current_tier`를 갱신한다. 따라서 업로드 성공 직후 프로필을
/// 다시 읽어 이 함수로 비교하면 된다 — 배치 대기도 realtime 구독도 필요 없다.
///
/// **시즌 id를 함께 비교하는 이유**: 분기 경계에서 전원이 브론즈로 리셋된다
/// (PRD §8.1). 시즌이 다르면 티어 대소 비교 자체가 의미 없고, 리셋 직후
/// 브론즈→실버 재승급을 "승급"으로 축하하는 것은 정상 동작이지만,
/// 시즌이 바뀐 첫 비교에서 옛 시즌 티어와 새 시즌 티어를 견주면 안 된다.
bool isTierPromotion({
  required Tier? previousTier,
  required String? previousSeasonId,
  required Tier currentTier,
  required String? currentSeasonId,
}) {
  if (previousTier == null) return false;
  if (previousSeasonId == null || currentSeasonId == null) return false;
  if (previousSeasonId != currentSeasonId) return false;
  return currentTier.order > previousTier.order;
}

/// 뱃지 획득 축하·공유를 띄워도 되는가.
///
/// 서버 `evaluate_badges()`는 `status='completed' AND is_flagged=false`인
/// 기록만 근거로 판정하고, 지급 시 `verified=true, revoked=false`로 넣는다.
/// 즉 **지급된 순간 이미 확정**이며 자동으로 뒤집히는 경로는 없다
/// (회수는 PRD §8.1 부정 판정 시 운영자 수동 처리뿐).
///
/// [verified]/[revoked]는 서버 행에서 그대로 읽은 값이어야 한다.
/// 클라이언트가 조건을 직접 계산해 이 함수를 통과시키면 PRD §8.4 위반이다.
bool isBadgeShareable({required bool verified, required bool revoked}) =>
    verified && !revoked;
