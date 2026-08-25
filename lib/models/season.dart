/// 시즌 · 주간 경계 계산 (PRD §8.5).
///
/// ## 왜 테이블이 아니라 순수 함수인가
/// 시즌은 **역년 분기**로 고정되어 있다 — 1/4/7/10월 1일 00:00 KST 시작.
/// 즉 시즌 목록은 달력에서 결정론적으로 유도되며, 운영자가 시즌을 만들거나
/// 날짜를 조정하는 절차가 없다. `seasons` 테이블을 두면
/// (a) 매 분기 행을 미리 심어두는 운영 작업이 생기고,
/// (b) 행이 없는 분기에 러닝이 들어오면 FK 위반으로 업로드가 실패하며,
/// (c) 클라이언트가 "다음 티어까지 N km"를 그리려고 시즌 경계를 조회하는
///     네트워크 왕복이 추가된다.
/// 반면 얻는 것은 없다 — 시즌에 붙일 가변 속성(이름·보상 등)이 현재 없다.
///
/// **결론: 시즌은 `seasonId` 문자열(예: `2026-Q3`) + 경계 계산 함수로만 표현한다.**
/// 시즌별 메타데이터(시즌 한정 뱃지·시즌 테마 등, PRD GM-08)가 필요해지면 그때
/// `seasons` 테이블을 추가한다. 그 경우에도 `seasonId`가 자연키가 되므로
/// 지금 저장한 값은 그대로 재사용된다 — 마이그레이션 비용이 낮다.
///
/// ## 첫 시즌(단축 시즌)
/// PRD §8.5의 "첫 시즌은 단축 시즌"은 **별도 개념이 아니다.** 출시일이 속한
/// 분기가 그대로 첫 시즌이고, 사용자가 분기 도중에 합류할 뿐이다. 티어는
/// 절대평가라 기간이 짧아도 판정이 정상 작동한다(§5.3 설계 전제). 따라서
/// 코드/스키마에 단축 시즌 분기 처리를 두지 않는다.
///
/// ## 타임존
/// KST(Asia/Seoul, UTC+9)는 서머타임이 없어 고정 오프셋으로 안전하게 계산할 수
/// 있다. 시각 계약(§0)에 따라 이 파일이 반환하는 `DateTime`은 전부 **UTC**다.
library;

/// KST 고정 오프셋. 대한민국은 1988년 이후 서머타임을 시행하지 않는다.
const Duration kstOffset = Duration(hours: 9);

/// 시즌 식별자 유틸. `"{연도}-Q{1..4}"` 형식.
///
/// 이 형식을 택한 이유: GM-07 티어 달성 뱃지 이름("2026 Q3 플래티넘")에 그대로
/// 쓰이고, 문자열 정렬이 곧 시간 순 정렬이 된다(`2026-Q3` < `2026-Q4` < `2027-Q1`).
abstract final class Season {
  /// [instant](UTC)가 속한 시즌 id. 예: `2026-Q3`.
  static String idAt(DateTime instant) {
    final kst = instant.toUtc().add(kstOffset);
    final quarter = ((kst.month - 1) ~/ 3) + 1;
    return '${kst.year}-Q$quarter';
  }

  /// 현재 시즌 id.
  static String currentId({DateTime? now}) =>
      idAt(now?.toUtc() ?? DateTime.now().toUtc());

  /// 시즌 시작 시각(UTC). 반열림 구간 `[start, end)`의 start.
  static DateTime startOf(String seasonId) {
    final (year, quarter) = _parse(seasonId);
    // KST 벽시계 기준 분기 첫날 00:00 → UTC 로 환산.
    return DateTime.utc(year, (quarter - 1) * 3 + 1).subtract(kstOffset);
  }

  /// 시즌 종료 시각(UTC, **배타적**). 다음 시즌의 시작과 동일하다.
  static DateTime endOf(String seasonId) => startOf(nextId(seasonId));

  static String nextId(String seasonId) {
    final (year, quarter) = _parse(seasonId);
    return quarter == 4 ? '${year + 1}-Q1' : '$year-Q${quarter + 1}';
  }

  static String previousId(String seasonId) {
    final (year, quarter) = _parse(seasonId);
    return quarter == 1 ? '${year - 1}-Q4' : '$year-Q${quarter - 1}';
  }

  /// 시즌 종료까지 남은 기간. TI-07(D-14 / D-3 알림)의 클라이언트 표시용.
  static Duration remaining(String seasonId, {DateTime? now}) {
    final at = now?.toUtc() ?? DateTime.now().toUtc();
    final end = endOf(seasonId);
    return end.isAfter(at) ? end.difference(at) : Duration.zero;
  }

  /// 러닝이 어느 시즌에 귀속되는지 — **시작 시각 기준**(§8.5 "경계 걸침").
  /// 종료 시각이 아니라 시작 시각을 쓰는 이유: 자정을 넘겨 달린 기록이
  /// 다음 시즌/다음 주로 튕겨 나가는 것을 막기 위함이다.
  static String idForRun(DateTime runStartedAt) => idAt(runStartedAt);

  static (int, int) _parse(String seasonId) {
    final m = RegExp(r'^(\d{4})-Q([1-4])$').firstMatch(seasonId);
    if (m == null) {
      throw FormatException('잘못된 seasonId 형식 (기대: 2026-Q3)', seasonId);
    }
    return (int.parse(m.group(1)!), int.parse(m.group(2)!));
  }
}

/// 주간 랭킹 경계 (PRD RK-01: KST 월요일 00:00 ~ 일요일 23:59).
abstract final class RankingWeek {
  /// [instant]가 속한 주의 시작(월요일 00:00 KST)을 UTC로 반환.
  static DateTime startOf(DateTime instant) {
    final kst = instant.toUtc().add(kstOffset);
    final midnight = DateTime.utc(kst.year, kst.month, kst.day);
    // DateTime.weekday: 월=1 … 일=7
    final monday = midnight.subtract(Duration(days: kst.weekday - 1));
    return monday.subtract(kstOffset);
  }

  /// 주간 종료(배타적) = 다음 주 월요일 00:00 KST.
  static DateTime endOf(DateTime instant) =>
      startOf(instant).add(const Duration(days: 7));
}
