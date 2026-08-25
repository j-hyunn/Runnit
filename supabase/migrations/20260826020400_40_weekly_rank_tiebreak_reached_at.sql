-- =============================================================================
-- Runnit :: 40. 주간 랭킹 동점 처리(PRD §8.2) + reached_at 컬럼
-- -----------------------------------------------------------------------------
-- 정본: _workspace/20260826_000340_gamification_badge-backlog-decisions.md §2.2 · §2.5
--       docs/PRD.md §8.2 · docs/TRD.md §10.2
--
-- ⚠️ 테이블 이름에 대한 구현 노트 (문서 ↔ 라이브 스키마)
--    설계 문서들은 이 캐시를 `weekly_ranking_cache` 라고 부른다(TRD §4 Phase 0 초안).
--    **라이브 스키마의 실제 이름은 `public.leaderboard_entries`**(마이그레이션 03)이고,
--    §2.5 가 요구한 컬럼이 이미 전부 들어 있다:
--      week_id           -> period_start (+ period='weekly')
--      season_id         -> period_start 이 속한 시즌(season_id_at)
--      weekly_distance_m -> score (metric='distance')
--      weekly_run_count  -> run_count
--      weekly_moving_sec -> total_moving_seconds
--      rank              -> rank        (배치가 기록 — 조회 시 재계산하지 않는다)
--      tier              -> tier        (주 종료 시점 확정 티어)
--      N                 -> participant_count
--    **유일하게 없던 것이 `reached_at`** 이고, 이것 없이는 PRD §8.2 ②를 구현할 수 없다.
--    마이그레이션 32/33 의 season_weekly_rank_* 판정도 이미 이 테이블을 읽고 있으므로
--    새 테이블을 만들지 않고 이 테이블에 컬럼을 더한다. TRD §4 초안 DDL 은 갱신했다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 40-1. reached_at 컬럼
-- -----------------------------------------------------------------------------
alter table public.leaderboard_entries
  add column if not exists reached_at timestamptz;

comment on column public.leaderboard_entries.reached_at is
  '이 기간 누적 거리가 최종값에 도달한 러닝의 started_at (= 기간 내 마지막 집계 대상 러닝). '
  'PRD §8.2 동점 처리 ②"먼저 해당 거리에 도달한 사람"의 유일한 근거 컬럼이다. '
  '이 값이 없으면 §8.2 를 구현할 수 없어 40번에서 신설했다.';

-- -----------------------------------------------------------------------------
-- 40-2. refresh_leaderboard — PRD §8.2 3단계 타이브레이크 + user_id 최종 폴백
-- -----------------------------------------------------------------------------
-- 기존(마이그레이션 11/23/24)은 `score desc, tie_break_value asc, user_id asc` 였다.
-- distance 지표에서 tie_break_value = 총 이동시간이므로, PRD §8.2 의 ①러닝 횟수와
-- ②도달 시각을 건너뛰고 ③만 적용하고 있었다 — 순위 자체는 결정적이었지만 정책과 달랐다.
--
-- 확정 순서 (distance 지표):
--   ① 주간 거리 내림차순
--   ② 더 적은 러닝 횟수 (효율)
--   ③ 먼저 해당 거리에 도달한 사람 (reached_at 오름차순)
--   ④ 총 러닝 시간이 짧은 사람 (페이스)
--   ⑤ user_id 오름차순 — 결정성 확보용 최종 폴백(§2.2). 공동 순위는 만들지 않는다.
--
-- duration / run_count 지표는 §8.2 의 적용 대상이 아니므로 기존 tie_break_value 순서를
-- 그대로 둔다. 아래 case 식은 distance 가 아닐 때 전부 NULL 이 되어 정렬에 영향이 없다.
create or replace function public.refresh_leaderboard(
  p_period  public.ranking_period,
  p_metric  public.ranking_metric,
  p_scope   public.ranking_scope default 'global',
  p_crew_id uuid default null,
  p_anchor  timestamptz default now(),
  p_tier    public.tier default null
)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_start    timestamptz;
  v_end      timestamptz;
  v_now      timestamptz := now();
  v_tier_key text := coalesce(p_tier::text, '_all');
  v_count    integer;
