// Material의 `Badge` 위젯과 도메인 모델 `Badge`가 이름 충돌하므로 위젯 쪽을 숨긴다.
import 'package:flutter/material.dart' hide Badge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:runnit/core/auth/auth_providers.dart';
import 'package:runnit/core/error/failure.dart';
import 'package:runnit/core/providers/repository_providers.dart';
import 'package:runnit/core/repositories/gamification_repository.dart';
import 'package:runnit/core/repositories/season_history_repository.dart';
import 'package:runnit/core/repositories/user_repository.dart';
import 'package:runnit/core/theme/app_theme.dart';
import 'package:runnit/features/home/presentation/widgets/ranking_widgets.dart';
import 'package:runnit/features/profile/presentation/user_profile_page.dart';
import 'package:runnit/models/models.dart';

/// AC-03 타인 프로필 화면.
///
/// 검증의 무게중심은 "무엇이 보이는가"보다 **"무엇이 보이지 않는가"**에 있다.
/// `profiles`는 전 컬럼 공개 SELECT라 체중·신장·주간목표가 모델에 실려서 온다 —
/// 서버가 막아주지 않으므로 화면이 그리지 않는 것이 유일한 방어선이고, 회귀하면
/// 조용히 개인정보가 새는 종류의 버그다. 그래서 그 부재를 테스트로 못 박는다.
void main() {
  // 노출 금지 필드에 **화면 어디에도 우연히 나타나지 않을** 값을 넣는다.
  // 노출 허용 값(거리/횟수/레벨/시즌 거리)과 숫자가 겹치면 테스트가 무의미해진다.
  const otherUser = 'user-other';

  AppUser profile({
    String? displayName = '러너B',
    Tier currentTier = Tier.gold,
    double seasonDistanceMeters = 30000,
  }) =>
      AppUser(
        id: otherUser,
        username: 'runner_b',
        displayName: displayName,
        // ── 노출 금지 ──
        weightKg: 68.5,
        heightCm: 177,
        weeklyGoalKm: 42,
        birthDate: DateTime.utc(1993, 3, 3),
        // ── 노출 허용 ──
        totalDistanceMeters: 123450,
        totalRunCount: 21,
        level: 7,
        currentTier: currentTier,
        seasonDistanceMeters: seasonDistanceMeters,
        createdAt: DateTime.utc(2026, 1, 1),
      );

  Badge badge(String id, String name) => Badge(
        id: id,
        name: name,
        description: '설명',
        category: BadgeCategory.cumulativeDistance,
        scope: BadgeScope.permanent,
        triggerType: BadgeTriggerType.cumulative,
        conditionType: 'cumulative_distance_gte',
        badgeGrade: 'gold',
      );

  UserBadge earned(String badgeId, String name) => UserBadge(
        id: 'ub-$badgeId',
        userId: otherUser,
        badgeId: badgeId,
        earnedAt: DateTime.utc(2026, 6, 1),
        verified: true,
        badge: badge(badgeId, name),
      );

  SeasonHistory season(String seasonId, Tier tier) => SeasonHistory(
        id: 'sh-$seasonId',
        userId: otherUser,
        seasonId: seasonId,
        finalTier: tier,
        distanceMeters: 90000,
        runCount: 9,
        movingSeconds: 3600,
        closedAt: DateTime.utc(2026, 4, 1),
      );

  Future<void> pump(
    WidgetTester tester, {
    AppUser? user,
    List<UserBadge> badges = const [],
    List<SeasonHistory> histories = const [],
    bool profileFails = false,
    bool badgesFail = false,
    String? myUserId = 'user-me',
  }) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue(myUserId),
          userRepositoryProvider.overrideWithValue(
            _FakeUserRepository(user: user, fails: profileFails),
          ),
          gamificationRepositoryProvider.overrideWithValue(
            _FakeGamificationRepository(badges: badges, fails: badgesFail),
          ),
          seasonHistoryRepositoryProvider.overrideWithValue(
            _FakeSeasonHistoryRepository(histories),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const UserProfilePage(userId: otherUser),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('공개 항목(티어·시즌 진행률·누적 요약·역대 최고 티어)을 보여준다',
      (tester) async {
    await pump(
      tester,
      user: profile(),
      histories: [season('2026-Q1', Tier.silver), season('2026-Q2', Tier.platinum)],
    );

    expect(find.text('러너B'), findsOneWidget);
    expect(find.text('@runner_b'), findsOneWidget);

    // 현재 티어 + 역대 최고 티어(무효 없음 → platinum) 둘 다 배지로 나온다.
    expect(find.text('Gold'), findsOneWidget);
    expect(find.text('Platinum'), findsOneWidget);
    expect(find.text('역대 최고 티어'), findsOneWidget);

    // 누적 요약 3분할.
    expect(find.text('123.5km'), findsOneWidget);
    expect(find.text('21'), findsOneWidget);
    expect(find.text('Lv.7'), findsOneWidget);

    // 시즌 진행률: gold(100km) → platinum(250km) 구간, 시즌 30km.
    expect(find.text('30.0'), findsOneWidget);
    expect(find.text('다음 티어까지 220.0km'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNotNull);
  });

  testWidgets('체중·신장·생년월일·주간목표는 어디에도 렌더링하지 않는다', (tester) async {
    await pump(tester, user: profile());

    for (final secret in ['68.5', '177', '42', '1993']) {
      expect(
        find.textContaining(secret),
        findsNothing,
        reason: '개인 설정 값 "$secret"이(가) 타인 프로필에 노출됐다',
      );
    }
    // 개별 러닝 목록으로 이어지는 요소도 없어야 한다.
    expect(find.textContaining('기록 없음'), findsNothing);
  });

  testWidgets('획득 뱃지만 그린다 — 미획득/진행률 바가 없다', (tester) async {
    await pump(
      tester,
      user: profile(),
      badges: [earned('dist_100km', '백리길'), earned('dist_1000km', '천리길')],
    );

    expect(find.text('백리길'), findsOneWidget);
    expect(find.text('천리길'), findsOneWidget);
    expect(find.text('2개'), findsOneWidget);

    // 진행률 바는 시즌 카드의 티어 바 **하나뿐**이어야 한다. 뱃지 타일에
    // 진행률이 붙으면 남의 미달성을 전시하는 화면이 된다.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('뱃지가 없으면 빈 상태 문구를 보여준다', (tester) async {
    await pump(tester, user: profile(), badges: const []);
    expect(find.text('아직 획득한 뱃지가 없어요'), findsOneWidget);
  });

  testWidgets('끝난 시즌이 없으면 역대 최고 티어는 "아직 없어요"', (tester) async {
    await pump(tester, user: profile(), histories: const []);
    expect(find.text('아직 없어요'), findsOneWidget);
  });

  testWidgets('없는 사용자면 안내를 보여준다', (tester) async {
    await pump(tester, user: null);
    expect(find.text('찾을 수 없는 사용자예요'), findsOneWidget);
  });

  testWidgets('프로필 조회 실패는 재시도 버튼과 함께 안내한다', (tester) async {
    await pump(tester, profileFails: true);
    expect(find.text('프로필을 불러오지 못했어요'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
  });

  testWidgets('뱃지 조회만 실패해도 프로필 본문은 유지된다', (tester) async {
    await pump(tester, user: profile(), badgesFail: true);
    expect(find.text('러너B'), findsOneWidget);
    expect(find.text('뱃지를 불러오지 못했어요'), findsOneWidget);
  });

  testWidgets('게스트(currentUserId=null)면 뱃지 조회를 시도하지 않는다', (tester) async {
    // provider가 게스트를 빈 목록으로 단락시킨다 — `user_badges`는
    // authenticated 전용이라 anon 호출이 권한 오류가 되기 때문이다.
    await pump(tester, user: profile(), myUserId: null);
    expect(find.text('아직 획득한 뱃지가 없어요'), findsOneWidget);
  });

  testWidgets('랭킹 행은 onTap이 주어질 때만 탭에 반응한다', (tester) async {
    var tapped = 0;
    final entry = RankingEntry(
      userId: otherUser,
      username: 'runner_b',
      rank: 3,
      metric: RankingMetric.distance,
      score: 12300,
      period: RankingPeriod.weekly,
      scope: RankingScope.global,
      periodStart: DateTime.utc(2026, 8, 24),
      periodEnd: DateTime.utc(2026, 8, 30),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              RunnerListTile(entry: entry, onTap: () => tapped++),
              RunnerListTile(entry: entry),
            ],
          ),
        ),
      ),
    );

    // 두 행 모두 같은 이름을 그리므로 InkWell 유무로 구분한다.
    expect(find.byType(InkWell), findsOneWidget);
    await tester.tap(find.byType(InkWell));
    expect(tapped, 1);
  });
}

