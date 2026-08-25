-- =============================================================================
-- Runnit :: 10. 포인트/레벨 산식 확정 반영 + 프로필 통계 캐시 정합성 수정
-- -----------------------------------------------------------------------------
-- 근거: _workspace/20260819_210450_badge_rules.md §3(포인트), §4(레벨), §2.3(스트릭)
-- 04_validation_and_stats.sql 의 PLACEHOLDER 본문을 여기서 교체한다.
-- (이미 적용된 마이그레이션 파일은 수정하지 않고 CREATE OR REPLACE 로 덮어쓴다.)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3-1. 포인트 산식 — 규칙서 §3.1 확정 공식
-- -----------------------------------------------------------------------------
-- ⚠️ 시그니처 변경 사항 (판단 필요했던 지점):
--    04 파일의 기존 함수는 3인자(status, is_flagged, distance_meters)다.
--    확정 산식은 페이스 보너스와 고도 보너스를 포함하므로 moving_seconds 와
--    elevation_gain_meters 가 반드시 필요하다 -> **5인자 오버로드를 정본으로 추가**하고,
--    기존 3인자 함수는 삭제하지 않고 5인자 정본에 위임하는 얇은 래퍼로 남긴다
--    (규칙서 §3.1 "시그니처가 다르면 호출부에서 인자만 맞춰주면 된다").
--    호출부 trg_runs_guard 는 아래에서 5인자 버전을 쓰도록 갱신한다.
create or replace function public.compute_awarded_points(
  p_status                public.run_status,
  p_is_flagged            boolean,
  p_distance_meters       double precision,
  p_moving_seconds        integer,
  p_elevation_gain_meters double precision
)
returns integer
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_distance_pts numeric;
  v_pace         numeric;   -- s/km
  v_mult         numeric;
  v_pace_pts     numeric;
  v_elev_pts     numeric;
  v_base         constant numeric := 20;   -- 완주 보너스(고정)
begin
  -- ① 자격 검사
  if p_status <> 'completed' or coalesce(p_is_flagged, false) then
    return 0;
  end if;
  -- 500m 미만은 0점. validate_run 의 평균속도 검사 하한(400m)보다 높게 잡아
  -- "검증은 통과했지만 점수는 없는" 구간을 명시적으로 만든다 (규칙서 §3.2).
  if p_distance_meters is null or p_distance_meters < 500 then
    return 0;
  end if;

  -- ② 거리 점수: 100m 당 1점 (10km -> 100pt)
  v_distance_pts := floor(p_distance_meters::numeric / 100.0);

  -- ④ 페이스 보너스: 2km 이상 러닝에만. 거리 점수에 곱한다(짧고 빠른 어뷰징 차단).
  if p_distance_meters >= 2000 and coalesce(p_moving_seconds, 0) > 0 then
    v_pace := p_moving_seconds::numeric / (p_distance_meters::numeric / 1000.0);
  else
    v_pace := null;
  end if;

  v_mult := case
              when v_pace is null then 0.00
              when v_pace <= 300  then 0.30   -- 5'00"/km 이내
              when v_pace <= 360  then 0.20   -- 6'00"/km 이내
              when v_pace <= 420  then 0.10   -- 7'00"/km 이내
              else 0.00
            end;
  v_pace_pts := floor(v_distance_pts * v_mult);

  -- ⑤ 고도 보너스: 상승 10m 당 1점, 최대 100pt.
  --    greatest(...,0) 은 규칙서에 없는 방어 코드다 — elevation_gain 이 음수로
  --    들어오면 floor() 가 음수 점수를 만들어 총점을 깎기 때문.
  v_elev_pts := least(floor(greatest(coalesce(p_elevation_gain_meters, 0)::numeric, 0) / 10.0), 100);

  -- ⑥ 합산 + 세션 상한 1000
  return least(v_base + v_distance_pts + v_pace_pts + v_elev_pts, 1000)::integer;
end;
$$;

comment on function public.compute_awarded_points(
  public.run_status, boolean, double precision, integer, double precision) is
  '러닝 1건 포인트 산정(정본). badge_rules §3.1. 완주20 + 거리(100m/1pt) + 페이스 보너스(최대 x1.3) + 고도(10m/1pt, 최대100), 세션 상한 1000.';

-- 기존 3인자 시그니처 유지용 래퍼 (구 호출부 호환).
-- 페이스/고도 정보가 없으므로 보너스 없이 계산된다 — 신규 코드는 5인자를 쓸 것.
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
  select public.compute_awarded_points(p_status, p_is_flagged, p_distance_meters, null::integer, null::double precision);
$$;

-- -----------------------------------------------------------------------------
-- 3-2. 레벨 산식 — 규칙서 §4.1 확정 공식 (체증형, 상한 100)
-- -----------------------------------------------------------------------------
-- level = min( 1 + floor( (P/500) ^ (1/1.6) ), 100 )
-- 1/1.6 = 0.625 (이진수로도 정확히 표현되는 값) 이지만, 규칙서 §4.3 지적대로
-- 경계값 안정성을 위해 **numeric** 으로 계산한다. double precision 으로 하면
-- power(1516/500.0, 0.625) 가 1.9999999... 로 떨어져 레벨이 하나 낮게 나올 수 있다.
create or replace function public.compute_level(p_total_points integer)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select least(
           1 + floor(power(greatest(coalesce(p_total_points, 0), 0)::numeric / 500.0, 0.625)),
           100
         )::integer;
