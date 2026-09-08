import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';
import 'season.dart';

part 'season_leaderboard_snapshot.freezed.dart';
part 'season_leaderboard_snapshot.g.dart';

/// 마감된 시즌의 **티어별 최종 랭킹 1행**. DB 테이블은
/// `season_leaderboard_snapshots`(마이그레이션 58 → 60 → 66).
///
/// ## [SeasonHistory]와 무엇이 다른가
/// [SeasonHistory]는 "내 시즌 결과"(최종 티어·누적 거리)이고, 이쪽은 "그 시즌
/// 내 티어 안에서 몇 등이었나"다. 둘을 한 테이블로 합치지 않는 이유는 랭킹이
/// **참가자 집합에 의존**하기 때문이다 — 한 사람이 무효 처리되면 그 티어 전원의
/// 등수가 밀리지만, 각자의 거리·티어는 그대로다.
///
/// ## ⚠️ 아직 소비 UI가 없다 (RK-10)
/// 이 모델은 마이그레이션 66이 확정한 **wire 계약을 코드에 못 박아 두는 것**이
/// 목적이다. 화면(RK-10 명예의 전당)이 붙을 때 [rank]의 nullable 여부를 다시
/// 추측하지 않게 하려는 것이며, 리포지토리/프로바이더는 그 라운드에서 붙인다.
/// 지금 만들지 않으면 스키마와 클라이언트 사이에 문서로만 존재하는 계약이 남는다.
@freezed
abstract class SeasonLeaderboardSnapshot with _$SeasonLeaderboardSnapshot {
  const SeasonLeaderboardSnapshot._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory SeasonLeaderboardSnapshot({
    /// 이 테이블에는 대리 키가 없다 — PK가 `(season_id, user_id)`다
    /// (마이그레이션 58). 유저당 시즌당 정확히 1행이므로 id 컬럼이 사족이다.
    required String userId,

    /// `2026-Q3` 형식. [Season] 유틸의 id와 동일 규약.
    required String seasonId,

    /// 랭킹은 **같은 티어 안에서만** 매겨진다(PRD §5.4). 마감 시점의 티어다.
    required Tier tier,

    /// 그 시즌 내 티어 순위. **null이면 이 시즌 순위가 존재하지 않는다.**
    ///
    /// ## null ⇔ [isVoided] (DB CHECK로 강제, 마이그레이션 66)
    /// ```sql
    /// check ((is_voided and rank is null) or (not is_voided and rank is not null))
    /// ```
    /// 무효 처리된 사용자는 RLS상 **자기 행은 계속 본다**(마이그레이션 60). 옛
    /// 등수를 그대로 남기면 "무효인데 12위"라는 모순된 화면이 되고, `0`이나 `-1`
    /// 같은 보초값은 언젠가 정렬에 섞인다. null은 "순위가 없다"를 타입으로
    /// 말하는 유일한 방법이고, **소비 UI가 반드시 분기하게** 만든다.
    ///
    /// ⚠️ RK-10은 이 null을 "무효 처리된 시즌"으로 표기해야 하며 0위·미참여와
    /// 구분해야 한다.
    int? rank,

    /// 그 시즌 그 티어의 **유효 참가자 수**(무효 사용자 제외, 마이그레이션 66).
    ///
    /// 무효 행에도 같은 값이 들어간다 — "N명 중"의 N은 누가 보든 같아야 하고,
    /// 무효 사용자 화면에서도 그 시즌 규모는 사실이다.
    @Default(0) int participantCount,

    /// 마감 시점에 확정된 시즌 누적 거리(m). 랭킹 1차 정렬 키다.
    /// wire 키는 `season_distance_meters`.
    @Default(0) double seasonDistanceMeters,

    /// 부가 표시용 — 그 시즌 러닝 횟수 / 이동 시간(s).
    /// 둘 다 PRD §8.2 타이브레이크 키이기도 하다(횟수 asc → 이동 시간 asc).
    @Default(0) int runCount,
    @Default(0) int movingSeconds,

    /// 누적 거리가 최종값에 도달한 시점 = 그 시즌 마지막 집계 대상 러닝의
    /// `started_at`. PRD §8.2 ② 타이브레이크 근거이며 표시용은 아니다.
    DateTime? reachedAt,

    /// 사후 부정 판정으로 무효화된 시즌(PRD §8.1). 행은 남기고 순위만 지운다 —
    /// [rank]가 null인 것과 **동치**다(위 CHECK).
    @Default(false) bool isVoided,

    /// 서버가 이 스냅샷을 적재한 시각(UTC). wire 키는 `computed_at`.
    DateTime? computedAt,
  }) = _SeasonLeaderboardSnapshot;

  factory SeasonLeaderboardSnapshot.fromJson(Map<String, dynamic> json) =>
      _$SeasonLeaderboardSnapshotFromJson(json);

  /// 표시 가능한 순위가 있는가. `rank != null`과 같은 뜻이지만, 호출부가
  /// "무효니까 순위가 없다"는 인과를 읽게 한다.
  bool get hasRank => rank != null;

  /// GM-07 프로필 표기용 라벨. 예: `2026 Q3`.
  String get seasonLabel => seasonId.replaceFirst('-', ' ');

  /// 상위 몇 %인가(올림, 1~100). 순위가 없거나 참가자 수를 모르면 null —
  /// [RankingEntry.topPercent]와 같은 규칙이다(1위도 0%가 되지 않는다).
  int? get topPercent {
    final r = rank;
    if (r == null || participantCount <= 0) return null;
    return (r / participantCount * 100).ceil().clamp(1, 100);
  }
}
