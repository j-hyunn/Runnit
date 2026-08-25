-- =============================================================================
-- Runnit :: 04. 서버 재검증(이상치 플래그) + 프로필 통계 캐시 재계산
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 서버 쓰기 세션 플래그
-- -----------------------------------------------------------------------------
-- 05_server_guards 의 가드 트리거는 "클라이언트가 서버 전용 컬럼을 쓰는 것"을 막는다.
-- 그런데 서버측 함수(통계 재계산 등)도 같은 컬럼을 UPDATE 하므로, 그때는 가드를
-- 통과시켜야 한다. 트랜잭션-로컬 GUC 로 서버 경로임을 표시한다.
-- (SET LOCAL 이므로 트랜잭션 종료 시 자동 해제 -> 클라이언트가 흉내낼 수 없다:
--  클라이언트는 애초에 이 함수를 실행할 권한이 없고, PostgREST 세션에서 임의의
--  set_config 를 호출할 경로도 없다.)
create or replace function public.is_server_write()
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(current_setting('runnit.server_write', true), 'off') = 'on';
$$;

-- -----------------------------------------------------------------------------
-- 포인트 산정 — **PLACEHOLDER** (gamification-designer 확정 대기)
-- -----------------------------------------------------------------------------
-- 현재 규칙: 정상 완료 기록 100m 당 1점. gamification-designer 가 확정 규칙을
-- 회신하면 이 함수 본문만 교체하면 된다(호출부 변경 불필요).
create or replace function public.compute_awarded_points(
  p_status          public.run_status,
  p_is_flagged      boolean,
  p_distance_meters double precision
)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p_status <> 'completed' or p_is_flagged then 0
    else greatest(0, floor(coalesce(p_distance_meters, 0) / 100.0))::integer
  end;
$$;

-- -----------------------------------------------------------------------------
-- 레벨 산정 — **PLACEHOLDER** (gamification-designer 확정 대기)
-- -----------------------------------------------------------------------------
create or replace function public.compute_level(p_total_points integer)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select 1 + (greatest(coalesce(p_total_points, 0), 0) / 1000);
$$;

-- -----------------------------------------------------------------------------
-- 이상치 판정
-- -----------------------------------------------------------------------------
-- 원칙: 기록을 **삭제하지 않는다**. is_flagged/flag_reason 만 세우고 랭킹·통계
-- 집계에서 제외한다. 오탐 시 사용자 문의에 대응할 근거 데이터를 남기기 위함.
-- 임계값 근거:
--   - 평균 7.0 m/s = 2분23초/km. 마라톤 세계기록 평균이 약 5.7 m/s 이므로
--     400m 이상 구간에서 이를 넘으면 사람의 러닝이 아니다(차량 이동 등).
--   - 순간 최고 15 m/s = 54 km/h. 인간 최고 순간속도(약 12 m/s)를 넘는다.
--   - 단일 세션 200km / 24시간 초과는 기록 병합 오류로 본다.
create or replace function public.validate_run(
  p_distance_meters       double precision,
  p_elapsed_seconds       integer,
  p_moving_seconds        integer,
  p_max_speed_mps         double precision,
  p_elevation_gain_meters double precision
)
returns text     -- null = 정상, 그 외 = 플래그 사유
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p_moving_seconds > p_elapsed_seconds
      then 'moving_exceeds_elapsed'
    when p_distance_meters > 0 and p_moving_seconds <= 0
      then 'zero_moving_time'
    when p_distance_meters >= 400
     and p_moving_seconds > 0
     and (p_distance_meters / p_moving_seconds) > 7.0
      then 'implausible_avg_speed'
    when p_max_speed_mps is not null and p_max_speed_mps > 15.0
      then 'implausible_max_speed'
    when p_distance_meters > 200000
      then 'implausible_distance'
    when p_elapsed_seconds > 86400
      then 'implausible_duration'
    when p_elevation_gain_meters is not null and p_elevation_gain_meters > 9000
      then 'implausible_elevation_gain'
    else null
  end;
$$;

-- -----------------------------------------------------------------------------
-- 프로필 통계 캐시 재계산 (전체 재계산 방식)
-- -----------------------------------------------------------------------------
-- 증분(델타) 갱신이 아니라 해당 사용자 기록 전체를 다시 집계한다.
-- 이유: 기록 수정/삭제/플래그 해제 경로마다 델타 부호를 맞추는 것은 오류가 잦고,
-- 한 사용자의 기록 수는 수천 건 규모라 부분 인덱스(runs_user_completed_idx)로
-- 충분히 빠르다. 정합성 > 미세 최적화.
create or replace function public.recompute_profile_stats(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dist    double precision := 0;
  v_moving  integer := 0;
  v_count   integer := 0;
  v_points  integer := 0;
  v_last    timestamptz;
  v_current integer := 0;
  v_longest integer := 0;
  v_today   date := (now() at time zone 'Asia/Seoul')::date;
begin
  select
    coalesce(sum(r.distance_meters), 0),
    coalesce(sum(r.moving_seconds), 0),
    count(*),
    coalesce(sum(r.awarded_points), 0),
    max(coalesce(r.ended_at, r.started_at))
  into v_dist, v_moving, v_count, v_points, v_last
  from public.runs r
  where r.user_id = p_user_id
    and r.status = 'completed'
    and r.is_flagged = false;

  -- 스트릭: KST 기준 "러닝한 날짜" 집합의 연속 구간(gaps-and-islands)
  with days as (
    select distinct (coalesce(r.ended_at, r.started_at) at time zone 'Asia/Seoul')::date as d
    from public.runs r
    where r.user_id = p_user_id
      and r.status = 'completed'
      and r.is_flagged = false
  ),
  grouped as (
    select d, d - (row_number() over (order by d))::integer as grp
    from days
  ),
  islands as (
    select max(d) as last_day, count(*)::integer as len
    from grouped
    group by grp
  )
  select
    coalesce(max(len), 0),
    -- 오늘 또는 어제까지 이어진 구간만 "현재 진행 중"으로 본다.
    coalesce(max(len) filter (where last_day >= v_today - 1), 0)
  into v_longest, v_current
  from islands;

  perform set_config('runnit.server_write', 'on', true);

  update public.profiles p
  set total_distance_meters = v_dist,
      total_moving_seconds  = v_moving,
      total_run_count       = v_count,
      total_points          = v_points,
      level                 = public.compute_level(v_points),
      current_streak_days   = v_current,
      longest_streak_days   = v_longest,
      last_run_at           = v_last,
      updated_at            = now()
  where p.id = p_user_id;

  perform set_config('runnit.server_write', 'off', true);
end;
$$;

revoke execute on function public.recompute_profile_stats(uuid) from public, anon, authenticated;

-- runs 변경 시 소유자 통계 재계산
create or replace function public.trg_runs_recompute_stats()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recompute_profile_stats(old.user_id);
    return old;
  end if;

  perform public.recompute_profile_stats(new.user_id);
  if tg_op = 'UPDATE' and old.user_id is distinct from new.user_id then
    perform public.recompute_profile_stats(old.user_id);
  end if;
  return new;
end;
$$;

create trigger runs_recompute_stats
after insert or update or delete on public.runs
for each row execute function public.trg_runs_recompute_stats();
