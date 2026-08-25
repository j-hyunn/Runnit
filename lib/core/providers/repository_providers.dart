import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/gamification/data/supabase_gamification_repository.dart';
import '../../features/profile/data/supabase_user_repository.dart';
import '../../features/ranking/data/supabase_ranking_repository.dart';
import '../../features/tracking/data/tracking_providers.dart';
import '../api/supabase_client.dart';
import '../repositories/gamification_repository.dart';
import '../repositories/ranking_repository.dart';
import '../repositories/run_repository.dart';
import '../repositories/user_repository.dart';

/// 레포지토리 provider의 단일 등록 지점.
///
/// 테스트/목킹은 `ProviderScope(overrides: [...])`로 처리한다.
///
/// 담당:
/// - runRepositoryProvider        → gps-tracking-engineer(로컬) + backend-engineer(원격)
/// - rankingRepositoryProvider    → backend-engineer
/// - gamificationRepositoryProvider → gamification-designer + backend-engineer
/// - userRepositoryProvider       → backend-engineer

/// 오프라인 우선 구현. 로컬(drift)에 먼저 쓰고 `syncPending()`으로 서버에
/// 밀어 올린다 — 지하 주차장에서 끝낸 러닝이 사라지면 안 되기 때문이다.
/// 조립은 트래킹 모듈이 소유한다(`features/tracking/data/tracking_providers.dart`).
final runRepositoryProvider = Provider<RunRepository>(buildLocalRunRepository);

final rankingRepositoryProvider = Provider<RankingRepository>((ref) {
  return SupabaseRankingRepository(ref.watch(supabaseClientProvider));
});

final gamificationRepositoryProvider = Provider<GamificationRepository>((ref) {
  return SupabaseGamificationRepository(ref.watch(supabaseClientProvider));
});

final userRepositoryProvider = Provider<UserRepository>((ref) {
  return SupabaseUserRepository(ref.watch(supabaseClientProvider));
});
