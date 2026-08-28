import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'notification_settings.freezed.dart';
part 'notification_settings.g.dart';

/// 알림 종류별 수신 설정 (PRD §5.10 NT-08). DB 테이블은 `notification_settings`.
/// **유저당 정확히 1행** — PK가 `user_id`다.
///
/// ## 왜 `Map<NotificationType, bool>`이 아니라 필드를 하나씩 두는가
/// 발송 주체가 서버(pg_cron 배치·트리거)이기 때문이다. 배치는
/// `... join notification_settings s on s.user_id = p.id where s.weekend_push`
/// 처럼 **SQL 한 번으로 수신 거부자를 걸러내야** 한다. jsonb 한 컬럼이면
/// 매 행마다 키 추출이 붙고 인덱스도 걸기 어렵다.
/// UI는 [isEnabled]/[withType]으로 제네릭하게 순회하므로 토글을 하나씩
/// 하드코딩하지 않는다.
///
/// ## 기본값은 전부 on (권장 · 확정 제안)
/// 이 앱의 알림은 광고가 아니라 **제품의 핵심 루프 그 자체**다 — "0.8km만 더 뛰면
/// 앞사람을 제친다"(PRD §5.4.1), "시즌 D-3"(TI-07)는 알림이 없으면 존재하지 않는
/// 기능이다. 기본 off로 두면 대다수 사용자에게 이중 경쟁 루프(PRD §4.2)가
/// 작동하지 않는다. 대신 **OS 권한 요청은 미루고**(첫 실행이 아니라 첫 러닝 완료
/// 직후), 끄는 경로를 프로필에서 1탭 거리에 둔다.
///
/// 서버는 행이 없는 사용자를 **전 종류 on으로 간주**한다(신규 가입 직후 행 생성
/// 실패로 알림이 조용히 끊기는 쪽이 더 나쁘다). 클라이언트도 조회 결과가 없으면
/// [NotificationSettings.defaultsFor]를 쓴다.
@freezed
abstract class NotificationSettings with _$NotificationSettings {
  const NotificationSettings._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory NotificationSettings({
    required String userId,

    /// 마스터 스위치. false면 종류별 값과 무관하게 **아무 푸시도 보내지 않는다**.
    /// OS 권한(사용자가 시스템 설정에서 끈 것)과는 별개다 — OS 권한은 앱이
    /// 되돌릴 수 없고, 이 값은 앱 안에서 껐다 켤 수 있다.
    @Default(true) bool pushEnabled,

    /// NT-01 티어 승급.
    @Default(true) bool tierPromotion,

    /// NT-02 다음 티어 근접.
    @Default(true) bool tierProximity,

    /// NT-03 시즌 종료 D-14 / D-3.
    @Default(true) bool seasonEnding,

    /// NT-04 주간 순위 변동(추월함·추월당함).
    @Default(true) bool rankChange,

    /// NT-05 주말 막판 유도.
    @Default(true) bool weekendPush,

    /// NT-06 뱃지 획득 / 레벨업.
    @Default(true) bool badgeLevel,

    // NT-07(포인트)은 Phase 4다. 컬럼도 필드도 지금 만들지 않는다 —
    // 적립 규칙이 미정(PRD §5.6)이라 지금 만든 토글은 아무것도 제어하지 못하고,
    // 설정 화면에 "동작하지 않는 스위치"가 남는다.

    /// 서버가 마지막으로 갱신한 시각(UTC). 기기 간 충돌 시 최신 우선.
    DateTime? updatedAt,
  }) = _NotificationSettings;

  factory NotificationSettings.fromJson(Map<String, dynamic> json) =>
      _$NotificationSettingsFromJson(json);

  /// 행이 아직 없을 때 쓰는 기본값 — 전 종류 on.
  factory NotificationSettings.defaultsFor(String userId) =>
      NotificationSettings(userId: userId);

  /// 설정 화면에 노출할 종류 목록. NT-07은 제외된다.
  static List<NotificationType> get configurableTypes =>
      NotificationType.values.where((t) => t.isMvp).toList(growable: false);

  /// [type] 알림을 받는가. [pushEnabled]가 꺼져 있으면 무조건 false다.
  bool isEnabled(NotificationType type) =>
      pushEnabled && _rawFlag(type);

  /// 마스터 스위치를 무시한, 종류별 토글의 원래 값. 설정 화면에서 마스터를
  /// 껐다 켰을 때 개별 토글이 기억된 상태로 돌아오게 하려면 이 값을 그린다.
  bool rawFlag(NotificationType type) => _rawFlag(type);

  bool _rawFlag(NotificationType type) => switch (type) {
        NotificationType.tierPromotion => tierPromotion,
        NotificationType.tierProximity => tierProximity,
        NotificationType.seasonEnding => seasonEnding,
        NotificationType.rankChange => rankChange,
        NotificationType.weekendPush => weekendPush,
        NotificationType.badgeLevel => badgeLevel,
        NotificationType.points => false, // Phase 4 — 항상 off
      };

  /// 종류 하나만 바꾼 사본. UI가 `switch`를 다시 쓰지 않게 하는 유일한 변경 경로다.
  NotificationSettings withType(NotificationType type, bool value) =>
      switch (type) {
        NotificationType.tierPromotion => copyWith(tierPromotion: value),
        NotificationType.tierProximity => copyWith(tierProximity: value),
        NotificationType.seasonEnding => copyWith(seasonEnding: value),
        NotificationType.rankChange => copyWith(rankChange: value),
        NotificationType.weekendPush => copyWith(weekendPush: value),
        NotificationType.badgeLevel => copyWith(badgeLevel: value),
        NotificationType.points => this, // Phase 4 — 변경 불가
      };

  /// 부분 갱신 payload. 토글 하나를 바꿀 때 행 전체를 덮어쓰면 다른 기기가
  /// 방금 바꾼 값을 되돌린다(lost update). 바뀐 컬럼 하나만 보낸다.
  static String columnOf(NotificationType type) => switch (type) {
        NotificationType.tierPromotion => 'tier_promotion',
        NotificationType.tierProximity => 'tier_proximity',
        NotificationType.seasonEnding => 'season_ending',
        NotificationType.rankChange => 'rank_change',
        NotificationType.weekendPush => 'weekend_push',
        NotificationType.badgeLevel => 'badge_level',
        NotificationType.points => 'points', // Phase 4 — 컬럼 미존재
      };
}
