import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'challenge.freezed.dart';
part 'challenge.g.dart';

/// 기간제 챌린지 정의. (예: "8월에 100km 달리기")
///
/// ## 단위
/// [targetValue]의 단위는 [type]에 종속:
/// - distanceTotal / singleRunDistance / elevationTotal → **미터(m)**
/// - runCount → 회
/// - streakDays → 일
@freezed
abstract class Challenge with _$Challenge {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Challenge({
    required String id,
    required String title,
    required String description,
    required ChallengeType type,
    required ChallengeStatus status,

    /// 목표값. 단위는 [type]에 종속(위 주석 참조).
    required double targetValue,

    /// 참가 기간(UTC, 반열림 구간 [startAt, endAt)).
    required DateTime startAt,
    required DateTime endAt,

    String? bannerImageUrl,

    /// 완주 시 지급 뱃지 id(Badge.id 슬러그). 없으면 null.
    String? rewardBadgeId,

    /// 완주 시 지급 포인트.
    @Default(0) int rewardPoints,

    /// 크루 전용 챌린지면 해당 크루 id, 전체 공개면 null.
    String? crewId,

    /// 현재 참가자 수(서버 관리 캐시).
    @Default(0) int participantCount,

    required DateTime createdAt,
  }) = _Challenge;

  factory Challenge.fromJson(Map<String, dynamic> json) =>
      _$ChallengeFromJson(json);
}

/// 특정 사용자의 챌린지 참가/진행 상태.
@freezed
abstract class ChallengeParticipation with _$ChallengeParticipation {
  const ChallengeParticipation._();

  @JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
  const factory ChallengeParticipation({
    required String id,
    required String challengeId,
    required String userId,

    required DateTime joinedAt,

    /// 현재 진척값. 단위는 Challenge.type에 종속. 서버가 갱신한다.
    @Default(0) double progressValue,

    /// 완주 시각(UTC). 미완주면 null.
    DateTime? completedAt,

    /// 챌린지 내 순위(선택 — 랭킹형 챌린지에서만).
    int? rank,

    /// 함께 조인해 내려온 챌린지 정의(선택).
    Challenge? challenge,
  }) = _ChallengeParticipation;

  factory ChallengeParticipation.fromJson(Map<String, dynamic> json) =>
      _$ChallengeParticipationFromJson(json);

  bool get isCompleted => completedAt != null;

  /// 0.0~1.0으로 정규화된 진행률.
  double progressRatio(double targetValue) =>
      targetValue <= 0 ? 0 : (progressValue / targetValue).clamp(0.0, 1.0);
}
