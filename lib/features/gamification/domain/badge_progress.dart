
/// 뱃지 갤러리 진행률의 **낙관적 추정** — 표시 전용.
///
/// ## 이 파일이 하지 않는 것
/// **뱃지를 획득 처리하지 않는다.** [BadgeProgress.isEarned]는 서버가 내려준
/// `UserBadge` 목록에서만 나오고, [BadgeProgress.ratio]는 순전히 프로그레스 바를
/// 그리기 위한 숫자다. 비율이 1.0이어도 서버가 지급하기 전까지는 미획득이다
/// (`meetsThresholdLocally`가 true인데 `isEarned`가 false인 상태 — UI는 이를
/// "곧 지급됩니다" 정도로만 표현하고, 획득 연출을 재생해서는 안 된다).
///
/// 획득 판정은 서버가 러닝 업로드 시점에 재검증한다.
///
/// ## 추정이 틀릴 수 있는 지점 / 아예 추정하지 않는 지점
/// - 로컬에 없는 러닝(다른 기기)이 빠져 **과소** 추정될 수 있다.
/// - 서버가 `is_flagged`로 제외한 러닝을 클라이언트는 알 수 없어 **과대** 추정될 수 있다.
/// - `BadgeConditionType.evaluabilityOf`가 `clientPartial`/`serverOnly`로 분류한
///   조건은 [currentValueFor]가 항상 null을 반환한다 — 진행률 바 없이 조건 설명
///   텍스트만 보여준다(`_workspace/20260825_architect_badge-model-v2.md` §4).
///   `clientEstimable`로 분류돼 있어도 아직 [GamificationStats]에 해당 지표를
///   수집하는 코드가 없으면(예: 스트릭 주 단위, 시간대별 집계, 페이스 변동성)
///   마찬가지로 null이다 — 이번 마이그레이션은 모델·분류 체계까지만이고, 지표
///   수집 확장은 후속 작업이다(위 문서 §7).
library;

import '../../../models/models.dart';
import 'badge_condition.dart';
import 'gamification_stats.dart';

/// 뱃지 1개에 대한 진행 상태.
class BadgeProgress {
  const BadgeProgress({
    required this.badge,
    required this.isEarned,
    required this.earnedAt,
    required this.currentValue,
    required this.ratio,
    required this.meetsThresholdLocally,
  });

  final Badge badge;

  /// **서버가 확정한** 획득 여부. `UserBadge` 존재 여부로만 결정된다.
  final bool isEarned;

  /// 서버가 확정한 획득 시각. 미획득이면 null.
  final DateTime? earnedAt;

  /// 현재 지표값(추정). 알 수 없으면(서버 전용/미수집 지표) null.
  final double? currentValue;

  /// 0.0~1.0 진행률. 값을 모르면 0.0, 획득했으면 1.0.
  final double ratio;

  /// 로컬 추정만으로는 임계값을 넘은 상태. **획득이 아니다.**
  /// [isEarned]가 false인데 이 값이 true면 "서버 반영 대기" 구간이다.
  final bool meetsThresholdLocally;
}

/// 진행률 계산기. 모든 메서드가 순수 함수다.
class BadgeProgressCalculator {
  const BadgeProgressCalculator._();

  /// 카탈로그 전체에 대한 진행 상태를 만든다.
  ///
  /// [earnedBadges]는 서버에서 받은 `UserBadge` 목록이며, 이것만이 획득의 근거다.
  /// [stats]는 표시용 추정 통계(`GamificationStats`).
  ///
  /// `scope == seasonal`이면서 **현재 시즌 인스턴스가 아닌** 뱃지는 제외한다 —
  /// 지난 시즌 템플릿은 신규 획득이 불가능하므로 진행률을 보여주면 오해를 부른다.
  /// `seasonId == null`인 시즌 뱃지는 아직 특정 시즌에 배정되지 않은 **카탈로그
  /// 원본 템플릿**이라 마찬가지로 제외한다(현재 시즌 인스턴스가 별도 행으로
  /// 존재하지 않는 한 진행률을 보여줄 대상이 없다).
  /// 단 **이미 획득한 것은 유지**해 갤러리에서 사라지지 않게 한다.
  static List<BadgeProgress> forCatalog({
    required Iterable<Badge> catalog,
    required Iterable<UserBadge> earnedBadges,
    required GamificationStats stats,
    String? currentSeasonId,
  }) {
    final earnedAtById = <String, DateTime>{
      for (final ub in earnedBadges) ub.badgeId: ub.earnedAt,
    };

    final result = <BadgeProgress>[];
    for (final badge in catalog) {
      final earnedAt = earnedAtById[badge.id];
      final isStaleSeasonal = badge.scope == BadgeScope.seasonal &&
          (badge.seasonId == null || badge.seasonId != currentSeasonId);
      if (isStaleSeasonal && earnedAt == null) continue;
      result.add(forBadge(badge: badge, earnedAt: earnedAt, stats: stats));
    }
    result.sort((a, b) {
      final category = _categorySortRank(a.badge.category)
          .compareTo(_categorySortRank(b.badge.category));
      if (category != 0) return category;
      final grade = badgeGradeOrder(a.badge.badgeGrade)
          .compareTo(badgeGradeOrder(b.badge.badgeGrade));
      if (grade != 0) return grade;
      return a.badge.id.compareTo(b.badge.id);
    });
    return result;
  }

