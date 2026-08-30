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

/// 알림 종류(`public.notification_type`). 알림함 필터
/// (`.eq('type', ...)`)와 미읽음 카운트 쿼리에 쓴다.
extension NotificationTypeWire on NotificationType {
  String get wire => switch (this) {
        NotificationType.tierPromotion => 'tier_promotion',
        NotificationType.tierProximity => 'tier_proximity',
        NotificationType.seasonEnding => 'season_ending',
        NotificationType.rankChange => 'rank_change',
        NotificationType.weekendPush => 'weekend_push',
        NotificationType.badgeLevel => 'badge_level',
        NotificationType.points => 'points', // Phase 4 — 발행되지 않음
      };
}

/// FCM data payload의 `type` 문자열 → [NotificationType].
///
/// 푸시 메시지는 `AppNotification.fromJson`을 거치지 않는다(행 전체가 아니라
/// data 맵 몇 개만 온다). 모르는 라벨은 **null** — 구버전 앱이 새 종류를 받아도
/// 예외로 죽지 않고 "종류 미상 알림"으로 다룬다.
NotificationType? notificationTypeFromWire(String? wire) {
  if (wire == null) return null;
  for (final type in NotificationType.values) {
    if (type.wire == wire) return type;
  }
  return null;
}

/// 푸시 토큰 플랫폼(`public.device_platform`).
extension DevicePlatformWire on DevicePlatform {
  String get wire => switch (this) {
        DevicePlatform.ios => 'ios',
        DevicePlatform.android => 'android',
      };
}

extension DistanceUnitWire on DistanceUnit {
  String get wire => switch (this) {
        DistanceUnit.metric => 'metric',
        DistanceUnit.imperial => 'imperial',
      };
}

/// 기기 벤더(`public.device_vendor`). `runs.device_vendors` 배열 필터
/// (`.contains('device_vendors', [vendor.wire])`)에 쓴다.
///
/// ⚠️ 이 문자열은 **네 곳**이 동일해야 한다 — 다른 enum보다 한 곳 더 많다:
/// `lib/models/enums.dart`의 `@JsonValue`, Postgres `device_vendor` 라벨,
/// 여기, 그리고 **뱃지 카탈로그의 조건 토큰**(`badge_catalog.condition_value`의
/// `source`/`sources` 값, `docs/badge-catalog.csv`). 카탈로그까지 같은 문자열로
/// 맞춘 것이 이 설계의 핵심이다 — 어긋나면 뱃지가 조용히 미지급된다.
extension DeviceVendorWire on DeviceVendor {
  String get wire => switch (this) {
        DeviceVendor.phone => 'phone',
        DeviceVendor.watchApple => 'watchApple',
        DeviceVendor.watchGarmin => 'watchGarmin',
        DeviceVendor.watchOther => 'watchOther',
        DeviceVendor.unknown => 'unknown',
      };
}
