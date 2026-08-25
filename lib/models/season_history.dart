import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';
import 'season.dart';

part 'season_history.freezed.dart';
part 'season_history.g.dart';

/// 역대 시즌 기록 (PRD HI-06 / TI-06). DB 테이블은 `season_histories`.
///
/// ## 왜 별도 테이블인가
/// 티어는 시즌마다 리셋되지만(TI-02), 리셋 자체가 상실감을 만든다(§5.5 GM-07 각주).
/// 시즌이 끝나는 순간의 **최종 티어와 시즌 누적 거리를 영구 보존**해서
/// "2026 Q3 플래티넘"이라는 사실이 남게 하는 것이 이 모델의 유일한 목적이다.
/// `runs`에서 매번 재집계해 복원할 수도 있지만, 그러면 이후의 기록 삭제·부정 판정이
/// 과거 시즌의 확정 결과를 소급해 바꾸게 된다. **시즌 결과는 마감 시점에 못 박는다.**
///
/// ## 불변 규칙
/// - **유저당 시즌당 정확히 1행** — `UNIQUE (user_id, season_id)`.
/// - 마감(`closedAt`) 이후에는 서버도 수정하지 않는다. 부정 기록이 사후에
///   적발되면 행을 고치는 대신 [isVoided]를 세운다(§8.1 부정 판정 시 회수 정책).
/// - 진행 중인 시즌의 행은 **존재하지 않는다.** 현재 시즌 상태는
///   `AppUser.currentTier` / `AppUser.seasonDistanceMeters`가 들고 있다.
///   두 곳에 동시에 쓰면 어느 쪽이 진실인지 모호해진다.
@freezed
abstract class SeasonHistory with _$SeasonHistory {
  const SeasonHistory._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory SeasonHistory({
    /// 서버 생성 UUID.
    required String id,

    required String userId,

    /// `2026-Q3` 형식. `Season` 유틸의 id와 동일 규약.
    required String seasonId,

    /// 시즌 종료 시점에 확정된 티어.
    required Tier finalTier,

    /// 확정된 시즌 누적 거리(m). **검증 통과 + 실외 기록만**(§8.3).
    /// `AppUser.seasonDistanceMeters`의 마감 시점 스냅샷이다.
    @Default(0) double distanceMeters,

    /// 부가 표시용 — 해당 시즌의 러닝 횟수 / 이동 시간(s).
    /// 티어 판정과 동일한 필터(검증 통과 + 실외)로 집계한다.
    @Default(0) int runCount,
    @Default(0) int movingSeconds,

    /// 해당 시즌 주간 랭킹에서의 최고 순위. 미참여면 null.
    /// (RK-09/RK-10 명예의 전당은 다음 라운드 범위 — 이 필드는 프로필 표시용 단순 값)
    int? bestWeeklyRank,

    /// 서버가 이 시즌을 마감 처리한 시각(UTC).
    required DateTime closedAt,

    /// 사후 부정 판정으로 무효화된 시즌(§8.1). 행은 남기고 표시만 지운다 —
    /// 삭제하면 이의 제기 대응 근거가 사라진다.
    @Default(false) bool isVoided,
  }) = _SeasonHistory;

  factory SeasonHistory.fromJson(Map<String, dynamic> json) =>
      _$SeasonHistoryFromJson(json);

  /// 시즌 시작/종료(UTC). 저장하지 않고 [seasonId]에서 파생한다 —
  /// 역년 분기는 결정론적이므로 컬럼으로 두면 중복 진실이 된다.
  DateTime get startAt => Season.startOf(seasonId);
  DateTime get endAt => Season.endOf(seasonId);

  /// GM-07 뱃지·프로필 표기용 라벨. 예: `2026 Q3`.
  String get seasonLabel => seasonId.replaceFirst('-', ' ');
}
