import 'package:flutter_test/flutter_test.dart';
import 'package:runnit/features/gamification/domain/badge_condition.dart';
import 'package:runnit/features/gamification/domain/badge_progress.dart';
import 'package:runnit/features/gamification/domain/gamification_stats.dart';
import 'package:runnit/features/gamification/domain/level_curve.dart';
import 'package:runnit/models/models.dart';

/// 이 테스트는 **확정 규칙서와 클라이언트 구현이 갈라지지 않았음**을 잠근다.
/// 규칙서: `_workspace/20260819_210450_badge_rules.md` §1.1 / §4
///
/// 여기 있는 기대값은 서버 SQL(`compute_level`)의 기대값과 동일해야 한다.
/// 서버 산식을 바꾸면 이 테스트가 먼저 깨져야 정상이다.
void main() {
  group('LevelCurve — 규칙서 §4 곡선표', () {
    // 규칙서 §4.2 표와 동일한 값.
    const expected = <int, int>{
      2: 500,
      3: 1516,
      4: 2900,
      5: 4595,
      10: 16818,
      20: 55588,
      30: 109347,
      50: 253096,
      100: 779806,
    };

    test('pointsRequiredFor가 문서 표와 일치한다', () {
      expected.forEach((level, points) {
        expect(LevelCurve.pointsRequiredFor(level), points,
            reason: '레벨 $level 임계값');
      });
    });

    test('levelForPoints와 pointsRequiredFor가 정확히 맞물린다', () {
      // 임계값에서 정확히 레벨업하고, 1pt 모자라면 이전 레벨에 머물러야 한다.
      // 이 경계가 어긋나면 사용자가 "500점인데 왜 레벨 2가 아니냐"를 겪는다.
      for (var level = 2; level <= LevelCurve.maxLevel; level++) {
        final threshold = LevelCurve.pointsRequiredFor(level);
        expect(LevelCurve.levelForPoints(threshold), level,
            reason: '레벨 $level 임계값 도달');
        expect(LevelCurve.levelForPoints(threshold - 1), level - 1,
            reason: '레벨 $level 임계값 1pt 미달');
      }
    });

    test('레벨 1과 음수/0 포인트를 안전하게 처리한다', () {
      expect(LevelCurve.pointsRequiredFor(1), 0);
      expect(LevelCurve.levelForPoints(0), 1);
      expect(LevelCurve.levelForPoints(-100), 1);
      expect(LevelCurve.levelProgress(0, level: 1), 0.0);
    });

    test('만렙에서 상한이 걸리고 다음 레벨이 없다', () {
      expect(LevelCurve.levelForPoints(99999999), LevelCurve.maxLevel);
      expect(LevelCurve.nextLevelThreshold(LevelCurve.maxLevel), isNull);
      expect(LevelCurve.pointsToNextLevel(99999999, level: 100), isNull);
      expect(LevelCurve.levelProgress(99999999, level: 100), 1.0);
    });

    test('구간 진행률이 0~1 사이에서 단조 증가한다', () {
      // 레벨 3 구간: 1516 ~ 2900
      expect(LevelCurve.levelProgress(1516, level: 3), 0.0);
      expect(LevelCurve.levelProgress(2900, level: 3), 1.0);
      final mid = LevelCurve.levelProgress(2208, level: 3);
      expect(mid, greaterThan(0.4));
      expect(mid, lessThan(0.6));
    });

    test('다음 레벨까지 남은 포인트', () {
      expect(LevelCurve.pointsToNextLevel(0, level: 1), 500);
      expect(LevelCurve.pointsToNextLevel(1516, level: 3), 2900 - 1516);
    });
  });

  group('BadgeConditionType — 40종 카탈로그 비교 방향', () {
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

    test('확정 집합은 40종이다', () {
      expect(BadgeConditionType.all.length, 40);
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
