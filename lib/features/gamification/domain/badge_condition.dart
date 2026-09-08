/// 뱃지 판정 조건(`Badge.conditionType`)의 **확정된 유한 집합**과 판정 주체 분류.
///
/// 정본은 `docs/badge-catalog.csv`(146종)이며, 서버 `badges` 테이블에는 동일 목록이
/// `condition_type` CHECK 제약으로 걸린다. 이 파일은 클라이언트가 진행률을 표시할 때
/// 조건을 해석하기 위한 사본이다 — 분류 근거는 `_workspace/20260825_architect_badge-model-v2.md` §4.
///
/// 값 추가/삭제는 서버 마이그레이션과 **동시에** 해야 한다. 클라이언트가 모르는
/// `conditionType`이 내려와도 앱이 죽지 않도록 [isKnown]이 안전하게 폴백한다 —
/// 새 뱃지가 추가돼도 앱 배포 없이 갤러리에 표시되어야 하기 때문이다.
///
/// ⚠️ 어느 분류든 **획득 확정은 100% 서버다.** [BadgeEvaluability.clientEstimable]은
/// "진행률 바를 그려도 되는가"에 대한 답일 뿐이며, `UserBadge` 행이 생기기 전에는
/// 미획득이다(ARCHITECTURE 원칙 3).
library;

import 'dart:math' as math;

/// 임계값 비교 방향.
enum BadgeCompareDirection {
  /// `현재값 >= 목표`이면 달성. 대부분의 조건.
  atLeast,

  /// `현재값 <= 목표`이면 달성. 페이스·랭킹 계열 전용(작을수록/앞순위일수록 좋음).
  atMost,
}

/// 판정을 누가 할 수 있는가.
enum BadgeEvaluability {
  /// 클라이언트가 로컬 기록만으로 **진행률을 추정**할 수 있다.
  /// (획득 확정은 여전히 서버 전용)
  clientEstimable,

  /// 로컬 데이터가 부분적으로만 있어 추정이 크게 빗나갈 수 있다.
  /// 진행률 바를 그리지 말고 조건 텍스트만 보여준다.
  clientPartial,

  /// 서버 집계 없이는 값 자체를 알 수 없다(랭킹·티어·시즌 전역 집계·역지오코딩·XP 공식 미정).
  serverOnly,
}

/// `Badge.conditionType` 문자열 상수 — CSV `condition_type` 열과 1:1 (40종).
class BadgeConditionType {
  const BadgeConditionType._();

  static const String cumulativeDistanceGte = 'cumulative_distance_gte';
  static const String cumulativeCountGte = 'cumulative_count_gte';
  static const String streakWeeksGte = 'streak_weeks_gte';
  static const String pbFirstAchieved = 'pb_first_achieved';
  static const String pbTimeLte = 'pb_time_lte';
  static const String sessionDistanceGte = 'session_distance_gte';
  static const String sessionDurationGte = 'session_duration_gte';
  static const String sessionStartHourCountGte = 'session_start_hour_count_gte';
  static const String weekdayFullWeekCountGte = 'weekday_full_week_count_gte';
  static const String weekendBothDaysCountGte = 'weekend_both_days_count_gte';
  static const String dayOfWeekCountGte = 'day_of_week_count_gte';
  static const String dayOfWeekDiversityGte = 'day_of_week_diversity_gte';
  static const String routeDiversityCountGte = 'route_diversity_count_gte';
  static const String elevationGainCumulativeGte = 'elevation_gain_cumulative_gte';
  static const String loopCourseCountGte = 'loop_course_count_gte';
  static const String calendarDateMatch = 'calendar_date_match';
  static const String membershipAnniversaryRun = 'membership_anniversary_run';
  static const String paceAvgLte = 'pace_avg_lte';
  static const String paceNegativeSplitCountGte = 'pace_negative_split_count_gte';
  static const String paceFinalKmFasterPctGte = 'pace_final_km_faster_pct_gte';
  static const String paceVarianceLte = 'pace_variance_lte';
  static const String deviceSourceCountGte = 'device_source_count_gte';
  static const String deviceSourceDiversityGte = 'device_source_diversity_gte';
  static const String levelGte = 'level_gte';
  static const String seasonTierReached = 'season_tier_reached';
  static const String seasonWeeklyRankLte = 'season_weekly_rank_lte';
  static const String seasonFirstRun = 'season_first_run';
  static const String seasonWeeklyAttendanceFull = 'season_weekly_attendance_full';
  static const String seasonWeeklyAttendanceGtePct = 'season_weekly_attendance_gte_pct';
  static const String seasonFirstRunWithinDays = 'season_first_run_within_days';
  static const String seasonPbAchieved = 'season_pb_achieved';
  static const String seasonBestWeekDistancePb = 'season_best_week_distance_pb';
  static const String seasonChallengeCompleted = 'season_challenge_completed';
  static const String seasonWeeklyRankRisingStreakGte = 'season_weekly_rank_rising_streak_gte';
  static const String seasonMaxTierReachedBeforePct = 'season_max_tier_reached_before_pct';
  static const String seasonComebackRun = 'season_comeback_run';
  static const String seasonFirstLongDistance = 'season_first_long_distance';
  static const String seasonStartStreakWeeksGte = 'season_start_streak_weeks_gte';
  static const String seasonStreakWeeksGte = 'season_streak_weeks_gte';

