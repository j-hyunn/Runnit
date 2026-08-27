-- =============================================================================
-- Runnit :: 39. XP/레벨 시스템 + 주 단위 스트릭(1회 유예)
-- -----------------------------------------------------------------------------
-- 정본: _workspace/20260826_000340_gamification_badge-backlog-decisions.md §1 · §3
--       docs/TRD.md §3.8 · §10.2 · docs/PRD.md GM-04 / GM-05
--
-- ⚠️ 이름 충돌 정리 (§1.0) — `points` 는 XP 가 아니다.
--    PRD §5.6 이 "포인트"를 **Phase 4 의 상품 교환 화폐**(거리 비연동 적립)로 확정했다.
--    현행 total_points 는 정확히 그 반대(거리 비례)이고 용도도 레벨 산정 하나뿐이라
--    Phase 4 에서 반드시 충돌한다. 레벨의 재화를 **XP** 로 개명하고 `points` 라는
--    이름을 Phase 4 에 통째로 반납한다.
--      profiles.total_points        -> profiles.total_xp
--      runs.awarded_points          -> runs.awarded_xp
--      compute_awarded_points(...)  -> compute_run_xp(...)   (활동유형 인자 추가)
--      compute_level(p_total_points)-> compute_level(p_total_xp)  (정수 배열 조회로 교체)
--
-- ⚠️ 증분 가산 금지. total_xp 는 4원천을 **매번 재집계**한다. "이번에 +50 해줬다" 식
--    가산은 기록 삭제/플래그 처리 후 정합이 깨진다(§1.1 원천 선정의 유일한 기준).
--    이 마이그레이션에서 challenges.reward_points 항이 total_xp 에서 빠지는 것도
--    같은 이유다 — XP 4원천에 챌린지는 없고, reward_points 는 Phase 4 포인트 이름이다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 39-1. 컬럼 개명 + 신설
-- -----------------------------------------------------------------------------
alter table public.profiles rename column total_points to total_xp;
alter table public.runs     rename column awarded_points to awarded_xp;

comment on column public.profiles.total_xp is
  '레벨 산정용 누적 XP. 4원천(러닝/주간스트릭/뱃지/티어) 재집계값 — 증분 가산 금지. '
  '⚠️ PRD §5.6 Phase 4 "포인트 이코노미"와 **다른 개념**이다. TRD §3.8';
comment on column public.runs.awarded_xp is
  '이 러닝 1건이 기여하는 XP. compute_run_xp() 가 서버에서 산정하며 클라이언트 입력은 무시한다.';

-- 주 단위 스트릭(§3.4). 기존 *_streak_days 는 삭제하지 않고 통계 표시용으로 남긴다 —
-- 단 **뱃지 판정에는 절대 쓰지 않는다**(GM-05 가 주 단위로 확정).
alter table public.profiles
  add column current_streak_weeks    integer  not null default 0,
  add column longest_streak_weeks    integer  not null default 0,
  add column streak_freeze_credits   smallint not null default 1,
  add column streak_last_active_week text;

comment on column public.profiles.longest_streak_weeks is
  '역대 최장 주간 스트릭. **streak_weeks_gte 뱃지 판정의 유일한 소스**(current_* 아님) — '
  '뱃지는 영구 자산이므로 한 번 달성하면 유지된다. 리플레이 결과 캐시.';
comment on column public.profiles.streak_freeze_credits is
  '유예(freeze) 크레딧 잔량(상한 1). **저장 상태가 아니라 리플레이 파생값 캐시**다 — '
  '기록이 삭제돼도 가입 주부터 다시 계산해 같은 답이 나온다.';
comment on column public.profiles.streak_last_active_week is
  'KST ISO 주 키(YYYY-Www). 마지막 활동 주 — "스트릭 위험" 알림 판단용.';

