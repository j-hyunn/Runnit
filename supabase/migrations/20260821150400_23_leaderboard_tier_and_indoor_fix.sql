-- =============================================================================
-- Runnit :: 23. 🔴 §8.3 결함 수정(트레드밀 랭킹 반영) + 리더보드 티어 차원
-- -----------------------------------------------------------------------------
-- 근거: architect 문서 §6(결함), §7-7, §7-8 / PRD §8.3, RK-02, RK-04, RK-08, §8.6
--
-- (A) 결함: refresh_leaderboard() 의 base CTE 에 activity_type 조건이 없어
--     트레드밀(indoor_run) 기록이 주간 랭킹 점수에 합산되고 있었다.
--     PRD §8.3 "트레드밀 기록 -> 주간 랭킹 ❌ 미반영" 위반. base CTE 에
--     `and r.activity_type <> 'indoor_run'` 를 추가한다.
--
--     ⚠️ recompute_profile_stats() 는 **고치지 않는다.** §8.3 은 누적 통계·히스토리에는
--        트레드밀을 반영하라고 명시하므로, 거기에 같은 필터를 넣으면 오히려 PRD 위반이다.
--
-- (B) 티어 차원: leaderboard_entries 에 tier(nullable) / participant_count 추가.
--     nullable 컬럼은 ON CONFLICT 추론이 되지 않으므로 기존 crew_key 와 동일한 패턴으로
--     tier_key 생성 컬럼을 두고 PK 를 재정의한다.
--     tier = null 은 "티어 미분할 통합 보드"로, 기존 daily/monthly/all_time 보드가
--     그대로 살아 있게 한다(삭제하지 않는다).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 23-1. 컬럼 + PK 재정의
-- -----------------------------------------------------------------------------
alter table public.leaderboard_entries
  add column tier              public.tier,
  add column participant_count integer;

-- crew_key 와 같은 이유: NULL 은 UNIQUE 비교에서 서로 다르게 취급되어 ON CONFLICT
-- 추론이 불가능하다. json_serializable 은 미인식 키를 무시하므로 RankingEntry.fromJson
-- 을 깨지 않는다.
-- ⚠️ `coalesce(tier::text, '_all')` 로 쓸 수 없다 — enum 의 출력 함수(enum_out)는
--    STABLE 이라 생성 컬럼 식에 쓰면 "generation expression is not immutable" 로 거부된다.
--    enum = enum 비교 연산자는 IMMUTABLE 이므로 CASE 로 동일한 결과를 얻는다.
--    (tier 가 NULL 이면 모든 WHEN 이 NULL 이 되어 ELSE 로 떨어진다 -> '_all')
alter table public.leaderboard_entries
  add column tier_key text generated always as (
    case tier
      when 'bronze'   then 'bronze'
      when 'silver'   then 'silver'
      when 'gold'     then 'gold'
      when 'platinum' then 'platinum'
      else '_all'
    end
  ) stored;

alter table public.leaderboard_entries
  drop constraint leaderboard_entries_pk;

alter table public.leaderboard_entries
  add constraint leaderboard_entries_pk
    primary key (scope, crew_key, tier_key, period, metric, period_start, user_id);

-- 조회 인덱스도 티어 차원을 포함하도록 교체.
drop index if exists public.leaderboard_entries_read_idx;
create index leaderboard_entries_read_idx
  on public.leaderboard_entries (scope, crew_key, tier_key, period, metric, period_start, rank);

comment on column public.leaderboard_entries.tier is
  'RK-02 티어 내 랭킹. NULL = 티어 미분할 통합 보드. scope(모집단 축)와 직교하는 필터 축이다.';
comment on column public.leaderboard_entries.participant_count is
  'RK-04 "상위 N%" 계산용 해당 보드 모집단 크기. RankingEntry.topPercent 가 사용한다.';
comment on column public.leaderboard_entries.tier_key is
  '모델에 없는 내부 컬럼. tier 가 NULL 이어도 ON CONFLICT 추론이 되도록 하는 대체키(crew_key 와 동일 패턴).';

