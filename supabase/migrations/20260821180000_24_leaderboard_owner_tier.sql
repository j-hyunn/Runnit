-- 24: leaderboard_entries에 owner_tier(행 소유자의 실제 개인 티어) 추가.
--
-- 기존 `tier` 컬럼은 "이 보드가 어느 티어로 필터링됐는지"(조회 조건)를 뜻하고,
-- 티어 무관 보드(tier IS NULL — "전체", "오늘의 Top 러너")에서는 항상 NULL이라
-- 각 행 주인의 실제 티어를 알 수 없었다. 홈 화면에서 "전체" 랭킹에도 각자의
-- 티어 배지를 보여 달라는 요청(2026-08-21)에 따라, `tier`와 별개로 각 행의
-- 실제 소유자 티어를 항상 채워 넣는 `owner_tier` 컬럼을 추가한다.
alter table public.leaderboard_entries
  add column if not exists owner_tier public.tier;

create or replace function public.refresh_leaderboard(
  p_period ranking_period,
  p_metric ranking_metric,
  p_scope ranking_scope default 'global'::ranking_scope,
  p_crew_id uuid default null::uuid,
  p_anchor timestamptz default now(),
  p_tier tier default null::tier
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
      count(*)::bigint               as run_cnt
    from public.runs r
    join public.profiles p on p.id = r.user_id
    where r.status = 'completed'
      and r.is_flagged = false
      and r.activity_type <> 'indoor_run'
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
      b.moving_s::integer                as total_moving_seconds
    from base b
  ),
  ranked as (
    select
      s.*,
      rank() over (
        order by s.score desc, s.tie_break_value asc, s.user_id asc
      )::integer as rnk,
      (count(*) over ())::integer as participant_count
    from scored s
    where s.score > 0
  )
  insert into public.leaderboard_entries as le (
    user_id, username, display_name, avatar_url,
    rank, rank_delta, metric, score, tie_break_value,
    period, scope, crew_id, tier, owner_tier, period_start, period_end,
    run_count, total_moving_seconds, participant_count, computed_at
  )
  select
    k.user_id, p.username, p.display_name, p.avatar_url,
    k.rnk, null, p_metric, k.score, k.tie_break_value,
    p_period, p_scope, p_crew_id, p_tier, p.current_tier, v_start, v_end,
    k.run_count, k.total_moving_seconds, k.participant_count, v_now
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
