-- =============================================================================
-- Runnit :: 03. 리더보드 (집계 캐시 테이블 + 갱신 함수)
-- -----------------------------------------------------------------------------
-- 전략 선택: **배치 갱신 캐시 테이블**.
--   - 매 조회마다 runs 를 전체 집계하면 사용자/기록 수에 선형으로 느려진다.
--   - Materialized View 는 REFRESH 시 전체 재계산 + CONCURRENTLY 여도 스코프별
--     부분 갱신이 불가능하고, rank_delta(직전 집계 대비 변동)를 계산할 수 없다.
--   - 일반 테이블 + UPSERT 는 (a) 스코프/기간별 부분 갱신, (b) 이전 rank 를 읽어
--     rank_delta 산출, (c) Realtime 구독 가능 이라는 세 요구를 모두 만족한다.
--
-- 기간 경계 타임존: **Asia/Seoul 고정** (리더 확정사항).
--   weekly 는 date_trunc('week') = ISO 8601 기준 **월요일 00:00 KST** 시작.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 기간 경계 계산. 반열림 구간 [period_start, period_end)
-- -----------------------------------------------------------------------------
-- all_time 은 'infinity'::timestamptz 를 쓰지 않는다. PostgREST 가 "infinity"
-- 문자열로 직렬화하면 Dart 의 DateTime.parse 가 FormatException 을 던진다.
-- 대신 파싱 가능한 센티넬(1970-01-01 / 9999-12-31)을 쓴다.
create or replace function public.leaderboard_period_bounds(
  p_period public.ranking_period,
  p_anchor timestamptz default now()
)
returns table (period_start timestamptz, period_end timestamptz)
language sql
immutable
set search_path = public, pg_temp
as $$
  select
    case p_period
      when 'daily'    then (date_trunc('day',   p_anchor at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul'
      when 'weekly'   then (date_trunc('week',  p_anchor at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul'
      when 'monthly'  then (date_trunc('month', p_anchor at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul'
      when 'all_time' then timestamptz '1970-01-01T00:00:00Z'
    end,
    case p_period
      when 'daily'    then (date_trunc('day',   p_anchor at time zone 'Asia/Seoul') + interval '1 day')   at time zone 'Asia/Seoul'
      when 'weekly'   then (date_trunc('week',  p_anchor at time zone 'Asia/Seoul') + interval '1 week')  at time zone 'Asia/Seoul'
      when 'monthly'  then (date_trunc('month', p_anchor at time zone 'Asia/Seoul') + interval '1 month') at time zone 'Asia/Seoul'
      when 'all_time' then timestamptz '9999-12-31T23:59:59Z'
    end;
$$;

-- -----------------------------------------------------------------------------
-- leaderboard_entries  <-> Dart RankingEntry (읽기 전용)
-- -----------------------------------------------------------------------------
-- username/display_name/avatar_url 은 집계 시점 스냅샷(비정규화) — 프로필 조인 왕복 제거.
create table public.leaderboard_entries (
  user_id              uuid not null references public.profiles (id) on delete cascade,

  username             text not null,
  display_name         text,
  avatar_url           text,

  rank                 integer not null,
  rank_delta           integer,          -- 양수 = 상승. 첫 진입이면 null
  metric               public.ranking_metric not null,
  score                double precision not null,
  tie_break_value      double precision, -- 작을수록 상위
  period               public.ranking_period not null,
  scope                public.ranking_scope  not null,
  crew_id              uuid,
  period_start         timestamptz not null,
  period_end           timestamptz not null,
  run_count            integer,
  total_moving_seconds integer,
  computed_at          timestamptz not null default now(),

  -- 모델에 없는 내부 컬럼: crew_id 가 NULL 이어도 UPSERT 충돌 추론이 되도록 하는 대체키.
  -- (NULL 은 UNIQUE 비교에서 서로 다르게 취급되어 ON CONFLICT 추론이 불가능하다.)
  -- json_serializable 은 미인식 키를 무시하므로 RankingEntry.fromJson 을 깨지 않는다.
  crew_key uuid generated always as
    (coalesce(crew_id, '00000000-0000-0000-0000-000000000000'::uuid)) stored,

  constraint leaderboard_entries_pk
    primary key (scope, crew_key, period, metric, period_start, user_id),
  constraint leaderboard_entries_rank_positive check (rank >= 1),
  constraint leaderboard_entries_crew_scope
    check ((scope = 'crew') = (crew_id is not null))
);

-- 리더보드 페이지 조회: 스코프/기간/지표 고정 + rank 순 상위 N
create index leaderboard_entries_read_idx
  on public.leaderboard_entries (scope, crew_key, period, metric, period_start, rank);

-- "내 순위" 단건 조회
create index leaderboard_entries_user_idx
  on public.leaderboard_entries (user_id, period, metric);

comment on table public.leaderboard_entries is
  'RankingEntry 집계 캐시. 클라이언트 쓰기 금지(RLS: select only). refresh_leaderboard() 로만 갱신.';

-- -----------------------------------------------------------------------------
-- 단일 (scope, crew, period, metric) 조합 갱신
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
      sum(r.distance_meters)                    as dist_m,
      sum(r.moving_seconds)::bigint             as moving_s,
      count(*)::bigint                          as run_cnt,
      coalesce(sum(r.awarded_points), 0)::bigint as pts
    from public.runs r
    join public.profiles p on p.id = r.user_id
    where r.status = 'completed'
      and r.is_flagged = false          -- 서버 재검증 이상치 제외
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
        when 'points'    then b.pts::double precision
      end                                as score,
      -- 동점 처리 보조값(초, 작을수록 상위). gamification-designer 확인 대기.
      b.moving_s::double precision       as tie_break_value,
      b.run_cnt::integer                 as run_count,
      b.moving_s::integer                as total_moving_seconds
    from base b
  ),
  ranked as (
    select
      s.*,
      -- 확정 정렬: score DESC -> tie_break_value ASC -> user_id ASC
      -- RANK() 이므로 동점자는 순위를 공유하고 다음 순위를 건너뛴다 (1,2,2,4).
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
    -- 직전 집계 순위 - 새 순위. 양수 = 상승.
    rank_delta           = le.rank - excluded.rank,
    rank                 = excluded.rank,
    score                = excluded.score,
    tie_break_value      = excluded.tie_break_value,
    period_end           = excluded.period_end,
    run_count            = excluded.run_count,
    total_moving_seconds = excluded.total_moving_seconds,
    computed_at          = excluded.computed_at;

  get diagnostics v_count = row_count;

  -- 이번 갱신에서 빠진(기록 삭제/플래그 처리로 탈락한) 행 정리
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
-- 전체 조합 일괄 갱신 — cron 진입점
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

-- 클라이언트가 이 함수를 RPC 로 호출하지 못하게 한다(서버/cron 전용).
revoke execute on function public.refresh_leaderboard(
  public.ranking_period, public.ranking_metric, public.ranking_scope, uuid, timestamptz
) from public, anon, authenticated;
revoke execute on function public.refresh_all_leaderboards(timestamptz) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 주기 갱신 스케줄 (원격 반영 시 사용자 승인 후 활성화)
-- -----------------------------------------------------------------------------
-- pg_cron 확장을 켠 뒤 아래를 실행한다. 5분 주기는 초기 규모 기준값이며,
-- 갱신 소요 시간이 주기의 30% 를 넘기 시작하면 주기를 늘리거나
-- daily/weekly 만 잦게, monthly/all_time 은 드물게로 분리한다.
--
--   create extension if not exists pg_cron;
--   select cron.schedule('runnit-leaderboard', '*/5 * * * *',
--                        $cron$ select public.refresh_all_leaderboards(); $cron$);

-- Realtime: 리더보드 변동을 클라이언트가 폴링 없이 구독한다.
-- 단, 갱신이 5분 배치이므로 체감 실시간성은 배치 주기에 종속된다 ->
-- UI 에 computed_at 기준 "N분 전" 표기를 함께 노출할 것(flutter-ui-designer 협의).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.leaderboard_entries;
  end if;
end;
$$;
