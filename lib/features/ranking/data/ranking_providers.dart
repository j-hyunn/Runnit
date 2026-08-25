import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../models/models.dart';

/// 랭킹 화면이 구독하는 provider. (목업 `mock_leaderboard.dart`를 대체)
///
/// v1 화면은 **이번 주 누적 거리** 한 조합만 노출한다. 기간/지표 선택 UI가
/// 생기면 family 키를 레코드로 확장하면 된다 — 리포지토리는 이미 필터를 받는다.
const rankingPeriodV1 = RankingPeriod.weekly;
const rankingMetricV1 = RankingMetric.distance;

/// **2026-08-21 홈 Figma 반영**: "오늘의 Top 러너" 섹션 전용. `refresh_all_leaderboards()`가
/// 이미 모든 (period, metric) 조합 × scope=global을 5분마다 갱신하므로
/// `daily`+`distance`는 백엔드 변경 없이 바로 쓸 수 있다(`leaderboard_entries`
/// 실측 확인 완료).
const rankingPeriodDaily = RankingPeriod.daily;

/// 크루/친구 없이, `RankingScope.global`을 `tier` 파라미터로만 세분화한다
/// (마이그레이션 23, `tier`는 `scope`와 직교). family 키 `Tier?`: `null` = 전체
/// (티어 무관), 특정 [Tier] = 그 티어 안에서의 랭킹.
final leaderboardProvider =
    FutureProvider.family<List<RankingEntry>, Tier?>((ref, tier) async {
  final repo = ref.watch(rankingRepositoryProvider);
  return repo.fetchLeaderboard(
    period: rankingPeriodV1,
    metric: rankingMetricV1,
    scope: RankingScope.global,
    tier: tier,
  );
});

/// 로그인 사용자의 현재 티어. 티어별 랭킹 섹션이 어느 티어를 조회할지 결정한다.
/// 게스트이거나 프로필이 아직 없으면 null(해당 섹션은 로그인 유도로 대체).
final myTierProvider = FutureProvider<Tier?>((ref) async {
  final profile = await ref.watch(currentProfileProvider.future);
  return profile?.currentTier;
});

/// 각 리더보드 섹션에 고정 표시되는 "내 순위" 한 줄. 게스트면 null.
/// family 키는 [leaderboardProvider]와 동일하게 `Tier?`(null=전체, 특정=그 티어).
final myRankProvider =
    FutureProvider.family<RankingEntry?, Tier?>((ref, tier) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;

  return ref.watch(rankingRepositoryProvider).fetchMyEntry(
        userId: userId,
        period: rankingPeriodV1,
        metric: rankingMetricV1,
        scope: RankingScope.global,
        tier: tier,
      );
});

/// "티어별 유저 랭킹" 섹션 전용 합성 provider — 내 현재 티어를 먼저 구한 뒤
/// 그 티어의 리더보드/내 순위를 조회한다. 게스트 분기는 위젯에서
/// `isAuthenticatedProvider`로 먼저 처리하므로(로그인 유도 카드로 대체),
/// 여기서 tier가 null인 경우는 "프로필 로딩 실패"에 가까운 예외적 상황만 남는다.
final myTierLeaderboardProvider =
    FutureProvider<List<RankingEntry>>((ref) async {
  final tier = await ref.watch(myTierProvider.future);
  if (tier == null) return const <RankingEntry>[];
  return ref.watch(leaderboardProvider(tier).future);
});

final myTierRankProvider = FutureProvider<RankingEntry?>((ref) async {
  final tier = await ref.watch(myTierProvider.future);
  if (tier == null) return null;
  return ref.watch(myRankProvider(tier).future);
});

/// "오늘의 Top 러너" 섹션 — 오늘 하루 누적 거리 기준 상위 N명(티어 무관, 게스트도
/// 조회 가능한 global 스코프). RLS가 `scope='global'`인 anon 조회를 허용하므로
/// 로그인 여부와 무관하게 그대로 쓸 수 있다.
final dailyTopRunnersProvider = FutureProvider<List<RankingEntry>>((ref) async {
  final repo = ref.watch(rankingRepositoryProvider);
  return repo.fetchLeaderboard(
    period: rankingPeriodDaily,
    metric: rankingMetricV1,
    scope: RankingScope.global,
    tier: null,
    limit: 5,
  );
});
