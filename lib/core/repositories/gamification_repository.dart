import '../../models/models.dart';

/// 뱃지 카탈로그/획득 기록 및 챌린지 조회 계약.
///
/// **획득 판정은 서버에서만 한다.** 클라이언트는 판정 결과를 조회/표시할 뿐이며,
/// 이 인터페이스에 "뱃지를 부여한다" 류의 메서드는 두지 않는다(부정행위 방지).
abstract interface class GamificationRepository {
  /// 전체 뱃지 카탈로그(마스터 데이터, 캐시 대상).
  Future<List<Badge>> fetchBadgeCatalog();

  /// 사용자 획득 기록. [Badge] 조인 포함.
  Future<List<UserBadge>> fetchUserBadges(String userId);

  /// 아직 획득 연출을 보여주지 않은 뱃지(획득 큐).
  Stream<List<UserBadge>> watchUnseenBadges(String userId);

  /// 획득 연출 표시 완료 처리.
  Future<void> markBadgesSeen(List<String> userBadgeIds);

  Future<List<Challenge>> fetchChallenges({ChallengeStatus? status, String? crewId});

  Future<List<ChallengeParticipation>> fetchMyParticipations(String userId);

  Future<void> joinChallenge({required String challengeId, required String userId});
}
