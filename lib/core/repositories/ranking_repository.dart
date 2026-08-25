import '../../models/models.dart';

/// 리더보드 조회 계약. 순위 계산은 전적으로 서버 책임이며,
/// 클라이언트는 결과를 표시만 한다.
abstract interface class RankingRepository {
  /// [tier]가 `null`이면 티어 무관(전체) 리더보드(`tier IS NULL` 행)를,
  /// 특정 [Tier]를 주면 그 티어 안에서의 리더보드를 조회한다(RK-02).
  Future<List<RankingEntry>> fetchLeaderboard({
    required RankingPeriod period,
    required RankingMetric metric,
    required RankingScope scope,
    Tier? tier,
    String? crewId,
    int limit = 50,
    int offset = 0,
  });

  /// 특정 사용자의 현재 순위 한 줄(리더보드 하단 고정 표시용).
  Future<RankingEntry?> fetchMyEntry({
    required String userId,
    required RankingPeriod period,
    required RankingMetric metric,
    required RankingScope scope,
    Tier? tier,
    String? crewId,
  });

  /// 실시간 랭킹 구독(Supabase Realtime).
  Stream<List<RankingEntry>> watchLeaderboard({
    required RankingPeriod period,
    required RankingMetric metric,
    required RankingScope scope,
    Tier? tier,
    String? crewId,
    int limit = 50,
  });
}
