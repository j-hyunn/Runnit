import 'package:json_annotation/json_annotation.dart';

/// 모든 enum의 JSON 표현은 snake_case 문자열이다.
/// Supabase 측에서는 동일 이름의 Postgres enum 타입 또는 CHECK 제약 걸린 text로 매핑한다.

/// RunSample이 어느 장치에서 왔는지. 폰/워치를 하나의 모델로 통합하고
/// 이 필드로만 구분한다 (소스별 모델 분리 금지).
enum RunSampleSource {
  @JsonValue('phone')
  phone,
  @JsonValue('watch')
  watch,
  @JsonValue('external')
  external, // Garmin Connect → HealthKit/Health Connect 경유 등 사후 임포트
}

/// 러닝 세션의 생명주기 상태.
enum RunStatus {
  @JsonValue('recording')
  recording,
  @JsonValue('paused')
  paused,
  @JsonValue('completed')
  completed,
  @JsonValue('discarded')
  discarded,
}

/// 기록의 동기화 상태. 오프라인 러닝 → 이후 업로드 흐름을 지원한다.
enum SyncStatus {
  @JsonValue('local')
  local, // 기기에만 존재
  @JsonValue('pending')
  pending, // 업로드 시도 중/대기
  @JsonValue('synced')
  synced, // 서버 반영 완료
  @JsonValue('failed')
  failed,
}

/// 활동 유형. v1은 outdoorRun 중심이나 모델은 확장 가능하게 둔다.
enum ActivityType {
  @JsonValue('outdoor_run')
  outdoorRun,
  @JsonValue('indoor_run')
  indoorRun, // 트레드밀 — GPS 좌표 없음, 거리 추정치
  @JsonValue('trail_run')
  trailRun,
  @JsonValue('walk')
  walk,
}

/// 랭킹 집계 기간.
enum RankingPeriod {
  @JsonValue('daily')
  daily,
  @JsonValue('weekly')
  weekly,
  @JsonValue('monthly')
  monthly,
  @JsonValue('all_time')
  allTime,
}

/// 랭킹 정렬 기준 지표.
enum RankingMetric {
  @JsonValue('distance')
  distance, // 총 거리(m)
  @JsonValue('duration')
  duration, // 총 시간(s)
  @JsonValue('run_count')
  runCount,
}

/// 랭킹 범위 — 전체/크루 단위.
enum RankingScope {
  @JsonValue('global')
  global,
  @JsonValue('crew')
  crew,
  @JsonValue('friends')
  friends,
}

/// 뱃지 판정 **시점**. TRD §3.6.
/// - [session]: 러닝 1건이 끝나는 순간 그 세션만 보고 판정(PB, 단일 세션 거리 등).
/// - [cumulative]: 누적 통계/집계를 다시 계산해 판정(누적 거리, 스트릭, 랭킹 등).
enum BadgeTriggerType {
  @JsonValue('session')
  session,
  @JsonValue('cumulative')
  cumulative,
}

/// 뱃지의 생명주기 스코프. TRD §3.6.
/// - [permanent]: 평생 누적 기준. 카탈로그에 딱 한 번만 존재하고 재발급되지 않는다.
/// - [seasonal]: 시즌 스코프로 판정. 카탈로그 항목은 **템플릿**이고, 시즌 시작마다
///   `seasonId`가 채워진 **인스턴스**가 새로 발급된다. 획득 인스턴스는 시즌이 끝나도
///   영구 보존된다(PRD GM-07 — 티어 리셋의 상실감을 수집 동기로 전환하는 장치).
enum BadgeScope {
  @JsonValue('permanent')
  permanent,
  @JsonValue('seasonal')
  seasonal,
}

/// 뱃지 카탈로그 16개 카테고리. 정본은 `docs/badge-catalog.csv`(158종).
/// CSV의 `category` 열은 한국어 라벨(`누적거리` 등)이지만 DB/JSON 표현은 아래
/// snake_case 영문이다 — 시드 시 backend가 매핑한다.
enum BadgeCategory {
  @JsonValue('cumulative_distance')
  cumulativeDistance, // 누적거리 (permanent)
  @JsonValue('cumulative_count')
  cumulativeCount, // 누적횟수 (permanent)
  @JsonValue('longest_streak')
  longestStreak, // 최장스트릭 (permanent) — PRD GM-05에 따라 **주 단위**
  @JsonValue('personal_best')
  personalBest, // PB갱신 (permanent, 검증된 실외 기록만)
  @JsonValue('single_session_distance')
  singleSessionDistance, // 단일세션거리 (permanent)
  @JsonValue('time_of_day_weekday')
  timeOfDayWeekday, // 시간대요일 (permanent)
  @JsonValue('route_exploration')
  routeExploration, // 경로탐험 (permanent, GPS 기반)
  @JsonValue('special_day')
  specialDay, // 특별한날 (permanent)
  @JsonValue('pace_speed')
  paceSpeed, // 페이스속도 (permanent)
  @JsonValue('device_integration')
  deviceIntegration, // 기기연동 (permanent)
  @JsonValue('level')
  level, // 레벨 (permanent) — XP 공식 미정, GM-04 별도 설계 후 확정
  @JsonValue('season_tier')
  seasonTier, // 시즌티어달성 (seasonal, GM-07)
  @JsonValue('season_weekly_rank')
  seasonWeeklyRank, // 시즌주간랭킹 (seasonal, RK-06)
  @JsonValue('season_event')
  seasonEvent, // 시즌한정이벤트 (seasonal, GM-08 P1)
}