  static const Set<String> all = {
    cumulativeDistanceGte,
    cumulativeCountGte,
    streakWeeksGte,
    pbFirstAchieved,
    pbTimeLte,
    sessionDistanceGte,
    sessionDurationGte,
    sessionStartHourCountGte,
    weekdayFullWeekCountGte,
    weekendBothDaysCountGte,
    dayOfWeekCountGte,
    dayOfWeekDiversityGte,
    routeDiversityCountGte,
    elevationGainCumulativeGte,
    loopCourseCountGte,
    calendarDateMatch,
    membershipAnniversaryRun,
    paceAvgLte,
    paceNegativeSplitCountGte,
    paceFinalKmFasterPctGte,
    paceVarianceLte,
    deviceSourceCountGte,
    deviceSourceDiversityGte,
    levelGte,
    seasonTierReached,
    seasonWeeklyRankLte,
    seasonFirstRun,
    seasonWeeklyAttendanceFull,
    seasonWeeklyAttendanceGtePct,
    seasonFirstRunWithinDays,
    seasonPbAchieved,
    seasonBestWeekDistancePb,
    seasonChallengeCompleted,
    seasonWeeklyRankRisingStreakGte,
    seasonMaxTierReachedBeforePct,
    seasonComebackRun,
    seasonFirstLongDistance,
    seasonStartStreakWeeksGte,
    seasonStreakWeeksGte,
  };

  /// 클라이언트가 아는 조건인지. 모르는 값이면 진행률 대신 조건 텍스트만 표시한다.
  static bool isKnown(String conditionType) => all.contains(conditionType);

  /// 판정 주체 분류. `_workspace/20260825_architect_badge-model-v2.md` §4의 표와 1:1.
  ///
  /// client 18 · partial 7 · server 15. partial/server는 진행률 바를 그리지 않는다
  /// (`BadgeProgressCalculator`가 이 값을 보고 분기한다).
  static BadgeEvaluability evaluabilityOf(String conditionType) {
    switch (conditionType) {
      case cumulativeDistanceGte:
      case cumulativeCountGte:
      case streakWeeksGte:
      case pbFirstAchieved:
      case pbTimeLte:
      case sessionDistanceGte:
      case sessionDurationGte:
      case sessionStartHourCountGte:
      case weekdayFullWeekCountGte:
      case weekendBothDaysCountGte:
      case dayOfWeekCountGte:
      case dayOfWeekDiversityGte:
      case elevationGainCumulativeGte:
      case loopCourseCountGte:
      case membershipAnniversaryRun:
      case paceAvgLte:
      case paceNegativeSplitCountGte:
      case paceFinalKmFasterPctGte:
      case paceVarianceLte:
      case deviceSourceCountGte:
      case deviceSourceDiversityGte:
        return BadgeEvaluability.clientEstimable;
      case routeDiversityCountGte:
      case calendarDateMatch:
      case seasonFirstRun:
      case seasonFirstRunWithinDays:
      case seasonPbAchieved:
      case seasonComebackRun:
      case seasonFirstLongDistance:
        return BadgeEvaluability.clientPartial;
      default:
        // levelGte(서버 XP 4원천), season_* 집계류(랭킹/티어/주차 전역) 등 — 서버 전용.
        // streakWeeksGte/deviceSource*는 클라이언트에서도 리플레이·배열 겹침으로 추정 가능해
        // 위 clientEstimable 분기에 이미 있다. districtDiversityGte는 2026-08-26 카탈로그에서 삭제됐다.
        return BadgeEvaluability.serverOnly;
    }
  }

