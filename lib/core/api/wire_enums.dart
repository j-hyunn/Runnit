import '../../models/models.dart';

/// Postgres enum 라벨 ↔ Dart enum 변환.
///
/// 모델의 `@JsonValue` 문자열은 `json_serializable`이 만든 **private** 맵
/// (`_$RankingPeriodEnumMap` 등)에만 존재해서 쿼리 계층에서 쓸 수 없다.
/// `.eq('period', ...)` 같은 **필터 값**은 직렬화를 거치지 않으므로 여기서
/// 명시적으로 같은 문자열을 제공한다.
///
/// ⚠️ 이 파일의 문자열은 `lib/models/enums.dart`의 `@JsonValue` 및
/// Postgres enum 라벨과 **세 곳이 항상 동일**해야 한다. 하나라도 어긋나면
/// 조회가 조용히 빈 결과를 돌려준다(에러가 나지 않는다).
extension RankingPeriodWire on RankingPeriod {
  String get wire => switch (this) {
        RankingPeriod.daily => 'daily',
        RankingPeriod.weekly => 'weekly',
        RankingPeriod.monthly => 'monthly',
        RankingPeriod.allTime => 'all_time',
      };
}

extension RankingMetricWire on RankingMetric {
  String get wire => switch (this) {
        RankingMetric.distance => 'distance',
        RankingMetric.duration => 'duration',
        RankingMetric.runCount => 'run_count',
      };
}

extension RankingScopeWire on RankingScope {
  String get wire => switch (this) {
        RankingScope.global => 'global',
        RankingScope.crew => 'crew',
        RankingScope.friends => 'friends',
      };
}

/// 경쟁 티어(`public.tier`). 티어 내 랭킹 조회 시 `.eq('tier', ...)` 필터에 쓴다.
extension TierWire on Tier {
  String get wire => switch (this) {
        Tier.bronze => 'bronze',
        Tier.silver => 'silver',
        Tier.gold => 'gold',
        Tier.platinum => 'platinum',
      };
}

extension ChallengeStatusWire on ChallengeStatus {
  String get wire => switch (this) {
        ChallengeStatus.upcoming => 'upcoming',
        ChallengeStatus.active => 'active',
        ChallengeStatus.ended => 'ended',
        ChallengeStatus.archived => 'archived',
      };
}

extension GenderWire on Gender {
  String get wire => switch (this) {
        Gender.male => 'male',
        Gender.female => 'female',
        Gender.other => 'other',
        Gender.undisclosed => 'undisclosed',
      };
}

extension DistanceUnitWire on DistanceUnit {
  String get wire => switch (this) {
        DistanceUnit.metric => 'metric',
        DistanceUnit.imperial => 'imperial',
      };
}
