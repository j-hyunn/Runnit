/// 공유 카드(HI-08) + 성취 큐(HI-10)의 Riverpod 계약.
///
/// ## 핵심 발견 — 트리거 3종이 이미 **하나의 큐**로 모인다
/// 티어 승급 / 뱃지 획득 / PB 갱신은 서로 다른 사건처럼 보이지만, 서버는 셋 다
/// `user_badges` INSERT로 끝낸다:
///
/// | HI-10 트리거 | 서버가 만드는 행 | 판별 방법 |
/// |---|---|---|
/// | 티어 승급 | `stier_{tier}@{seasonId}` 인스턴스 (마이그레이션 31/32, `season_tier_reached`) | `Badge.category == seasonTier` |
/// | 뱃지 획득 | 해당 뱃지 (마이그레이션 27/41 `evaluate_badges`) | 나머지 카테고리 |
/// | PB 갱신 | `pb_*` 뱃지 (`pb_first_achieved` / `pb_time_lte`) | `Badge.category == personalBest` |
///
/// `user_badges`는 realtime publication에 들어 있고(07_rls.sql), 리포지토리에
/// [GamificationRepository.watchUnseenBadges]가 이미 있다. **다만 지금까지
/// 어떤 화면도 그 스트림을 구독하지 않아 `is_seen`은 영원히 false였다.**
/// 여기가 그 첫 소비자다.
///
/// 그래서 축하 연출 트리거를 세 벌 만들지 않는다 — 큐 하나를 구독하고, 카드
/// 종류만 카테고리로 갈라진다.
///
/// ## `verified`에 대해
/// 서버는 판정 통과분을 `verified = true`로 넣는다(마이그레이션 27 §567). 즉
/// 큐에 뜬 시점에 이미 서버 확정이다 — 클라이언트가 "가채점"한 성취를 축하했다가
/// 나중에 뒤집히는 상황은 구조적으로 없다. 이것이 클라이언트 판정을 두지 않은
/// 이유이자, 공유 카드가 서버 값만 그리는 이유다.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/providers/repository_providers.dart';
import '../../../core/repositories/gamification_repository.dart';
import '../../../models/models.dart';
import '../../ranking/data/ranking_providers.dart';
import '../domain/share_card_builder.dart';
import '../domain/share_card_data.dart';
import 'share_service.dart';

final shareServiceProvider = Provider<ShareService>(
  (ref) => const ShareServiceImpl(),
);

/// 아직 축하 연출을 보여주지 않은 성취 큐. 오래된 것부터(서버 정렬 그대로).
///
/// 게스트면 빈 목록 — 러닝 자체가 로그인 사용자만 가능하다.
/// 러닝 업로드 → 서버 판정 → realtime push 경로라 **요약 화면이 떠 있는 동안
/// 뒤늦게 도착**할 수 있다. UI는 이 스트림을 `listen`해 큐가 비→참으로 바뀔 때
/// 연출을 띄운다(한 번 보여준 뒤 [markAchievementsSeen] 호출).
final pendingAchievementsProvider =
    StreamProvider<List<UserBadge>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const <UserBadge>[]);
  return ref.watch(gamificationRepositoryProvider).watchUnseenBadges(userId);
});

/// 큐의 맨 앞 1건. 연출은 한 번에 하나씩 보여준다 —
/// 10km 달성 러닝 하나가 뱃지를 5개 터뜨리는 일이 실제로 있고, 다이얼로그 5개가
/// 동시에 쌓이면 아무것도 축하가 되지 않는다.
final nextAchievementProvider = Provider<UserBadge?>((ref) {
  final queue = ref.watch(pendingAchievementsProvider).valueOrNull;
  return (queue == null || queue.isEmpty) ? null : queue.first;
});