-- -----------------------------------------------------------------------------
-- 39-2. 레벨 임계값 — 정본은 60개 정수 배열 (역함수 계산 금지)
-- -----------------------------------------------------------------------------
-- 유도식은 XP_required(L) = ceil(50 × (L−1)^2.2), 만렙 60. 다만 지수 역함수의
-- 부동소수 오차가 "레벨업까지 1pt 남음"을 고착시키는 버그를 실제로 일으킨 전례가
-- 있으므로(_workspace/20260819_210450_badge_rules.md §4.3), 양쪽(Postgres/Dart)에
-- 정수 배열을 그대로 심고 **역함수를 계산하지 않는다**.
create or replace function public.xp_level_thresholds()
returns integer[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array[
        0,     50,    230,    561,   1056,   1725,   2576,   3616,   4851,   6285,
     7925,   9774,  11836,  14114,  16614,  19337,  22287,  25466,  28879,  32526,
    36412,  40538,  44906,  49519,  54380,  59490,  64851,  70465,  76334,  82461,
    88846,  95492, 102401, 109573, 117011, 124716, 132690, 140934, 149450, 158239,
   167303, 176643, 186260, 196156, 206332, 216790, 227530, 238554, 249863, 261458,
   273341, 285513, 297974, 310726, 323770, 337108, 350739, 364666, 378889, 393410
  ]::integer[];
$$;

comment on function public.xp_level_thresholds() is
  '레벨 1..60 진입에 필요한 누적 XP(정본, TRD §3.8.3). 배열 인덱스 = 레벨. '
  'Dart LevelCurve.thresholds 와 **글자 그대로 같은 60개 정수**여야 한다.';

-- 파라미터 이름이 바뀌므로 CREATE OR REPLACE 가 아니라 drop 후 재생성한다.
drop function if exists public.compute_level(integer);

create function public.compute_level(p_total_xp integer)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(
    (
      select max(i)
        from generate_subscripts(public.xp_level_thresholds(), 1) as i
       where (public.xp_level_thresholds())[i] <= greatest(coalesce(p_total_xp, 0), 0)
    ),
    1
  )::integer;
$$;

comment on function public.compute_level(integer) is
  'level(xp) = max{L : XP_LEVEL_THRESHOLDS[L] <= xp}, 상한 60. **정수 비교만** 하므로 '
  '부동소수 경계 버그가 원천적으로 없다. 역함수가 필요하면 xp_level_thresholds()[L] 을 '
  '그대로 읽을 것 — power()/ceil() 로 재유도하지 말 것(§4.3 부동소수 증폭 버그).';

revoke execute on function public.compute_level(integer) from public, anon;

-- -----------------------------------------------------------------------------
-- 39-3. XP-1 러닝 세션 XP (§1.1)
-- -----------------------------------------------------------------------------
-- 실외 산식은 현행 compute_awarded_points 그대로다(검증된 값이므로 바꾸지 않는다).
-- 달라진 것은 **실내·수동 분기 하나**뿐 — PRD §8.3 이 실내·수동을 누적 통계에
-- 반영하도록 확정했으므로 XP 에서 통째로 배제하면 정책이 어긋나지만, 검증 불가능한
-- 입력에 보너스 배수를 곱하는 것은 어뷰징 유인이다. 레벨은 경쟁 지표가 아니므로
-- (랭킹·티어와 무관) 낮은 상한으로 분리하는 완화로 충분하다.
create or replace function public.compute_run_xp(
  p_status                public.run_status,
  p_is_flagged            boolean,
  p_distance_meters       double precision,
  p_moving_seconds        integer,
  p_elevation_gain_meters double precision,
  p_activity_type         public.activity_type
)
returns integer
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_distance_pts numeric;
  v_pace         numeric;
  v_mult         numeric;
  v_pace_pts     numeric;
  v_elev_pts     numeric;
  v_base         constant numeric := 20;   -- 완주 보너스(고정)
begin
  if p_status <> 'completed' or coalesce(p_is_flagged, false) then
    return 0;
  end if;
  if p_distance_meters is null or p_distance_meters < 500 then
    return 0;
  end if;

  v_distance_pts := floor(p_distance_meters::numeric / 100.0);

  -- 실내·수동: 페이스·고도 보너스 없음, 세션 상한 300
  if p_activity_type = 'indoor_run' then
    return least(v_base + v_distance_pts, 300)::integer;
  end if;

  -- 페이스 보너스: 2km 이상에만. 거리 점수에 곱한다(짧고 빠른 어뷰징 차단).
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

  -- greatest(...,0) 은 방어 코드 — elevation_gain 이 음수면 floor() 가 XP 를 깎는다.
  v_elev_pts := least(floor(greatest(coalesce(p_elevation_gain_meters, 0)::numeric, 0) / 10.0), 100);

  return least(v_base + v_distance_pts + v_pace_pts + v_elev_pts, 1000)::integer;
end;
$$;

comment on function public.compute_run_xp(
  public.run_status, boolean, double precision, integer, double precision, public.activity_type) is
  '러닝 1건 XP(정본, TRD §3.8.2 XP_run). 실외: 완주20 + 거리(100m/1) + 페이스 보너스(최대 ×1.3) '
  '+ 고도(10m/1, 최대100), 세션 상한 1000. 실내·수동(indoor_run): 완주20 + 거리, 상한 300.';

revoke execute on function public.compute_run_xp(
  public.run_status, boolean, double precision, integer, double precision, public.activity_type)
  from public, anon;

-- -----------------------------------------------------------------------------
-- 39-4. 주 단위 스트릭 리플레이 (§3.3) — 순수 함수
-- -----------------------------------------------------------------------------
-- **크레딧은 저장 상태가 아니라 리플레이 파생값이다.** 매 계산마다 가입 주부터 다시
-- 돌린다 — 그래야 러닝이 삭제/플래그 처리돼도 같은 답이 나온다(정본 문서 원칙 1).
create or replace function public._weekly_streak_state(p_user_id uuid)
returns table(
  current_streak_weeks integer,
  longest_streak_weeks integer,
  freeze_credits       smallint,
  streak_xp            integer,
  last_active_week     text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_weeks   date[];
  v_first   date;
  v_now_wk  date;
  v_w       date;
  v_active  boolean;
  v_credits smallint := 1;
  v_used    boolean  := false;
  v_since   integer  := 0;
  v_cur     integer  := 0;
  v_long    integer  := 0;
  v_xp      integer  := 0;
  v_last    date;
begin
  -- 활동 주(§3.1) = 그 주에 완주·비플래그 러닝 1건 이상 **그리고** 주 합산 거리 >= 1.0km.
  -- 실내·수동을 **포함한다** — 스트릭은 이탈 방지 장치이지 경쟁 지표가 아니다.
  -- PRD §8.3 이 실내·수동을 배제한 대상은 티어·랭킹이지 누적 자산이 아니다.
  -- 하한 1.0km 가 없으면 50m 기록으로 104주 스트릭을 유지할 수 있다. 주 **합산**
  -- 기준이라 400m × 3회도 통과한다.
  select array_agg(wk order by wk)
    into v_weeks
    from (
      select date_trunc('week', r.started_at at time zone 'Asia/Seoul')::date as wk
        from public.runs r
       where r.user_id = p_user_id
         and r.status = 'completed'
         and r.is_flagged = false
       group by 1
      having sum(r.distance_meters) >= 1000.0
    ) w;

  if v_weeks is null or coalesce(array_length(v_weeks, 1), 0) = 0 then
    return query select 0, 0, 1::smallint, 0, null::text;
    return;
  end if;

  v_now_wk := date_trunc('week', (now() at time zone 'Asia/Seoul'))::date;

  -- 리플레이 시작 주 = 가입 주(§3.3).
  -- ⚠️ 구현 노트: 시드/임포트 데이터는 러닝이 가입보다 앞설 수 있어 least() 로 감싼다.
  --    프로덕션 불변식(가입 <= 첫 러닝) 아래에서는 결과가 정본 알고리즘과 **동일**하고,
  --    그 밖에서는 이미 존재하는 러닝을 리플레이에서 잃지 않는다.
  select least(
           date_trunc('week', (p.created_at at time zone 'Asia/Seoul'))::date,
           v_weeks[1]
         )
    into v_first
    from public.profiles p
   where p.id = p_user_id;

  v_first := coalesce(v_first, v_weeks[1]);

  v_w := v_first;
  while v_w <= v_now_wk loop
    v_active := v_w = any (v_weeks);

    if v_active then
      v_cur  := v_cur + 1;
      v_long := greatest(v_long, v_cur);
      -- XP-2: 스트릭 내 n번째 주마다 30 × min(n,5). 거리에 비례하지 않는다 —
      -- 거리 보상은 XP-1 이 담당하고 이 항목은 "매주 나온다"만 보상한다.
      v_xp   := v_xp + 30 * least(v_cur, 5);
      v_last := v_w;
      if v_used then
        v_since := v_since + 1;
        if v_since >= 4 then          -- 유예 회복: 사용 후 연속 4주 활동
          v_credits := 1;
          v_used    := false;
          v_since   := 0;
        end if;
      end if;
    else
      -- 진행 중인 주는 비활동으로 판정하지 않는다(유예도 소모하지 않는다).
      exit when v_w = v_now_wk;

      if v_credits >= 1 then
        v_credits := v_credits - 1;   -- 유예 자동 소모. current 는 증가시키지 않고,
        v_used    := true;            -- 그 주의 XP 도 0 이다 — 연결만 유지된다.
        v_since   := 0;
      else
        v_cur     := 0;               -- 스트릭 종료
        v_credits := 1;               -- 새 스트릭용 안전망 리셋
        v_used    := false;
        v_since   := 0;
      end if;
    end if;

    v_w := v_w + 7;
  end loop;

  return query select v_cur, v_long, v_credits, v_xp, to_char(v_last, 'IYYY-"W"IW');
end;
$$;

comment on function public._weekly_streak_state(uuid) is
  '주 단위 스트릭 리플레이(정본, TRD §10.2 / GM-05). KST 월~일, 활동 주 = 완주 1건 + 주 합산 >=1.0km '
  '(실내·수동 포함). 유예 크레딧 1개 자동 소모 → 연속 4주 활동 시 회복 → 스트릭 종료 시 리셋. '
  '유예 주는 스트릭 카운트·XP 모두 0. 저장 상태 없이 매번 가입 주부터 재생한다.';

revoke execute on function public._weekly_streak_state(uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 39-5. recompute_profile_stats — XP 4원천 재집계로 확장
-- -----------------------------------------------------------------------------
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
  v_xp_run     integer := 0;
  v_xp_streak  integer := 0;
  v_xp_badge   integer := 0;
  v_xp_tier    integer := 0;
  v_total_xp   integer := 0;
  v_last       timestamptz;
  v_current    integer := 0;
  v_longest    integer := 0;
  v_today      date := (now() at time zone 'Asia/Seoul')::date;
  v_cur_w      integer  := 0;
  v_long_w     integer  := 0;
  v_credits    smallint := 1;
  v_last_w     text;
begin
  -- ── XP-1 러닝 세션 XP + 기본 통계 ────────────────────────────────────────
  select
    coalesce(sum(r.distance_meters), 0),
    coalesce(sum(r.moving_seconds), 0),
    count(*),
    coalesce(sum(r.awarded_xp), 0),
    max(coalesce(r.ended_at, r.started_at))
  into v_dist, v_moving, v_count, v_xp_run, v_last
  from public.runs r
  where r.user_id = p_user_id
    and r.status = 'completed'
    and r.is_flagged = false;

  -- ── XP-2 주간 스트릭 XP + 스트릭 캐시 컬럼 ───────────────────────────────
  select s.current_streak_weeks, s.longest_streak_weeks,
         s.freeze_credits, s.streak_xp, s.last_active_week
    into v_cur_w, v_long_w, v_credits, v_xp_streak, v_last_w
    from public._weekly_streak_state(p_user_id) s;

  -- ── XP-3 뱃지 획득 XP ────────────────────────────────────────────────────
  -- ⚠️ category='level' 뱃지 9종은 **0**. XP → 레벨 → 레벨 뱃지 → XP 순환을
  --    정의로 끊는다(§1.1 XP-3). 이 예외가 재진입 수렴의 근거이기도 하다.
  select coalesce(sum(
           case b.badge_grade
             when 'bronze'   then 100
             when 'silver'   then 250
             when 'gold'     then 600
             when 'platinum' then 1500
             when 'diamond'  then 4000
             when 'special'  then 200
             else 0
           end), 0)
    into v_xp_badge
    from public.user_badges ub
    join public.badges b on b.id = ub.badge_id
   where ub.user_id = p_user_id
     and ub.verified = true
     and ub.revoked  = false
     and b.category <> 'level';

  -- ── XP-4 티어 달성 XP ────────────────────────────────────────────────────
  -- tier_change_history 의 distinct (season_id, tier) 마다 1회. 시즌마다 재지급된다
  -- (티어는 시즌마다 리셋되므로 매 시즌 다시 올라간 노력에 대한 보상이 맞다).
  select coalesce(sum(
           case t.tier
             when 'silver'   then 300
             when 'gold'     then 800
             when 'platinum' then 2000
             else 0                     -- bronze = 시즌 시작 기본값
           end), 0)
    into v_xp_tier
    from (
      select distinct tch.season_id, tch.tier
        from public.tier_change_history tch
       where tch.user_id = p_user_id
    ) t;

  v_total_xp := v_xp_run + v_xp_streak + v_xp_badge + v_xp_tier;

  -- ── 일 단위 스트릭 (통계 표시 전용 — 뱃지 판정에는 쓰지 않는다) ──────────
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
    coalesce(max(len) filter (where last_day >= v_today - 1), 0)
  into v_longest, v_current
  from islands;

  perform set_config('runnit.server_write', 'on', true);

  update public.profiles p
  set total_distance_meters   = v_dist,
      total_moving_seconds    = v_moving,
      total_run_count         = v_count,
      total_xp                = v_total_xp,
      level                   = public.compute_level(v_total_xp),
      current_streak_days     = v_current,
      longest_streak_days     = v_longest,
      current_streak_weeks    = v_cur_w,
      longest_streak_weeks    = v_long_w,
      streak_freeze_credits   = v_credits,
      streak_last_active_week = v_last_w,
      last_run_at             = v_last,
      updated_at              = now()
  where p.id = p_user_id;

  perform set_config('runnit.server_write', 'off', true);
end;
$$;

comment on function public.recompute_profile_stats(uuid) is
  '프로필 통계 + XP 4원천(러닝/주간스트릭/뱃지/티어) + 레벨 + 주간 스트릭 캐시 전체 재계산. '
  '멱등이며 증분 가산을 쓰지 않는다 — 기록 삭제/플래그 후에도 같은 답이 나온다. TRD §3.8.4';

revoke execute on function public.recompute_profile_stats(uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 39-6. trg_runs_guard — compute_run_xp 호출로 갱신
-- -----------------------------------------------------------------------------
-- 05/10 번 원본과 동일하되 XP 산정부만 교체한다(파생값 정규화·validate_run 그대로).
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

  -- XP 는 클라이언트 입력을 무시하고 항상 서버가 산정한다.
  new.awarded_xp := public.compute_run_xp(
    new.status, new.is_flagged, new.distance_meters,
    new.moving_seconds, new.elevation_gain_meters, new.activity_type
  );

  return new;
end;
$$;

-- 구 포인트 함수 제거 — 유일한 호출부(trg_runs_guard)를 위에서 갱신했다.
drop function if exists public.compute_awarded_points(public.run_status, boolean, double precision);
drop function if exists public.compute_awarded_points(public.run_status, boolean, double precision, integer, double precision);

-- -----------------------------------------------------------------------------
-- 39-7. trg_profiles_guard — 신설 서버 전용 컬럼 보호
-- -----------------------------------------------------------------------------
create or replace function public.trg_profiles_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := now();

    if not public.is_server_write() then
      new.total_distance_meters   := 0;
      new.total_moving_seconds    := 0;
      new.total_run_count         := 0;
      new.total_xp                := 0;
      new.level                   := 1;
      new.current_streak_days     := 0;
      new.longest_streak_days     := 0;
      new.current_streak_weeks    := 0;
      new.longest_streak_weeks    := 0;
      new.streak_freeze_credits   := 1;
      new.streak_last_active_week := null;
      new.last_run_at             := null;
      new.current_tier            := 'bronze';
      new.season_distance_meters  := 0;
      new.tier_season_id          := null;
    end if;
    return new;
  end if;

  new.id         := old.id;
  new.created_at := old.created_at;
  new.updated_at := now();

  if not public.is_server_write() then
    new.total_distance_meters   := old.total_distance_meters;
    new.total_moving_seconds    := old.total_moving_seconds;
    new.total_run_count         := old.total_run_count;
    new.total_xp                := old.total_xp;
    new.level                   := old.level;
    new.current_streak_days     := old.current_streak_days;
    new.longest_streak_days     := old.longest_streak_days;
    new.current_streak_weeks    := old.current_streak_weeks;
    new.longest_streak_weeks    := old.longest_streak_weeks;
    new.streak_freeze_credits   := old.streak_freeze_credits;
    new.streak_last_active_week := old.streak_last_active_week;
    new.last_run_at             := old.last_run_at;
    new.crew_id                 := old.crew_id;
    new.current_tier            := old.current_tier;
    new.season_distance_meters  := old.season_distance_meters;
    new.tier_season_id          := old.tier_season_id;
  end if;

  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- 39-8. XP-3 / XP-4 갱신 트리거 (§1.4 호출 지점 3곳 중 신규 2곳)
-- -----------------------------------------------------------------------------
-- 기존 runs_01_recompute_stats 가 XP-1·XP-2 를 커버하고, 아래 둘이 XP-3·XP-4 를 맡는다.
--
-- ⚠️ evaluate_badges 내부에서는 이 트리거를 건너뛴다. 한 번의 평가에서 뱃지가 N개
--    지급되면 전체 재집계가 N번 도는데, evaluate_badges 가 **패스 끝에 한 번**
--    재계산하므로 결과는 같고 비용만 1/N 이 된다.
create or replace function public.trg_recompute_xp_source()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(current_setting('runnit.badge_eval', true), 'off') = 'on' then
    return null;
  end if;
  -- 무한 루프 방어(§1.4). 정상 경로의 최대 깊이는 3 이다.
  if pg_trigger_depth() > 8 then
    raise notice 'trg_recompute_xp_source: pg_trigger_depth()=% — 재진입 방어로 중단', pg_trigger_depth();
    return null;
  end if;

  if tg_op = 'DELETE' then
    perform public.recompute_profile_stats(old.user_id);
  else
    perform public.recompute_profile_stats(new.user_id);
    if tg_op = 'UPDATE' and old.user_id is distinct from new.user_id then
      perform public.recompute_profile_stats(old.user_id);
    end if;
  end if;
  return null;
end;
$$;

comment on function public.trg_recompute_xp_source() is
  'XP-3(뱃지)·XP-4(티어 도달) 원천 테이블 변경 시 프로필 XP/레벨 재계산. '
  'evaluate_badges 내부(runnit.badge_eval=on)에서는 스킵 — 그쪽이 패스 끝에 한 번만 돈다.';

-- 트리거 함수는 RPC 로 직접 호출될 수 없어야 한다(마이그레이션 14/15 관례).
revoke execute on function public.trg_recompute_xp_source() from public, anon, authenticated;

drop trigger if exists user_badges_02_recompute_xp on public.user_badges;
create trigger user_badges_02_recompute_xp
  after insert or delete or update of verified, revoked on public.user_badges
  for each row execute function public.trg_recompute_xp_source();

drop trigger if exists tier_change_history_01_recompute_xp on public.tier_change_history;
create trigger tier_change_history_01_recompute_xp
  after insert on public.tier_change_history
  for each row execute function public.trg_recompute_xp_source();

-- -----------------------------------------------------------------------------
-- 39-9. evaluate_badges — 수렴 루프 (최대 3패스)
-- -----------------------------------------------------------------------------
-- 재진입 종료 보장(§1.4): 뱃지 획득 → XP 증가 → 레벨업 → 레벨 뱃지 지급 →
-- (레벨 뱃지는 XP 0) → total_xp 불변 → 레벨 불변 → 새 뱃지 없음 → 종료.
-- 한 트랜잭션 안에서 수렴하므로 사용자는 레벨 뱃지를 다음 러닝까지 기다리지 않는다.
create or replace function public.evaluate_badges(p_user_id uuid, p_source_run_id uuid default null)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_badge     record;
  v_awarded   integer := 0;
  v_pass_cnt  integer;
  v_pass      integer;
begin
  if p_user_id is null then
    return 0;
  end if;

  perform set_config('runnit.server_write', 'on', true);
  perform set_config('runnit.badge_eval',   'on', true);

  for v_pass in 1..3 loop
    v_pass_cnt := 0;

    -- scope='permanent' 이거나, scope='seasonal' 이면서 season_id 가 채워진(발급된)
    -- 인스턴스만 대상. 템플릿(season_id is null)은 자동 제외된다.
    for v_badge in
      select b.id, b.condition_type, b.condition
      from public.badges b
      where (b.scope = 'permanent' or (b.scope = 'seasonal' and b.season_id is not null))
        and not exists (
          select 1 from public.user_badges ub
          where ub.user_id = p_user_id and ub.badge_id = b.id
        )
    loop
      if public.evaluate_badge_condition(p_user_id, v_badge.condition_type, v_badge.condition) then
        insert into public.user_badges (user_id, badge_id, earned_at, source_run_id, is_seen, verified, revoked)
        values (p_user_id, v_badge.id, now(), p_source_run_id, false, true, false)
        on conflict (user_id, badge_id) do nothing;

        if found then
          v_pass_cnt := v_pass_cnt + 1;
        end if;
      end if;
    end loop;

    v_awarded := v_awarded + v_pass_cnt;
    exit when v_pass_cnt = 0;

    -- 이번 패스에서 지급된 뱃지의 XP-3 를 반영한다(트리거는 badge_eval=on 으로 스킵됨).
    -- 레벨이 오르면 다음 패스에서 level_gte 뱃지가 잡힌다.
    perform public.recompute_profile_stats(p_user_id);
  end loop;

  perform set_config('runnit.badge_eval',   'off', true);
  perform set_config('runnit.server_write', 'off', true);

  return v_awarded;
end;
$function$;

comment on function public.evaluate_badges(uuid, uuid) is
  '미획득 뱃지 전체 재평가 + 지급(INSERT 전용 — PRD §8.1 에 따라 회수 경로를 만들지 말 것). '
  '최대 3패스 수렴 루프: 뱃지 XP → 레벨업 → 레벨 뱃지까지 한 트랜잭션에서 지급된다.';

revoke execute on function public.evaluate_badges(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 39-10. 백필 — runs.awarded_xp 재산정 후 전 프로필 재계산
-- -----------------------------------------------------------------------------
-- 실외 산식은 그대로이므로 대부분 값이 같고, indoor_run 세션만 새 상한(300)으로 내려간다.
-- BEFORE 가드가 어차피 awarded_xp 를 재산정하므로 no-op UPDATE 로 충분하다.
--
-- AFTER 트리거 3종을 잠시 끈다 — 켜둔 채로 돌리면 러닝 1건마다 프로필 전체 재집계 +
-- 뱃지 146행 재평가가 돌아 O(runs × badges) 가 된다. 아래에서 프로필 단위로 한 번씩
-- 재계산하므로 결과는 동일하고, 뱃지 재평가는 판정 로직이 완성되는 41번 뒤에 돈다.
alter table public.runs disable trigger runs_01_recompute_stats;
alter table public.runs disable trigger runs_02_challenge_progress;
alter table public.runs disable trigger runs_03_evaluate_badges;

update public.runs set updated_at = updated_at;

alter table public.runs enable trigger runs_01_recompute_stats;
alter table public.runs enable trigger runs_02_challenge_progress;
alter table public.runs enable trigger runs_03_evaluate_badges;

do $$
declare
  v_id uuid;
begin
  for v_id in select p.id from public.profiles p loop
    perform public.recompute_profile_stats(v_id);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- 39-11. 레벨 상한 CHECK — 100 → 60
-- -----------------------------------------------------------------------------
-- 현행 상한 100 은 구 포인트 곡선의 잔재다. 카탈로그의 lvl_60 표시명이 이미 "만렙"
-- (diamond)이고, 60 위에 아무 보상도 없는 40레벨을 남기면 숫자만 인플레이션된다.
-- 백필 뒤에 붙여야 기존 행이 제약을 위반하지 않는다.
alter table public.profiles drop constraint if exists profiles_level_positive;
alter table public.profiles drop constraint if exists profiles_level_range;
alter table public.profiles add constraint profiles_level_range check (level between 1 and 60);