begin
  if p_scope = 'friends' then
    raise exception 'friends 스코프는 아직 미지원 (친구 관계 테이블 미정의)';
  end if;
  if (p_scope = 'crew') <> (p_crew_id is not null) then
    raise exception 'crew 스코프에는 p_crew_id 가 필요하고, 그 외 스코프에는 NULL 이어야 한다';
  end if;

  select b.period_start, b.period_end
    into v_start, v_end
    from public.leaderboard_period_bounds(p_period, p_anchor) b;

  with base as (
    select
      r.user_id,
      sum(r.distance_meters)         as dist_m,
      sum(r.moving_seconds)::bigint  as moving_s,
      count(*)::bigint               as run_cnt,
      -- 누적 거리가 최종값에 도달하는 시점 = 기간 내 마지막 집계 대상 러닝의 시작 시각.
      max(r.started_at)              as reached_at
    from public.runs r
    join public.profiles p on p.id = r.user_id
    where r.status = 'completed'
      and r.is_flagged = false
      and r.activity_type <> 'indoor_run'   -- PRD §8.3 실내·수동 제외
      and r.started_at >= v_start
      and r.started_at <  v_end
      and (p_scope <> 'crew' or p.crew_id = p_crew_id)
      and (p_tier is null or p.current_tier = p_tier)
    group by r.user_id
  ),
  scored as (
    select
      b.user_id,
      case p_metric
        when 'distance'  then b.dist_m
        when 'duration'  then b.moving_s::double precision
        when 'run_count' then b.run_cnt::double precision
      end                                as score,
      case p_metric
        when 'duration'  then -1 * b.dist_m
        when 'run_count' then -1 * b.dist_m
        else                   b.moving_s::double precision
      end                                as tie_break_value,
      b.run_cnt::integer                 as run_count,
      b.moving_s::integer                as total_moving_seconds,
      b.reached_at                       as reached_at
    from base b
  ),
  ranked as (
    select
      s.*,
      rank() over (
        order by
          s.score desc,
          case when p_metric = 'distance' then s.run_count            end asc,
          case when p_metric = 'distance' then s.reached_at           end asc,
          case when p_metric = 'distance' then s.total_moving_seconds end asc,
          s.tie_break_value asc,
          s.user_id asc
      )::integer as rnk,
      (count(*) over ())::integer as participant_count
    from scored s
    where s.score > 0        -- 주간 거리 0 인 사용자는 순위를 갖지 않는다(§2.2 모집단)
  )
  insert into public.leaderboard_entries as le (
    user_id, username, display_name, avatar_url,
    rank, rank_delta, metric, score, tie_break_value,
    period, scope, crew_id, tier, owner_tier, period_start, period_end,
    run_count, total_moving_seconds, participant_count, reached_at, computed_at
  )
  select
    k.user_id, p.username, p.display_name, p.avatar_url,
    k.rnk, null, p_metric, k.score, k.tie_break_value,
    p_period, p_scope, p_crew_id, p_tier, p.current_tier, v_start, v_end,
    k.run_count, k.total_moving_seconds, k.participant_count, k.reached_at, v_now
  from ranked k
  join public.profiles p on p.id = k.user_id
  on conflict (scope, crew_key, tier_key, period, metric, period_start, user_id)
  do update set
    username             = excluded.username,
    display_name         = excluded.display_name,
    avatar_url           = excluded.avatar_url,
    rank_delta           = le.rank - excluded.rank,
    rank                 = excluded.rank,
    score                = excluded.score,
    tie_break_value      = excluded.tie_break_value,
    owner_tier           = excluded.owner_tier,
    period_end           = excluded.period_end,
    run_count            = excluded.run_count,
    total_moving_seconds = excluded.total_moving_seconds,
    participant_count    = excluded.participant_count,
    reached_at           = excluded.reached_at,
    computed_at          = excluded.computed_at;

  get diagnostics v_count = row_count;

  delete from public.leaderboard_entries le
  where le.scope        = p_scope
    and le.crew_key     = coalesce(p_crew_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and le.tier_key     = v_tier_key
    and le.period       = p_period
    and le.metric       = p_metric
    and le.period_start = v_start
    and le.computed_at  < v_now;

  return v_count;
end;
$function$;

comment on function public.refresh_leaderboard(
  public.ranking_period, public.ranking_metric, public.ranking_scope, uuid, timestamptz, public.tier) is
  '리더보드 캐시 갱신. distance 지표는 PRD §8.2 3단계 타이브레이크(러닝 횟수 -> reached_at -> 총 시간) '
  '+ user_id 최종 폴백으로 **고유 순위**를 부여한다(공동 순위 없음). rank 는 여기서 확정해 기록하며 '
  '조회 시 재계산하지 않는다.';

revoke execute on function public.refresh_leaderboard(
  public.ranking_period, public.ranking_metric, public.ranking_scope, uuid, timestamptz, public.tier)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 40-3. 기존 캐시 재계산 — reached_at 을 채우고 새 순서로 순위를 다시 매긴다
-- -----------------------------------------------------------------------------
select public.refresh_all_leaderboards(now());
