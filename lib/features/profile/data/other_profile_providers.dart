import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../models/models.dart';

/// AC-03(타인 프로필 조회)이 구독하는 provider 묶음.
///
/// ## 왜 본인용(`currentProfileProvider` / `userBadgesProvider` /
/// `mySeasonHistoriesProvider`)과 분리하는가
///
/// 1. **키가 다르다.** 본인용은 인증 상태(`currentUserIdProvider`)에 매달려
///    있어서 로그아웃 시 자동으로 비워지는 것이 옳다. 타인용은 라우트 파라미터
///    (`/users/:id`)가 키다. 같은 provider를 재사용하면 "누구의 데이터인가"를
///    화면이 매번 확인해야 하고, 로그아웃 순간 남의 프로필이 사라진다.
/// 2. **수명이 다르다.** 본인 프로필은 앱 전역에서 계속 쓰이므로 상시 유지지만,
///    타인 프로필은 화면을 떠나면 필요 없다 → `autoDispose`. family는 인자마다
///    provider를 새로 만들기 때문에 autoDispose 없이 쓰면 방문한 사용자 수만큼
///    캐시가 무한히 쌓인다.
/// 3. **노출 범위가 다르다.** 본인 화면은 진행률·미획득 뱃지·무효 시즌까지
///    보지만, 타인 화면은 "획득한 뱃지"와 "확정된 티어"만 본다(브리핑 §AC-03).
///
/// ## 노출하지 않는 것
/// - 최근 러닝 목록: `runs` RLS를 손대지 않기로 확정했다. 타인 러닝 provider를
///   여기에 추가하지 말 것 — 추가해도 RLS가 빈 목록을 돌려주므로 화면에는
///   "기록 없음"이라는 **거짓말**이 뜬다.
/// - `weightKg` / `heightCm` / `birthDate` / `weeklyGoalKm` 등 개인 설정:
///   `profiles`가 전 컬럼 공개 SELECT라 모델에는 실려 오지만, 타인 화면에서
///   렌더링하지 않는다. 이 경계는 표현 계층의 책임이다.

/// 임의 사용자(`userId`)의 프로필. 존재하지 않으면 null.
///
/// 본인 id를 넘겨도 동작한다(같은 `profiles` 행이다). 다만 그 경우 화면은
/// 타인 프로필이 아니라 본인 프로필로 라우팅하는 편이 낫다 — 편집 진입점과
/// 미획득 뱃지가 있는 쪽이 본인에게는 더 유용하기 때문이다.
final userProfileProvider =
    FutureProvider.autoDispose.family<AppUser?, String>((ref, userId) {
  return ref.watch(userRepositoryProvider).findById(userId);
});

/// [userId]가 획득한 뱃지 목록(최신 획득 순).
///
/// 리포지토리의 `fetchUserBadges`는 이미 `revoked = false`만 거르고 `badge`를
/// 임베드하므로 본인/타인 경로가 같다. 갈라지는 지점은 **여기 위**다 —
/// 본인 갤러리는 이 목록을 카탈로그·통계와 합쳐 진행률까지 계산하지만
/// (`badgeProgressListProvider`), 타인 화면은 이 목록 자체가 최종 결과다.
/// 타인에게 미획득 뱃지·진행률을 보여줄 근거 데이터(`GamificationStats`)는
/// 애초에 얻을 수 없다(그 사용자의 러닝을 읽을 수 없으므로).
///
/// 게스트는 빈 목록이다 — `user_badges`는 authenticated 전용이라 anon 호출이
/// 권한 오류가 된다. 랭킹 화면 자체가 로그인 이후 진입점이라 실제로는 도달하지
/// 않지만, 로그아웃 직후 한 프레임을 방어한다.
final userBadgesByIdProvider =
    FutureProvider.autoDispose.family<List<UserBadge>, String>((ref, userId) {
  if (ref.watch(currentUserIdProvider) == null) return const <UserBadge>[];
  return ref.watch(gamificationRepositoryProvider).fetchUserBadges(userId);
});

/// [userId]의 끝난 시즌 결과. `bestTierOfProvider`의 입력.
///
/// RLS(`season_histories_select_visible`)가 무효(`is_voided`) 행은 본인에게만
/// 보여주므로, 타인 조회 결과에는 유효 시즌만 담긴다. 그래도 아래
/// [bestTierOfProvider]는 `isVoided`를 한 번 더 거른다 — 본인 id로 호출됐을
/// 때도 같은 의미("확정된 명예")를 내야 하기 때문이다.
final userSeasonHistoriesProvider =
    FutureProvider.autoDispose.family<List<SeasonHistory>, String>((
  ref,
  userId,
) {
  if (ref.watch(currentUserIdProvider) == null) return const <SeasonHistory>[];
  return ref.watch(seasonHistoryRepositoryProvider).fetchByUser(userId);
});

/// TI-09 역대 최고 티어의 **임의 사용자 버전**.
///
/// 기존 `bestEverTierProvider`(본인 전용)와 판정 규칙이 완전히 같아, 규칙은
/// [SeasonHistory.bestTierOf]에 한 번만 두고 양쪽이 그것을 부른다. 규칙을
/// 복제하면 "무효 시즌 제외" 같은 정책이 한쪽에만 반영되는 사고가 난다.
final bestTierOfProvider =
    Provider.autoDispose.family<Tier?, String>((ref, userId) {
  final histories =
      ref.watch(userSeasonHistoriesProvider(userId)).valueOrNull ??
          const <SeasonHistory>[];
  return SeasonHistory.bestTierOf(histories);
});