/// 성취 1건을 [RunRecord]·프로필·순위와 합쳐 공유 카드로 만든다.
///
/// 비동기인 이유: [UserBadge.sourceRunId]로 러닝을 한 건 더 조회해야 경로를 그릴
/// 수 있다. 조회가 실패하거나 러닝이 이미 삭제됐어도 **카드는 만들어진다**
/// (경로만 빠진다) — 공유를 막을 이유가 아니다.
///
/// 카탈로그 조인이 비어 있거나(이론상만 존재) 프로필을 못 읽으면 null.
final shareCardForAchievementProvider =
    FutureProvider.family<ShareCardData?, UserBadge>((ref, userBadge) async {
  final user = await ref.watch(currentProfileProvider.future);
  if (user == null) return null;

  final sourceRun = await ref.watch(_sourceRunProvider(userBadge.sourceRunId).future);

  // 티어 카드에만 필요한 값이라 그 외에는 조회 자체를 건너뛴다.
  final needsRank = userBadge.badge?.category == BadgeCategory.seasonTier;
  final myRank =
      needsRank ? await ref.watch(myTierRankProvider.future) : null;

  return ShareCardBuilder.fromUserBadge(
    userBadge: userBadge,
    user: user,
    sourceRun: sourceRun,
    myRank: myRank,
  );
});

/// "지금 내 티어를 자랑한다" — 성취 직후가 아니라 홈/프로필에서 여는 경로.
/// 승급 순간이 아니므로 [ShareCardData.achievedAt]은 조회 시각이다.
final currentTierShareCardProvider =
    FutureProvider<TierPromotionCardData?>((ref) async {
  final user = await ref.watch(currentProfileProvider.future);
  if (user == null) return null;
  final myRank = await ref.watch(myTierRankProvider.future);
  return ShareCardBuilder.fromProfile(user: user, myRank: myRank);
});

/// 러닝 1건을 그 자리에서 카드 데이터로 — 트래킹 요약 화면(`_SummaryView`)처럼
/// 이미 `RunRecord`를 손에 쥐고 있는 곳에서 쓴다. 성취가 없어도 경로/거리만으로
/// 카드를 만들 수 있게 [ShareCardBuilder.routeOf]를 노출한다.
ShareRoute? shareRouteOf(RunRecord? run) => ShareCardBuilder.routeOf(run);

/// 연출을 보여준 뒤 호출한다. 서버 `is_seen`을 true로 바꿔 큐에서 빼며,
/// 이것이 **클라이언트가 `user_badges`에 쓸 수 있는 유일한 컬럼**이다.
///
/// 실패해도 조용히 넘긴다 — 다음 실행에서 연출을 한 번 더 보는 정도의 손해이고,
/// 축하 화면을 닫는 동작이 네트워크 오류로 막히는 쪽이 훨씬 나쁘다.
Future<void> markAchievementsSeen(Ref ref, List<String> userBadgeIds) =>
    _markSeen(ref.read(gamificationRepositoryProvider), userBadgeIds);

/// 위젯(축하 연출)에서 부르는 같은 동작.
///
/// Riverpod 2.x의 `Ref`(provider)와 `WidgetRef`(위젯)는 공통 상위 타입이 없어서
/// 하나의 시그니처로는 양쪽에서 못 부른다. 동작 본체는 [_markSeen] 하나뿐이라
/// 두 경로가 갈라질 여지는 없다.
Future<void> markAchievementsSeenFrom(
  WidgetRef ref,
  List<String> userBadgeIds,
) =>
    _markSeen(ref.read(gamificationRepositoryProvider), userBadgeIds);

Future<void> _markSeen(
  GamificationRepository repository,
  List<String> userBadgeIds,
) async {
  if (userBadgeIds.isEmpty) return;
  try {
    await repository.markBadgesSeen(userBadgeIds);
  } catch (_) {
    // 무시 — 다음 스트림 갱신에서 다시 큐에 오를 뿐이다.
  }
}

/// [UserBadge.sourceRunId] → [RunRecord]. null이면 조회하지 않는다.
///
/// `includeSamples: true`로 부르는 이유: 카드의 경로 그림에는 좌표가 필요하고,
/// 목록 조회 경로로 받은 레코드는 `samples`가 비어 있다(payload 절감 규약).
final _sourceRunProvider =
    FutureProvider.family<RunRecord?, String?>((ref, runId) async {
  if (runId == null) return null;
  try {
    return await ref
        .watch(runRepositoryProvider)
        .findById(runId, includeSamples: true);
  } catch (_) {
    return null; // 경로 없는 카드로 폴백.
  }
});