-- -----------------------------------------------------------------------------
-- 23-2. refresh_leaderboard 재정의
-- -----------------------------------------------------------------------------
-- 파라미터가 하나 늘어난다. 기존 5-인자 함수를 남겨두면 전부 DEFAULT 를 가진
-- 오버로드가 되어 호출이 ambiguous 해지므로 먼저 DROP 한다.
drop function if exists public.refresh_all_leaderboards(timestamptz);
drop function if exists public.refresh_leaderboard(
  public.ranking_period, public.ranking_metric, public.ranking_scope, uuid, timestamptz);

create or replace function public.refresh_leaderboard(
  p_period  public.ranking_period,
  p_metric  public.ranking_metric,
  p_scope   public.ranking_scope default 'global',
  p_crew_id uuid                 default null,
  p_anchor  timestamptz          default now(),
  p_tier    public.tier          default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
      and r.is_flagged = false                -- 서버 재검증 이상치 제외
      and r.activity_type <> 'indoor_run'     -- 🔴 §8.3: 트레드밀은 랭킹 미반영
      and r.started_at >= v_start
      and r.started_at <  v_end
      and (p_scope <> 'crew' or p.crew_id = p_crew_id)
      -- RK-02: 티어 보드는 모집단 자체를 그 티어로 자른다.
      -- 순위는 아래 rank() 가 잘린 모집단 안에서만 매긴다.
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
      (count(*) over ())::integer as participant_count   -- RK-04 모집단 크기
    from scored s
    where s.score > 0
  )
  insert into public.leaderboard_entries as le (
    user_id, username, display_name, avatar_url,
    rank, rank_delta, metric, score, tie_break_value,
    period, scope, crew_id, tier, period_start, period_end,
    run_count, total_moving_seconds, participant_count, computed_at
  )
  select
    k.user_id, p.username, p.display_name, p.avatar_url,
    k.rnk, null, p_metric, k.score, k.tie_break_value,
    p_period, p_scope, p_crew_id, p_tier, v_start, v_end,
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
    period_end           = excluded.period_end,
    run_count            = excluded.run_count,
    total_moving_seconds = excluded.total_moving_seconds,
    participant_count    = excluded.participant_count,
    computed_at          = excluded.computed_at;

  get diagnostics v_count = row_count;

  -- 이번 갱신에서 빠진 행 정리.
  -- RK-08/§8.6: 주중 승급자는 **이전 티어 보드**에서 이 경로로 지워진다.
  -- 따라서 4개 티어 조합을 항상 함께 갱신해야 한다(refresh_all_leaderboards 참조).
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
$$;

-- -----------------------------------------------------------------------------
-- 23-3. refresh_all_leaderboards — cron 진입점
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
  v_tier   public.tier;
begin
  -- (1) 티어 미분할 통합 보드 (tier = null). 기존 동작 그대로.
  foreach v_period in array enum_range(null::public.ranking_period) loop
    foreach v_metric in array enum_range(null::public.ranking_metric) loop
      perform public.refresh_leaderboard(v_period, v_metric, 'global', null, p_anchor, null);

      for v_crew in
        select distinct crew_id from public.profiles where crew_id is not null
      loop
        perform public.refresh_leaderboard(v_period, v_metric, 'crew', v_crew, p_anchor, null);
      end loop;
    end loop;
  end loop;

  -- (2) PRD 기본 랭킹 화면: weekly x distance x global x 4티어 (RK-01+RK-02+RK-03).
  --     ⚠️ 4개 티어를 **항상 함께** 돌려야 한다. 한 티어만 부분 갱신하면 주중 승급자가
  --     이전 티어 보드에 유령 행으로 남는다(정리 로직이 그 조합을 돌아야 지운다) — RK-08.
  foreach v_tier in array enum_range(null::public.tier) loop
    perform public.refresh_leaderboard('weekly', 'distance', 'global', null, p_anchor, v_tier);
  end loop;
end;
$$;

revoke execute on function public.refresh_leaderboard(
  public.ranking_period, public.ranking_metric, public.ranking_scope,
  uuid, timestamptz, public.tier
) from public, anon, authenticated;
revoke execute on function public.refresh_all_leaderboards(timestamptz)
  from public, anon, authenticated;