$$;

comment on function public.compute_level(integer) is
  '레벨 산정(정본). badge_rules §4.1: 1 + floor((P/500)^(1/1.6)), 상한 100. '
  '역함수 ceil(500*(L-1)^1.6) 를 서버에서 독립적으로 쓰지 말 것 — §4.3 의 부동소수 증폭 버그. '
  '역함수가 필요하면 이 함수 기준으로 ±1 보정 루프를 돌려야 한다(클라이언트 level_curve.dart 와 동일 방식).';

-- -----------------------------------------------------------------------------
-- 3-3. runs 가드 트리거 — 5인자 포인트 함수 호출로 갱신
-- -----------------------------------------------------------------------------
-- 05_server_guards.sql 의 trg_runs_guard 본문 중 compute_awarded_points 호출부만
-- 달라진다. 나머지 로직(파생값 정규화, validate_run)은 그대로 유지한다.
create or replace function public.trg_runs_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_reason text;
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
  else
    new.id         := old.id;          -- PK 변조 차단
    new.user_id    := old.user_id;     -- 소유권 이전 차단
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();

  if new.distance_meters > 0 and new.moving_seconds > 0 then
    new.avg_pace_sec_per_km := new.moving_seconds / (new.distance_meters / 1000.0);
  else
    new.avg_pace_sec_per_km := null;
  end if;

  v_reason := public.validate_run(
    new.distance_meters, new.elapsed_seconds, new.moving_seconds,
    new.max_speed_mps, new.elevation_gain_meters
  );
  new.is_flagged  := (v_reason is not null);
  new.flag_reason := v_reason;

  -- 포인트는 클라이언트 입력을 무시하고 항상 서버가 산정한다 (badge_rules §3.1).
  new.awarded_points := public.compute_awarded_points(
    new.status, new.is_flagged, new.distance_meters,
    new.moving_seconds, new.elevation_gain_meters
  );

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3-4. 프로필 통계 캐시 재계산 — **정합성 수정 2건**
-- -----------------------------------------------------------------------------
-- ⚠️ (a) total_points 의 정의를 바꾼다.
--     기존: sum(runs.awarded_points) 만.
--     문제: evaluate_badges / recompute_challenge_progress 가 뱃지·챌린지 보상
--           포인트를 total_points 에 **가산**하는데, 다음 러닝 업로드 때
--           이 함수가 total_points 를 러닝 포인트만으로 덮어써서 그 가산분이
--           통째로 사라진다(레벨이 내려가는 버그). 규칙서 §2.2/§6.4 가 성립하려면
--           캐시 재계산도 세 원천을 모두 합해야 한다.
--     확정: total_points = sum(runs.awarded_points)
--                        + sum(획득 뱃지.points)
--                        + sum(완주 챌린지.reward_points)
--     트리거 순서(01 stats -> 02 challenge -> 03 badges)상 이 함수가 먼저 돌고
--     이후 단계가 "새로" 획득한 분만 증분 가산하므로 이중 계상되지 않는다.
--
-- ⚠️ (b) 스트릭 일자 귀속을 ended_at -> **started_at** 으로 바꾼다 (규칙서 §2.3).
--     23:50 출발해 자정을 넘긴 러닝은 출발일에 귀속되어야 사용자가 체감하는
--     "오늘 뛰었다"와 일치한다. last_run_at 은 그대로 ended_at 우선을 유지한다
--     (그쪽은 "마지막으로 러닝을 끝낸 시각"이 자연스러운 의미이기 때문).
create or replace function public.recompute_profile_stats(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dist       double precision := 0;
  v_moving     integer := 0;
  v_count      integer := 0;
  v_run_pts    integer := 0;
  v_badge_pts  integer := 0;
  v_chal_pts   integer := 0;
  v_points     integer := 0;
  v_last       timestamptz;
  v_current    integer := 0;
  v_longest    integer := 0;
  v_today      date := (now() at time zone 'Asia/Seoul')::date;
begin
  select
    coalesce(sum(r.distance_meters), 0),
    coalesce(sum(r.moving_seconds), 0),
    count(*),
    coalesce(sum(r.awarded_points), 0),
    max(coalesce(r.ended_at, r.started_at))
  into v_dist, v_moving, v_count, v_run_pts, v_last
  from public.runs r
  where r.user_id = p_user_id
    and r.status = 'completed'
    and r.is_flagged = false;

  -- 뱃지 포인트 (이미 획득한 것 전량)
  select coalesce(sum(b.points), 0)
  into v_badge_pts
  from public.user_badges ub
  join public.badges b on b.id = ub.badge_id
  where ub.user_id = p_user_id;

  -- 완주 챌린지 보상 포인트
  select coalesce(sum(c.reward_points), 0)
  into v_chal_pts
  from public.challenge_participations cp
  join public.challenges c on c.id = cp.challenge_id
  where cp.user_id = p_user_id
    and cp.completed_at is not null;

  v_points := v_run_pts + v_badge_pts + v_chal_pts;

  -- 스트릭: KST 기준 started_at 날짜 집합의 연속 구간(gaps-and-islands)
  with days as (
    select distinct (r.started_at at time zone 'Asia/Seoul')::date as d
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
    -- 오늘 또는 어제까지 이어진 구간만 "현재 진행 중"으로 본다 (규칙서 §2.3).
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
revoke execute on function public.compute_awarded_points(
  public.run_status, boolean, double precision, integer, double precision)
  from public, anon;