/// 경쟁 티어 (PRD §5.3, TI-01). **절대평가** — 시즌 누적 거리가 기준선을 넘으면 승급.
///
/// ⚠️ `Badge.badgeGrade`(String: bronze/silver/gold/platinum/diamond/special)와
/// 이름이 겹치지만 **다른 개념**이다.
/// - `Badge.badgeGrade`: 뱃지 자체의 희소도 등급(카탈로그 속성). `scope == seasonal`인
///   시즌티어달성(`stier_*`) 4종을 제외하면 이 [Tier]와 무관한 순수 장식용 값이다.
/// - [Tier]: 사용자의 시즌 경쟁 등급 (프로필 상태, 시즌마다 리셋)
///
/// 두 값이 우연히 같은 라벨을 쓰므로 통합하고 싶어지지만, 통합하면 뱃지 희소도를
/// 바꿀 때 경쟁 티어 체계가 딸려 움직인다. 별도 개념으로 둔다.
enum Tier {
  @JsonValue('bronze')
  bronze,
  @JsonValue('silver')
  silver,
  @JsonValue('gold')
  gold,
  @JsonValue('platinum')
  platinum,
}

/// 티어 기준선과 파생 계산.
///
/// ⚠️ **서버가 단일 진실 원천이다** (PRD §6 "티어 정합성"). 여기의 계산은
/// 오직 **표시용 예측**(TI-05 "다음 티어까지 N km" 진행률 바)에만 쓴다.
/// 클라이언트가 계산한 티어를 서버에 써 넣거나, 서버가 내려준
/// `AppUser.currentTier`를 클라이언트 계산값으로 덮어쓰면 안 된다.
extension TierX on Tier {
  /// 승급에 필요한 **시즌 누적 거리 하한(m)** — PRD §5.3.2 확정값.
  double get thresholdMeters => switch (this) {
        Tier.bronze => 0,
        Tier.silver => 25000,
        Tier.gold => 100000,
        Tier.platinum => 250000,
      };

  /// 낮은 티어부터 높은 티어 순. 비교/정렬의 기준.
  int get order => Tier.values.indexOf(this);

  /// 다음 티어. 최고 티어면 null.
  Tier? get next =>
      order + 1 < Tier.values.length ? Tier.values[order + 1] : null;

  /// 시즌 누적 거리로 티어를 판정한다(§8.1). 입력은 **검증 통과 + 실외 기록만**
  /// 합산한 거리여야 한다 — 트레드밀/수동 기록은 제외(§8.3).
  static Tier fromSeasonDistanceMeters(double meters) {
    var result = Tier.bronze;
    for (final t in Tier.values) {
      if (meters >= t.thresholdMeters) result = t;
    }
    return result;
  }

  /// 다음 티어까지 남은 거리(m). 최고 티어면 null.
  static double? remainingToNextMeters(double seasonMeters) {
    final next = fromSeasonDistanceMeters(seasonMeters).next;
    if (next == null) return null;
    return (next.thresholdMeters - seasonMeters).clamp(0, double.infinity);
  }
}

enum ChallengeType {
  @JsonValue('distance_total')
  distanceTotal, // 기간 내 누적 거리
  @JsonValue('run_count')
  runCount, // 기간 내 러닝 횟수
  @JsonValue('single_run_distance')
  singleRunDistance, // 단일 러닝 최장 거리
  @JsonValue('streak_days')
  streakDays, // 연속 러닝 일수
  @JsonValue('elevation_total')
  elevationTotal,
}

enum ChallengeStatus {
  @JsonValue('upcoming')
  upcoming,
  @JsonValue('active')
  active,
  @JsonValue('ended')
  ended,
  @JsonValue('archived')
  archived,
}

/// 사용자 표시 단위 설정. 저장은 항상 SI(미터/초)이고, 이 값은 표시 계층에서만 쓴다.
enum DistanceUnit {
  @JsonValue('metric')
  metric,
  @JsonValue('imperial')
  imperial,
}

enum Gender {
  @JsonValue('male')
  male,
  @JsonValue('female')
  female,
  @JsonValue('other')
  other,
  @JsonValue('undisclosed')
  undisclosed,
}