  /// 뱃지 1개의 진행 상태.
  static BadgeProgress forBadge({
    required Badge badge,
    required DateTime? earnedAt,
    required GamificationStats stats,
  }) {
    final isEarned = earnedAt != null;
    final current = currentValueFor(badge.conditionType, badge.condition, stats);
    final direction = BadgeConditionType.compareDirectionFor(badge.conditionType);
    final target = targetOf(badge.condition);

    final meets = current != null &&
        target != null &&
        (direction == BadgeCompareDirection.atMost
            ? current <= target
            : current >= target);

    return BadgeProgress(
      badge: badge,
      isEarned: isEarned,
      earnedAt: earnedAt,
      currentValue: current,
      ratio: isEarned
          ? 1.0
          : ratioFor(
              conditionType: badge.conditionType,
              target: target,
              currentValue: current,
            ),
      meetsThresholdLocally: meets,
    );
  }

  /// 조건의 목표값. `condition` 맵의 관용적인 키(`distanceKm`/`count`/`seconds`/`weeks`/
  /// `meters`/`pct`)를 순서대로 찾는다 — 조건마다 파라미터 키가 달라 일반화하기
  /// 어렵지만, `gte`/`lte` 계열 대부분이 이 중 하나를 단일 임계값으로 쓴다.
  /// 못 찾으면 null(진행률 계산 불가).
  static double? targetOf(Map<String, dynamic> condition) {
    for (final key in ['distanceKm', 'count', 'seconds', 'weeks', 'meters', 'pct']) {
      final value = condition[key];
      if (value is num) return value.toDouble();
    }
    return null;
  }

  /// 조건별 현재값. [BadgeConditionType.evaluabilityOf]가 `clientEstimable`인
  /// 것 중 [GamificationStats]가 실제로 수집하는 지표만 값을 낸다 — 나머지는
  /// 분류상 client여도 아직 수집 코드가 없어 null이다(클래스 doc 참고).
  ///
  /// 모르는 `conditionType`(앱보다 새로운 뱃지)이거나 partial/server 분류면 null을
  /// 반환해 UI가 진행률 없이 조건 텍스트만 보여주도록 한다.
  static double? currentValueFor(
    String conditionType,
    Map<String, dynamic> condition,
    GamificationStats s,
  ) {
    if (BadgeConditionType.evaluabilityOf(conditionType) !=
        BadgeEvaluability.clientEstimable) {
      return null;
    }
    switch (conditionType) {
      case BadgeConditionType.cumulativeDistanceGte:
        return s.totalDistanceMeters / 1000.0; // condition의 distanceKm과 단위 맞춤
      case BadgeConditionType.cumulativeCountGte:
        return s.totalRunCount.toDouble();
      case BadgeConditionType.sessionDistanceGte:
        return s.maxSingleRunDistanceMeters / 1000.0;
      case BadgeConditionType.elevationGainCumulativeGte:
        return s.totalElevationGainMeters;
      default:
        // streakWeeksGte(주 단위 스트릭), pbFirstAchieved/pbTimeLte(거리별 PB),
        // sessionDurationGte, sessionStartHourCountGte, weekday/weekend 집계,
        // dayOfWeek 집계, loopCourseCountGte, membershipAnniversaryRun,
        // pace 계열(avg/negativeSplit/finalKmFaster/variance), device 계열 —
        // clientEstimable로 분류돼 있으나 GamificationStats가 아직 이 값들을
        // 수집하지 않는다. 후속 작업으로 확장 필요
        // (`_workspace/20260825_architect_badge-model-v2.md` §7).
        return null;
    }
  }

  /// 0.0~1.0 진행률.
  ///
  /// atMost 조건(작을수록/앞순위일수록 좋음)은 단순 나눗셈이 성립하지 않는다.
  /// 예를 들어 목표가 5'00"/km(300s)인데 현재 최고가 6'00"(360s)라면
  /// `360/300 = 1.2`가 되어 이미 달성한 것처럼 보인다. 그래서 **비율을 뒤집어**
  /// `target / current`로 계산한다(360초 → 300/360 = 0.83).
  static double ratioFor({
    required String conditionType,
    required double? target,
    required double? currentValue,
  }) {
    if (currentValue == null || target == null || target <= 0) return 0.0;
    final direction = BadgeConditionType.compareDirectionFor(conditionType);
    if (direction == BadgeCompareDirection.atMost) {
      if (currentValue <= 0) return 0.0;
      return (target / currentValue).clamp(0.0, 1.0);
    }
    return (currentValue / target).clamp(0.0, 1.0);
  }
}

/// 갤러리 정렬 순서 — **시즌 카테고리를 맨 앞으로** 옮긴다(2026-08-25 요청).
/// `BadgeCategory` 선언 순서(영구 11종 다음에 시즌 종)를 그대로 정렬에 쓰면
/// 시즌 섹션이 맨 밑으로 가버려서, 정렬 전용 랭크를 따로 둔다.
/// 나머지 11종은 기존 선언 순서를 그대로 유지한다.
/// (`seasonCumulativeDistance`/`seasonFinisher`는 2026-08-26 카테고리 자체를
/// 삭제했다 — 더 이상 이 함수가 다룰 대상이 아니다.)
int _categorySortRank(BadgeCategory category) => switch (category) {
      BadgeCategory.seasonTier => 0,
      BadgeCategory.seasonWeeklyRank => 1,
      BadgeCategory.seasonEvent => 2,
      _ => 10 + category.index,
    };
