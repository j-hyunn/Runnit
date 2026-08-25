import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'ranking_entry.freezed.dart';
part 'ranking_entry.g.dart';

/// 리더보드의 한 행. 서버 집계 결과를 그대로 담는 **읽기 전용 뷰 모델**.
///
/// 클라이언트는 절대 순위를 계산하지 않는다 — 부정행위 방지 및 일관성 때문에
/// [rank]는 서버 집계(뷰/머티리얼라이즈드 뷰)가 확정한 값을 신뢰한다.
///
/// ## 단위
/// - [score]의 단위는 [metric]에 종속: distance→미터, duration→초, runCount→회.
///   (게이미피케이션 포인트 랭킹은 지원하지 않는다 — 리더 결정.)
/// - [tieBreakValue]: 동점 시 비교값. 규약상 **작을수록 상위**
///   (예: 동일 거리면 총 이동 시간이 짧은 쪽이 상위 → 초 단위).
@freezed
abstract class RankingEntry with _$RankingEntry {
  const RankingEntry._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory RankingEntry({
    /// 대상 사용자 id.
    required String userId,

    /// 표시용 스냅샷 — 집계 시점의 값. 프로필 조회 왕복을 없애기 위한 비정규화.
    required String username,
    String? displayName,
    String? avatarUrl,

    /// 1부터 시작. 동점자는 같은 순위를 공유하고 다음 순위를 건너뛴다(1,2,2,4).
    required int rank,

    /// 직전 집계 대비 순위 변동. 양수 = 상승. 첫 진입/미집계면 null.
    int? rankDelta,

    /// 정렬 기준 지표.
    required RankingMetric metric,

    /// [metric] 단위의 점수. 클수록 상위.
    required double score,

    /// 동점 처리용 보조값(초). 작을수록 상위.
    double? tieBreakValue,

    required RankingPeriod period,
    required RankingScope scope,

    /// 크루 랭킹일 때의 크루 id. global이면 null.
    String? crewId,

    /// **티어 분할 차원** (PRD RK-02 "랭킹은 같은 티어 내에서만 겨룬다").
    ///
    /// [scope]와 **직교**한다 — 티어를 [RankingScope]의 새 값으로 넣지 않았다.
    /// scope는 "누구와 겨루는가"(전체/크루/친구)라는 모집단 축이고, 티어는
    /// 그 모집단을 실력으로 자르는 필터 축이다. 한 enum에 섞으면 나중에
    /// "크루 안에서의 티어 랭킹" 같은 조합을 표현할 수 없게 되고,
    /// `scope = tier`가 crew/friends와 배타적이 되어 조합 폭발을 낳는다.
    ///
    /// - null = 티어로 나누지 않은 통합 랭킹 (기존 daily/monthly/all_time 보드)
    /// - non-null = 해당 티어 내부 랭킹
    ///
    /// **PRD가 요구하는 조합**: `period = weekly`, `metric = distance`,
    /// `scope = global`, `tier != null`. 이 조합이 앱의 기본 랭킹 화면이다.
    /// 나머지 조합은 PRD 범위 밖의 부가 기능으로 남겨둔다.
    ///
    /// 주중 승급 시(RK-08 / §8.6) 서버는 이 사용자의 행을 새 티어 보드로 옮기며
    /// **주간 누적 거리를 그대로 이관한다** — 재계산 기준이 `runs`의 주간 합계라
    /// 별도 이관 로직 없이 자연히 성립한다. 승급 직후 갱신에서 이전 티어 보드의
    /// 잔여 행이 정리되는지는 backend가 보장한다.
    Tier? tier,

    /// **행 소유자의 실제 개인 티어**(마이그레이션 24). [tier]는 "이 보드가 어느
    /// 티어로 필터링됐는지"(조회 조건)라 티어 무관 보드(tier IS NULL — "전체",
    /// "오늘의 Top 러너")에서는 항상 null인 반면, 이 필드는 그 보드가 무엇이든
    /// 항상 채워진다 — 화면에 "이 사람이 실제로 무슨 티어인지" 배지를 그릴 때는
    /// 반드시 이 필드를 쓴다([tier]를 쓰면 전체 보드에서 늘 null이 나온다).
    Tier? ownerTier,

    /// 티어 내 참가자 수. RK-04의 "상위 N%" 표기를 클라이언트에서 계산하기
    /// 위한 값 — `rank / tierParticipantCount`. 없으면 절대 순위만 표시한다.
    int? participantCount,

    /// 집계 기간의 시작/끝(UTC, 반열림 구간 [start, end)).
    required DateTime periodStart,
    required DateTime periodEnd,

    /// 부가 표시용 — 해당 기간의 러닝 횟수/총 시간.
    int? runCount,
    int? totalMovingSeconds,

    /// 서버가 이 행을 집계한 시각(UTC). 화면의 "N분 전 기준" 표시에 사용.
    DateTime? computedAt,
  }) = _RankingEntry;

  factory RankingEntry.fromJson(Map<String, dynamic> json) =>
      _$RankingEntryFromJson(json);

  /// RK-04 "상위 N%" 표기값(1~100). [participantCount]가 없으면 null.
  ///
  /// 1위도 0%가 되지 않도록 올림한다 — "상위 0%"는 사용자에게 의미가 통하지
  /// 않는다. 절대 순위 대신 이 값을 병기하는 이유는 §5.4.1: 브론즈 3,000명 중
  /// 2,847위는 좌절만 주지만 "상위 95%"는 같은 정보를 덜 날카롭게 전달한다.
  int? get topPercent {
    final total = participantCount;
    if (total == null || total <= 0) return null;
    return (rank / total * 100).ceil().clamp(1, 100);
  }
}
