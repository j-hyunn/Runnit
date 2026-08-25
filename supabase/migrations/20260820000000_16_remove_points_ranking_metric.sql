-- =============================================================================
-- Runnit :: 16. 랭킹 지표에서 `points`(게이미피케이션 포인트) 제거
-- -----------------------------------------------------------------------------
-- 리더 결정(2026-08-20): 포인트 랭킹은 굳이 필요 없다고 판단해 제거한다.
-- 짝을 이루는 클라이언트 변경: lib/models/enums.dart RankingMetric.points 삭제.
--
-- 뱃지/챌린지로 얻는 게이미피케이션 포인트 자체(profiles.total_points, 레벨 산정)는
-- 그대로 유지된다 — 없앤 것은 "포인트로 순위를 매기는 리더보드"뿐이다.
--
-- Postgres 는 enum 값을 직접 DROP 하는 기능이 없으므로(ADD VALUE 만 지원),
-- 새 enum 타입을 만들어 컬럼을 이관한 뒤 이름을 바꿔치기한다. leaderboard_entries.metric
-- 은 PK 구성 컬럼이고, refresh_leaderboard()/refresh_all_leaderboards() 는 각각
-- 파라미터 타입과 DECLARE 변수 타입으로 이 enum 에 의존하므로, 타입 교체 전에
-- 두 함수를 먼저 DROP 해야 한다(그렇지 않으면 DROP TYPE 이 의존성 에러로 실패한다).
-- =============================================================================

delete from public.leaderboard_entries where metric = 'points';

create type public.ranking_metric_new as enum ('distance', 'duration', 'run_count');

alter table public.leaderboard_entries
  alter column metric type public.ranking_metric_new
  using metric::text::public.ranking_metric_new;

drop function if exists public.refresh_leaderboard(
  public.ranking_period, public.ranking_metric, public.ranking_scope, uuid, timestamptz);
drop function if exists public.refresh_all_leaderboards(timestamptz);

drop type public.ranking_metric;
alter type public.ranking_metric_new rename to ranking_metric;

-- -----------------------------------------------------------------------------
-- 16-1. refresh_leaderboard 재생성 — 'points' 케이스 및 base CTE 의 pts 집계 제거
-- -----------------------------------------------------------------------------
create or replace function public.refresh_leaderboard(
  p_period public.ranking_period,
  p_metric public.ranking_metric,
  p_scope  public.ranking_scope default 'global',
  p_crew_id uuid default null,
  p_anchor timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_end   timestamptz;
  v_now   timestamptz := now();
  v_count integer;
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
      and r.started_at >= v_start
      and r.started_at <  v_end
      and (p_scope <> 'crew' or p.crew_id = p_crew_id)
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
      )::integer as rnk
    from scored s
    where s.score > 0
  )
  insert into public.leaderboard_entries as le (
    user_id, username, display_name, avatar_url,
    rank, rank_delta, metric, score, tie_break_value,
    period, scope, crew_id, period_start, period_end,
    run_count, total_moving_seconds, computed_at
  )
  select
    k.user_id, p.username, p.display_name, p.avatar_url,
    k.rnk, null, p_metric, k.score, k.tie_break_value,
    p_period, p_scope, p_crew_id, v_start, v_end,
    k.run_count, k.total_moving_seconds, v_now
  from ranked k
  join public.profiles p on p.id = k.user_id
  on conflict (scope, crew_key, period, metric, period_start, user_id)
  do update set
    username             = excluded.username,
    display_name         = excluded.display_name,
    avatar_url           = excluded.avatar_url,
    rank_delta           = le.rank - excluded.rank,
    rank                 = excluded.rank,
    score                = excluded.score,
    tie_break_value      = excluded.tie_break_value,
    period_end           = excluded.period_end,
    run_count            = excluded.run_count,
    total_moving_seconds = excluded.total_moving_seconds,
    computed_at          = excluded.computed_at;

  get diagnostics v_count = row_count;

  delete from public.leaderboard_entries le
  where le.scope        = p_scope
    and le.crew_key     = coalesce(p_crew_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and le.period       = p_period
    and le.metric       = p_metric
    and le.period_start = v_start
    and le.computed_at  < v_now;

  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- 16-2. refresh_all_leaderboards 재생성 — enum_range 로 자동 순회하므로 본문 불변
-- -----------------------------------------------------------------------------
create or replace function public.refresh_all_leaderboards(
  p_anchor timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period public.ranking_period;
  v_metric public.ranking_metric;
  v_crew   uuid;
begin
  foreach v_period in array enum_range(null::public.ranking_period) loop
    foreach v_metric in array enum_range(null::public.ranking_metric) loop
      perform public.refresh_leaderboard(v_period, v_metric, 'global', null, p_anchor);

      for v_crew in
        select distinct crew_id from public.profiles where crew_id is not null
      loop
        perform public.refresh_leaderboard(v_period, v_metric, 'crew', v_crew, p_anchor);
      end loop;
    end loop;
  end loop;
end;
$$;

revoke execute on function public.refresh_leaderboard(
  public.ranking_period, public.ranking_metric, public.ranking_scope, uuid, timestamptz
) from public, anon, authenticated;
revoke execute on function public.refresh_all_leaderboards(timestamptz) from public, anon, authenticated;

comment on column public.leaderboard_entries.tie_break_value is
  '동점 보조값(작을수록 상위). distance=sum(moving_seconds), duration/run_count=-1*sum(distance_meters). '
  '정렬 전용 내부값이며 UI 노출 금지. (points 지표는 리더 결정으로 제거됨 — badge_rules 후속 문서 참조)';
