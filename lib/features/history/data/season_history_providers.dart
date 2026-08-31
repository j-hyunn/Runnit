import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../models/models.dart';

/// 역대 시즌 화면(HI-06)이 구독하는 provider.
///
/// 로컬 캐시를 두지 않는다 — 러닝 기록(`myRunsProvider`)과 달리 이 데이터는
/// **서버가 마감 시점에 확정한 스냅샷**이고, 오프라인에서 다시 계산할 수 있는
/// 값이 아니다(로컬 러닝을 재집계하면 마감 이후의 무효 판정·보정이 빠진다).
///
/// 게스트는 빈 목록이다. 화면 자체가 로그인 필수 라우트라 실제로는 도달하지
/// 않지만, 로그아웃 직후 위젯이 한 프레임 더 살아있는 경우를 위해 방어한다
/// (`currentProfileProvider`와 같은 처리).
final mySeasonHistoriesProvider =
    FutureProvider<List<SeasonHistory>>((ref) async {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const <SeasonHistory>[];
  return ref.watch(seasonHistoryRepositoryProvider).fetchByUser(userId);
});

/// TI-09(역대 최고 티어, P1) 표시용 — **끝난 시즌만** 본다.
///
/// 진행 중인 시즌의 티어(`AppUser.currentTier`)는 포함하지 않는다. 이 값의
/// 의미는 "확정된 명예"이고, 아직 안 끝난 시즌은 확정이 아니기 때문이다.
/// 무효 처리된 시즌(`isVoided`)도 제외한다 — 부정 판정된 시즌이 최고 기록으로
/// 남으면 §8.1의 회수 정책이 무의미해진다.
final bestEverTierProvider = Provider<Tier?>((ref) {
  final histories =
      ref.watch(mySeasonHistoriesProvider).valueOrNull ?? const <SeasonHistory>[];

  Tier? best;
  for (final h in histories) {
    if (h.isVoided) continue;
    if (best == null || h.finalTier.order > best.order) best = h.finalTier;
  }
  return best;
});