class _FakeUserRepository implements UserRepository {
  _FakeUserRepository({this.user, this.fails = false});

  final AppUser? user;
  final bool fails;

  @override
  Future<AppUser?> findById(String userId) async {
    if (fails) throw const Failure.network(message: 'boom');
    return user;
  }

  @override
  Future<AppUser?> currentUser() async => user;

  @override
  Stream<AppUser?> watchCurrentUser() => Stream.value(user);

  @override
  Future<AppUser> updateProfile(AppUser user) async => user;
}

class _FakeGamificationRepository implements GamificationRepository {
  _FakeGamificationRepository({required this.badges, this.fails = false});

  final List<UserBadge> badges;
  final bool fails;

  @override
  Future<List<UserBadge>> fetchUserBadges(String userId) async {
    if (fails) throw const Failure.network(message: 'boom');
    return badges;
  }

  @override
  Future<List<Badge>> fetchBadgeCatalog() async => const [];

  @override
  Stream<List<UserBadge>> watchUnseenBadges(String userId) =>
      const Stream.empty();

  @override
  Future<void> markBadgesSeen(List<String> userBadgeIds) async {}

  @override
  Future<List<Challenge>> fetchChallenges({
    ChallengeStatus? status,
    String? crewId,
  }) async =>
      const [];

  @override
  Future<List<ChallengeParticipation>> fetchMyParticipations(String userId) async =>
      const [];

  @override
  Future<void> joinChallenge({
    required String challengeId,
    required String userId,
  }) async {}
}

class _FakeSeasonHistoryRepository implements SeasonHistoryRepository {
  _FakeSeasonHistoryRepository(this.histories);

  final List<SeasonHistory> histories;

  @override
  Future<List<SeasonHistory>> fetchByUser(String userId) async => histories;
}
