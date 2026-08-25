import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../models/models.dart';
import '../../history/data/history_providers.dart';
import '../domain/badge_progress.dart';
import '../domain/gamification_stats.dart';

/// 뱃지 갤러리가 구독하는 provider. (목업 `mock_badge_catalog.dart`를 대체)

/// 전체 뱃지 카탈로그(마스터 데이터). **게스트도 조회 가능**하다 —
/// `badges`는 anon SELECT가 열려 있다(마이그레이션 17).
final badgeCatalogProvider = FutureProvider<List<Badge>>((ref) {
  return ref.watch(gamificationRepositoryProvider).fetchBadgeCatalog();
});

/// 로그인 사용자가 획득한 뱃지 전체(획득 시각·서버 검증 상태 포함). 게스트면
/// 빈 목록(요청 자체를 하지 않는다 — `user_badges`는 authenticated 전용이라
/// anon 호출은 권한 오류가 된다).
final userBadgesProvider = FutureProvider<List<UserBadge>>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const <UserBadge>[];

  return ref.watch(gamificationRepositoryProvider).fetchUserBadges(userId);
});

/// 로그인 사용자가 획득한 뱃지 id 집합 — [userBadgesProvider]에서 파생.
final earnedBadgeIdsProvider = Provider<AsyncValue<Set<String>>>((ref) {
  return ref
      .watch(userBadgesProvider)
      .whenData((list) => list.map((e) => e.badgeId).toSet());
});

/// 뱃지 진행률 계산 입력. 게스트/로딩 중에는 [GamificationStats.empty]로
/// 폴백한다 — 진행률 없이 카탈로그만 중립적으로 보여주는 기존 게스트 UX와
/// 자연히 맞아떨어진다(모든 currentValue가 null → ratio 0).
final gamificationStatsProvider = Provider<GamificationStats>((ref) {
  final user = ref.watch(currentProfileProvider).valueOrNull;
  if (user == null) return GamificationStats.empty;

  final runs = ref.watch(myRunsProvider).valueOrNull ?? const [];
  return GamificationStats.fromUserAndRuns(user: user, runs: runs);
});

/// 카탈로그 + 획득 기록 + 통계를 합쳐 화면이 바로 쓸 수 있는 진행 상태 목록으로
/// 만든다. 시즌 미배정/지난 시즌 템플릿 제외, 카테고리·등급순 정렬까지 여기서
/// 끝낸다 — [badge_progress.dart]의 `BadgeProgressCalculator`가 실제 로직.
final badgeProgressListProvider = Provider<AsyncValue<List<BadgeProgress>>>((ref) {
  final catalog = ref.watch(badgeCatalogProvider);
  final earned = ref.watch(userBadgesProvider);
  final stats = ref.watch(gamificationStatsProvider);

  if (catalog.isLoading || earned.isLoading) {
    return const AsyncValue.loading();
  }
  final error = catalog.hasError ? catalog : (earned.hasError ? earned : null);
  if (error != null) {
    return AsyncValue.error(error.error!, error.stackTrace!);
  }

  return AsyncValue.data(BadgeProgressCalculator.forCatalog(
    catalog: catalog.requireValue,
    earnedBadges: earned.requireValue,
    stats: stats,
    currentSeasonId: Season.currentId(),
  ));
});
