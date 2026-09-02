import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/api/realtime_refetch.dart';
import '../../../core/api/supabase_error.dart';
import '../../../core/api/wire_enums.dart';
import '../../../core/repositories/ranking_repository.dart';
import '../../../models/models.dart';

/// [RankingRepository]의 Supabase 구현.
///
/// **집계는 전부 서버가 한다.** 이 클래스는 5분 주기 배치(`refresh_all_leaderboards`,
/// pg_cron)가 채워둔 `public.leaderboard_entries` 캐시 테이블을 그대로 읽는다
/// (`_workspace/20260819_132600_backend_schema.md` §5). 클라이언트는 정렬조차
/// 다시 하지 않는다 — `rank`가 서버의 확정값이다.
///
/// RLS: 로그인 사용자는 전 스코프, 게스트(anon)는 `scope = 'global'` 행만 본다
/// (마이그레이션 17). 게스트가 크루/친구를 요청하면 **에러가 아니라 빈 배열**이
/// 돌아온다 — 랭킹 화면은 이 경우를 로그인 유도 화면으로 처리한다.
class SupabaseRankingRepository implements RankingRepository {
  const SupabaseRankingRepository(this._client);

  final SupabaseClient _client;

  /// 조회(select)는 이 뷰만 읽는다 — `leaderboard_period_bounds(period, now())`가
  /// 정한 **현재 활성 기간** 행만 노출한다(마이그레이션 62). `leaderboard_entries`는
  /// 지난 기간 행을 삭제 없이 누적 보존하고(ARCHITECTURE §5.3), 시즌 말 단축 주간은
  /// 같은 달력 주를 `period_start`가 다른 두 조각으로 나누므로(마이그레이션 61),
  /// 베이스 테이블을 그대로 읽으면 여러 기간 행이 섞여 rank가 중복된다.
  static const _viewTable = 'leaderboard_entries_active';

  /// Realtime 구독 대상 — 뷰는 publication에 없으므로 베이스 테이블을 구독하고
  /// 재조회만 뷰(`_viewTable`)로 한다.
  static const _baseTable = 'leaderboard_entries';

  @override
  Future<List<RankingEntry>> fetchLeaderboard({
    required RankingPeriod period,
    required RankingMetric metric,
    required RankingScope scope,
    Tier? tier,
    String? crewId,
    int limit = 50,
    int offset = 0,
  }) {
    return guardSupabase(() async {
      final rows = await _scoped(period, metric, scope, tier, crewId)
          .order('rank', ascending: true)
          .range(offset, offset + limit - 1);
      return rows.map(RankingEntry.fromJson).toList(growable: false);
    });
  }

  @override
  Future<RankingEntry?> fetchMyEntry({
    required String userId,
    required RankingPeriod period,
    required RankingMetric metric,
    required RankingScope scope,
    Tier? tier,
    String? crewId,
  }) {
    return guardSupabase(() async {
      // 기간 내 기록이 없으면 캐시에 행 자체가 없다 → null이 정상.
      // `_viewTable`이 현재 활성 기간 행만 반환하므로 (period, metric, scope, tier,
      // user_id)당 최대 1행 — `.maybeSingle()`이 안전하다. (베이스 테이블을 직접
      // 읽으면 한 사용자가 여러 주차 행을 가져 다중 행 예외가 났다.)
      final row = await _scoped(period, metric, scope, tier, crewId)
          .eq('user_id', userId)
          .maybeSingle();
      return row == null ? null : RankingEntry.fromJson(row);
    });
  }

  @override
  Stream<List<RankingEntry>> watchLeaderboard({
    required RankingPeriod period,
    required RankingMetric metric,
    required RankingScope scope,
    Tier? tier,
    String? crewId,
    int limit = 50,
  }) {
    // 갱신이 5분 배치라 체감 실시간성은 배치 주기에 묶인다. 구독의 실익은
    // "폴링 제거"이지 "즉시성"이 아니다 — UI는 `computed_at` 기준 시각을 함께 노출한다.
    return watchTableAndRefetch<List<RankingEntry>>(
      client: _client,
      table: _baseTable,
      topicSuffix:
          '${scope.wire}-${period.wire}-${metric.wire}-${tier?.wire ?? 'all'}',
      // Realtime 필터는 단일 컬럼만 지원한다. 스코프로 1차만 좁히고,
      // 나머지 조건(티어 포함)은 재조회 쿼리가 정확히 건다(중복 재조회는 배치 주기상 무해).
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'scope',
        value: scope.wire,
      ),
      fetch: () => fetchLeaderboard(
        period: period,
        metric: metric,
        scope: scope,
        tier: tier,
        crewId: crewId,
        limit: limit,
      ),
    );
  }

  /// period/metric/scope/tier(+crew_id) 공통 필터.
  ///
  /// `period_start`는 조건에 넣지 않는다 — `_viewTable`(마이그레이션 62)이 이미
  /// `leaderboard_period_bounds(period, now())` 기준 현재 활성 기간 행만 반환하므로,
  /// 클라이언트는 KST·시즌 클램프 규칙을 복제할 필요가 없다.
  ///
  /// `tier`는 `scope`와 직교하는 nullable 컬럼(마이그레이션 23) — `tier IS NULL`
  /// 행이 "전체(티어 무관)" 리더보드다. `.eq('tier', null)`은 PostgREST에서
  /// `IS NULL`이 아니라 항상 빈 결과를 주므로 반드시 `.isFilter`를 쓴다.
  PostgrestFilterBuilder<List<Map<String, dynamic>>> _scoped(
    RankingPeriod period,
    RankingMetric metric,
    RankingScope scope,
    Tier? tier,
    String? crewId,
  ) {
    // ⚠️ `select()`에 컬럼 별칭(`as`)을 쓰지 않는다 — RankingEntry.fromJson이 깨진다.
    var query = _client
        .from(_viewTable)
        .select()
        .eq('period', period.wire)
        .eq('metric', metric.wire)
        .eq('scope', scope.wire);

    query = tier == null
        ? query.isFilter('tier', null)
        : query.eq('tier', tier.wire);

    // crew 스코프에서만 crew_id가 non-null이다(CHECK 제약).
    if (scope == RankingScope.crew && crewId != null) {
      query = query.eq('crew_id', crewId);
    }
    return query;
  }
}