  /// 비교 방향. "작을수록/앞순위일수록 좋음" 조건만 [BadgeCompareDirection.atMost].
  static BadgeCompareDirection compareDirectionFor(String conditionType) {
    const atMostTypes = {
      pbTimeLte,
      paceAvgLte,
      paceVarianceLte,
      seasonWeeklyRankLte,
    };
    return atMostTypes.contains(conditionType)
        ? BadgeCompareDirection.atMost
        : BadgeCompareDirection.atLeast;
  }
}

/// 서버가 "목표 거리 도달"을 판정할 때 쓰는 **거리 허용오차**(마이그레이션 42,
/// `docs/TRD.md` §10.2). 목표 `D`km에 대해 서버는
/// `distance_meters >= D*1000 - min(D*1000*0.02, 300)` 이면 달성으로 본다.
///
/// 이 상수/함수는 **마이그레이션 42 SQL의 거울**이다 — 서버 식이 바뀌면 여기도
/// 같이 바뀌어야 한다. 클라이언트가 이걸 아는 이유는 오직 하나, 진행률 바가
/// 서버 인정 기준에서 100%로 차게 하기 위해서다(텐런을 9.8km에서 뛰면 서버는
/// 지급하는데 바만 98%에서 멈추던 문제 — TRD §14 #17).
const double _distanceTolerancePct = 0.02;
const double _distanceToleranceCapMeters = 300.0;

/// 마이그레이션 42가 허용오차를 적용한 조건 3종.
///
/// ⚠️ `cumulative_distance_gte`는 **포함하지 않는다.** 42번 마이그레이션에서
/// 누적 거리 분기는 `p.total_distance_meters >= v_distance_km * 1000.0` 그대로다 —
/// 누적은 "한 번의 목표 거리 완주" 판정이 아니라 합계라 허용오차를 둘 이유가
/// 없다. 클라이언트가 임의로 완화하면 서버보다 먼저 100%를 그리게 된다.
const Set<String> _distanceToleranceConditionTypes = {
  BadgeConditionType.sessionDistanceGte,
  BadgeConditionType.pbFirstAchieved,
  BadgeConditionType.seasonFirstLongDistance,
};

/// [conditionType]이 서버 거리 허용오차를 쓰는 조건인지.
bool usesDistanceTolerance(String conditionType) =>
    _distanceToleranceConditionTypes.contains(conditionType);

/// 서버가 실제로 인정하는 **유효 목표 거리(km)**.
///
/// 허용오차를 쓰지 않는 조건이거나 목표가 유효하지 않으면 [targetKm]을 그대로
/// 돌려준다(호출부가 분기하지 않아도 되게).
double effectiveDistanceTargetKm({
  required String conditionType,
  required double targetKm,
}) {
  if (!usesDistanceTolerance(conditionType) || targetKm <= 0) return targetKm;
  final targetMeters = targetKm * 1000.0;
  final tolerance = math.min(
    targetMeters * _distanceTolerancePct,
    _distanceToleranceCapMeters,
  );
  return (targetMeters - tolerance) / 1000.0;
}

/// `Badge.badgeGrade`(String) 정렬 키. bronze=0 … diamond=4, 그 외(special 포함)=5.
/// `sortOrder` 필드가 삭제된 자리를 메운다 — 카탈로그는 (카테고리, 등급, 임계값)
/// 순으로 자연 정렬돼 있으므로 클라이언트가 파생시킨다.
int badgeGradeOrder(String badgeGrade) {
  const order = ['bronze', 'silver', 'gold', 'platinum', 'diamond'];
  final i = order.indexOf(badgeGrade);
  return i == -1 ? order.length : i;
}
