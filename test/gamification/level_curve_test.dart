import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/gamification/domain/badge_condition.dart';
import 'package:runnit/features/gamification/domain/badge_progress.dart';
import 'package:runnit/features/gamification/domain/gamification_stats.dart';
import 'package:runnit/features/gamification/domain/level_curve.dart';
import 'package:runnit/models/models.dart';

/// 이 테스트는 **확정 규칙서와 클라이언트 구현이 갈라지지 않았음**을 잠근다.
/// 규칙서: `_workspace/20260826_000340_gamification_badge-backlog-decisions.md` §1 / §3,
/// `docs/TRD.md` §3.8 / §10.2
///
/// 여기 있는 기대값은 서버 SQL(`xp_level_thresholds` / `compute_level` /
/// `_weekly_streak_state`)의 기대값과 동일해야 한다.
/// 서버 산식을 바꾸면 이 테스트가 먼저 깨져야 정상이다.
void main() {
  group('LevelCurve — TRD §3.8.3 XP 임계값 배열', () {
    // 정본: _workspace/20260826_000340_gamification_badge-backlog-decisions.md §1.2
    // 서버 public.xp_level_thresholds() 와 **글자 그대로 같은 60개 정수**여야 한다.
    // 유도식 ceil(50 × (L−1)^2.2) 는 근거일 뿐, 계약은 이 배열이다.
    const expected = <int, int>{
      1: 0,
      2: 50,
      3: 230,
      4: 561,
      5: 1056,
      10: 6285,
      15: 16614,
      20: 32526,
      25: 54380,
      30: 82461,
      40: 158239,
      50: 261458,
      60: 393410,
    };

    test('xpRequiredFor가 확정 배열과 일치한다', () {
      expected.forEach((level, xp) {
        expect(LevelCurve.xpRequiredFor(level), xp, reason: '레벨 $level 임계값');
      });
    });

    test('만렙은 60이고 배열 길이와 같다', () {
      expect(LevelCurve.maxLevel, 60);
      expect(LevelCurve.thresholds, hasLength(60));
    });

    test('임계값이 순증가한다', () {
      for (var i = 1; i < LevelCurve.thresholds.length; i++) {
        expect(LevelCurve.thresholds[i],
            greaterThan(LevelCurve.thresholds[i - 1]),
            reason: '레벨 ${i + 1} 임계값');
      }
    });

    // ⚠️ 이 테스트를 지우지 말 것. 구 곡선에서 지수 역함수의 부동소수 오차가
    // "레벨업까지 1pt 남음"을 고착시키는 버그를 실제로 일으켰다
    // (_workspace/20260819_210450_badge_rules.md §4.3). 배열 조회로 바꾼
    // 이유가 바로 이것이고, L=2..60 전수 경계 검증이 그 재발을 막는 잠금장치다.
    test('levelForXp와 xpRequiredFor가 L=2..60 전수에서 정확히 맞물린다', () {
      for (var level = 2; level <= LevelCurve.maxLevel; level++) {
        final threshold = LevelCurve.xpRequiredFor(level);
        expect(LevelCurve.levelForXp(threshold), level,
            reason: '레벨 $level 임계값 도달');
        expect(LevelCurve.levelForXp(threshold - 1), level - 1,
            reason: '레벨 $level 임계값 1XP 미달');
      }
    });

    test('레벨 1과 음수/0 XP를 안전하게 처리한다', () {
      expect(LevelCurve.xpRequiredFor(1), 0);
      expect(LevelCurve.levelForXp(0), 1);
      expect(LevelCurve.levelForXp(-100), 1);
      expect(LevelCurve.levelProgress(0, level: 1), 0.0);
    });

    test('만렙에서 상한이 걸리고 다음 레벨이 없다', () {
      expect(LevelCurve.levelForXp(99999999), LevelCurve.maxLevel);
      expect(LevelCurve.nextLevelThreshold(LevelCurve.maxLevel), isNull);
      expect(LevelCurve.xpToNextLevel(99999999, level: 60), isNull);
      expect(LevelCurve.levelProgress(99999999, level: 60), 1.0);
      expect(LevelCurve.isMaxLevel(60), isTrue);
      expect(LevelCurve.isMaxLevel(59), isFalse);
    });

    test('구간 진행률이 0~1 사이에서 단조 증가한다', () {
      // 레벨 3 구간: 230 ~ 561
      expect(LevelCurve.levelProgress(230, level: 3), 0.0);
      expect(LevelCurve.levelProgress(561, level: 3), 1.0);
      final mid = LevelCurve.levelProgress(395, level: 3);
      expect(mid, greaterThan(0.4));
      expect(mid, lessThan(0.6));
    });

    test('다음 레벨까지 남은 XP', () {
      expect(LevelCurve.xpToNextLevel(0, level: 1), 50);
      expect(LevelCurve.xpToNextLevel(230, level: 3), 561 - 230);
      // 이미 넘겼으면 음수가 아니라 0.
      expect(LevelCurve.xpToNextLevel(999, level: 3), 0);
    });

    test('첫 러닝 1건(약 95 XP)으로 즉시 레벨 2가 된다 — 온보딩 첫 보상', () {
      expect(LevelCurve.levelForXp(95), 2);
    });
  });

  group('GamificationStats.computeWeeklyStreak — GM-05 주 단위 + 1회 유예', () {
    // 서버 public._weekly_streak_state(uuid) 의 리플레이와 **글자 그대로 같은 규칙**이어야
    // 한다. 정본: badge-backlog-decisions §3.3 / TRD §10.2.
    // 아래 기대값은 실제 Supabase 검증에서 나온 값과 동일하다(보고서 검증 §D).

    // 2026-05-04(월) 00:00 KST = 2026-05-03T15:00Z
    final baseMonday = DateTime.utc(2026, 5, 3, 15);

    RunRecord weekRun(int weekOffset, {double distanceMeters = 3000}) => RunRecord(
          id: 'r$weekOffset-\${distanceMeters.toInt()}',
          userId: 'u1',
          startedAt: baseMonday.add(Duration(days: weekOffset * 7, hours: 9)),
          endedAt: baseMonday
              .add(Duration(days: weekOffset * 7, hours: 9, minutes: 18)),
          activityType: ActivityType.outdoorRun,
          status: RunStatus.completed,
          distanceMeters: distanceMeters,
          elapsedSeconds: 1080,
          movingSeconds: 1080,
        );

    // 평가 시점: 활동 주 마지막(offset 7)로부터 한참 뒤 = offset 16 주의 수요일.
    final now = baseMonday.add(const Duration(days: 16 * 7 + 2));

    test('유예 1회가 결석 주를 메워 스트릭을 잇는다', () {
      // 활동 주 0, 2,3,4,5, 7 (1과 6 결석).
      // 0=1 / 1 유예 / 2=2 3=3 4=4 5=5(4주 연속 → 크레딧 회복) / 6 유예 / 7=6
      final runs = [0, 2, 3, 4, 5, 7].map(weekRun).toList();
      final state = GamificationStats.computeWeeklyStreak(runs, now: now);
      expect(state.longest, 6);
      // 유예 없이 세면 연속 최대 구간은 2~5의 4주뿐이다.
      expect(state.longest, greaterThan(4));
    });

    test('연속 2주 결석은 크레딧 1개로 메울 수 없어 스트릭이 끊긴다', () {
      // 활동 주 0, 3, 4 → 1·2 연속 결석에서 크레딧 소진 후 리셋.
      final runs = [0, 3, 4].map(weekRun).toList();
      final state = GamificationStats.computeWeeklyStreak(runs, now: now);
      expect(state.longest, 2); // 3,4 두 주가 최장
    });

    test('주 합산 1.0km 미만인 주는 활동 주가 아니다', () {
      // 0,2,3,4,5,7 은 3km. 결석 주 1에 800m 만 추가해도 활동 주가 되면 안 된다
      // (되면 0~5가 이어져 longest 가 8이 된다).
      final runs = [
        ...[0, 2, 3, 4, 5, 7].map(weekRun),
        weekRun(1, distanceMeters: 800),
      ];
      final state = GamificationStats.computeWeeklyStreak(runs, now: now);
      expect(state.longest, 6);
    });

    test('400m x 3회처럼 주 합산으로 1.0km를 넘기면 활동 주가 된다', () {
      final runs = [
        weekRun(0),
        RunRecord(
          id: 'a',
          userId: 'u1',
          startedAt: baseMonday.add(const Duration(days: 7, hours: 9)),
          activityType: ActivityType.outdoorRun,
          status: RunStatus.completed,
          distanceMeters: 400,
          elapsedSeconds: 200,
          movingSeconds: 200,
        ),
        RunRecord(
          id: 'b',
          userId: 'u1',
          startedAt: baseMonday.add(const Duration(days: 8, hours: 9)),
          activityType: ActivityType.outdoorRun,
          status: RunStatus.completed,
          distanceMeters: 400,
          elapsedSeconds: 200,
          movingSeconds: 200,
        ),
        RunRecord(
          id: 'c',
          userId: 'u1',
          startedAt: baseMonday.add(const Duration(days: 9, hours: 9)),
          activityType: ActivityType.outdoorRun,
          status: RunStatus.completed,
          distanceMeters: 400,
          elapsedSeconds: 200,
          movingSeconds: 200,
        ),
      ];
      final state = GamificationStats.computeWeeklyStreak(runs, now: now);
      expect(state.longest, 2);
    });

    test('진행 중인 주는 비활동으로 판정하지 않는다 — 스트릭을 끊지 않는다', () {
      // 활동 주 0,1 이고 지금은 offset 2 주의 목요일(아직 안 뛴 상태).
      final runs = [0, 1].map(weekRun).toList();
      final nowInWeek2 = baseMonday.add(const Duration(days: 2 * 7 + 3));
      final state = GamificationStats.computeWeeklyStreak(runs, now: nowInWeek2);
      expect(state.current, 2);
      expect(state.longest, 2);
      expect(state.freezeCredits, 1); // 유예를 소모하지 않았다
    });

    test('러닝이 없으면 0주 / 크레딧 1', () {
      final state = GamificationStats.computeWeeklyStreak(const [], now: now);
      expect(state.longest, 0);
      expect(state.current, 0);
      expect(state.freezeCredits, 1);
    });

    test('가입이 첫 러닝보다 늦어도 러닝을 잃지 않는다 (서버 least() 가드와 동일)', () {
      final runs = [0, 1, 2].map(weekRun).toList();
      final state = GamificationStats.computeWeeklyStreak(
        runs,
        signupAt: baseMonday.add(const Duration(days: 30)),
        now: now,
      );
      expect(state.longest, 3);
    });

    test('일 단위 스트릭과 섞이지 않는다', () {
      // 매주 1회씩 6주 → 주 단위 6, 일 단위는 1.
      final runs = [0, 1, 2, 3, 4, 5].map(weekRun).toList();
      expect(GamificationStats.computeLongestStreakWeeks(runs, now: now), 6);
      expect(GamificationStats.computeLongestStreakDays(runs), 1);
    });
  });

  group('BadgeConditionType — 39종 카탈로그 비교 방향', () {
    test('atMost 4종(pb_time_lte/pace_avg_lte/pace_variance_lte/season_weekly_rank_lte)만 뒤집힌다', () {
      const atMost = {
        BadgeConditionType.pbTimeLte,
        BadgeConditionType.paceAvgLte,
        BadgeConditionType.paceVarianceLte,
        BadgeConditionType.seasonWeeklyRankLte,
      };
      for (final type in BadgeConditionType.all) {
        final expectedDirection = atMost.contains(type)
            ? BadgeCompareDirection.atMost
            : BadgeCompareDirection.atLeast;
        expect(BadgeConditionType.compareDirectionFor(type), expectedDirection,
            reason: type);
      }
    });

    test('앱이 모르는 신규 조건은 atLeast로 안전하게 폴백한다', () {
      expect(BadgeConditionType.compareDirectionFor('brand_new_condition_v3'),
          BadgeCompareDirection.atLeast);
      expect(BadgeConditionType.isKnown('brand_new_condition_v3'), isFalse);
    });

    test('확정 집합은 39종이다 (district_diversity_gte 삭제 후)', () {
      expect(BadgeConditionType.all.length, 39);
      expect(BadgeConditionType.all, isNot(contains('district_diversity_gte')));
    });
  });

  group('BadgeProgressCalculator.ratioFor — atMost 역방향 비율', () {
    test('일반 조건은 현재값/목표값', () {
      expect(
        BadgeProgressCalculator.ratioFor(
          conditionType: BadgeConditionType.cumulativeDistanceGte,
          target: 10000,
          currentValue: 3000,
        ),
        closeTo(0.3, 1e-9),
      );
    });

    test('atMost 조건은 비율을 뒤집는다', () {
      // 목표 5'00"(300s), 현재 최고 6'00"(360s) → 300/360 = 0.833
      // 뒤집지 않으면 360/300 = 1.2가 되어 이미 달성한 것처럼 보인다.
      expect(
        BadgeProgressCalculator.ratioFor(
          conditionType: BadgeConditionType.paceAvgLte,
          target: 300,
          currentValue: 360,
        ),
        closeTo(300 / 360, 1e-9),
      );
    });

    test('기록이 없으면(null) 진행률 0 — 뱃지가 공짜로 채워지지 않는다', () {
      expect(
        BadgeProgressCalculator.ratioFor(
          conditionType: BadgeConditionType.paceAvgLte,
          target: 420,
          currentValue: null,
        ),
        0.0,
      );
    });

    test('비율은 1.0을 넘지 않는다', () {
      expect(
        BadgeProgressCalculator.ratioFor(
          conditionType: BadgeConditionType.cumulativeDistanceGte,
          target: 1000,
          currentValue: 999999,
        ),
        1.0,
      );
    });
  });

  group('BadgeProgressCalculator.forCatalog — 시즌 뱃지 필터링', () {
    Badge seasonalBadge({required String id, String? seasonId}) => Badge(
          id: id,
          name: id,
          description: id,
          category: BadgeCategory.seasonEvent,
          scope: BadgeScope.seasonal,
          triggerType: BadgeTriggerType.cumulative,
          conditionType: BadgeConditionType.cumulativeDistanceGte,
          badgeGrade: 'bronze',
          seasonId: seasonId,
        );

    test('seasonId가 null인 시즌 템플릿은 미획득이면 제외된다', () {
      final result = BadgeProgressCalculator.forCatalog(
        catalog: [seasonalBadge(id: 'a', seasonId: null)],
        earnedBadges: const [],
        stats: GamificationStats.empty,
        currentSeasonId: '2026-Q3',
      );
      expect(result, isEmpty);
    });

    test('현재 시즌과 다른 seasonId는 미획득이면 제외된다', () {
      final result = BadgeProgressCalculator.forCatalog(
        catalog: [seasonalBadge(id: 'a', seasonId: '2026-Q2')],
        earnedBadges: const [],
        stats: GamificationStats.empty,
        currentSeasonId: '2026-Q3',
      );
      expect(result, isEmpty);
    });

    test('currentSeasonId를 모를 때(null)도 seasonId=null 템플릿은 제외된다', () {
      final result = BadgeProgressCalculator.forCatalog(
        catalog: [seasonalBadge(id: 'a', seasonId: null)],
        earnedBadges: const [],
        stats: GamificationStats.empty,
        currentSeasonId: null,
      );
      expect(result, isEmpty);
    });

    test('현재 시즌과 일치하는 seasonId는 포함된다', () {
      final result = BadgeProgressCalculator.forCatalog(
        catalog: [seasonalBadge(id: 'a', seasonId: '2026-Q3')],
        earnedBadges: const [],
        stats: GamificationStats.empty,
        currentSeasonId: '2026-Q3',
      );
      expect(result, hasLength(1));
    });

    test('시즌 카테고리는 정렬에서 영구 카테고리보다 앞에 온다(2026-08-25 요청)', () {
      const permanent = Badge(
        id: 'z_permanent',
        name: 'z',
        description: 'z',
        category: BadgeCategory.cumulativeDistance,
        scope: BadgeScope.permanent,
        triggerType: BadgeTriggerType.cumulative,
        conditionType: BadgeConditionType.cumulativeDistanceGte,
        badgeGrade: 'bronze',
      );
      final seasonal =
          seasonalBadge(id: 'a_seasonal', seasonId: '2026-Q3');
      final result = BadgeProgressCalculator.forCatalog(
        catalog: [permanent, seasonal],
        earnedBadges: const [],
        stats: GamificationStats.empty,
        currentSeasonId: '2026-Q3',
      );
      expect(result.map((p) => p.badge.id).toList(),
          ['a_seasonal', 'z_permanent']);
    });

    test('지난 시즌이라도 이미 획득했으면 갤러리에서 사라지지 않는다', () {
      final earnedAt = DateTime(2026, 6, 1);
      final result = BadgeProgressCalculator.forCatalog(
        catalog: [seasonalBadge(id: 'a', seasonId: null)],
        earnedBadges: [
          UserBadge(
            id: 'ub1',
            userId: 'u1',
            badgeId: 'a',
            earnedAt: earnedAt,
            verified: true,
          ),
        ],
        stats: GamificationStats.empty,
        currentSeasonId: '2026-Q3',
      );
      expect(result, hasLength(1));
      expect(result.single.isEarned, isTrue);
    });
  });
}
