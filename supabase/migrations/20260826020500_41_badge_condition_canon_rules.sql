-- =============================================================================
-- Runnit :: 41. 뱃지 판정 정본 규칙 반영 (스텁 5종 해제 + §5 임계값 정본화)
-- -----------------------------------------------------------------------------
-- 정본: _workspace/20260826_000340_gamification_badge-backlog-decisions.md §1·§3·§5·§6
--       _workspace/20260826_012000_architect_device-vendor-arbitration.md §2.2
--       docs/TRD.md §3.1.2 · §3.8 · §10.2
--
-- 이 마이그레이션이 해제하는 스텁 (27/32/33 번에 raise notice 로 남아 있던 것)
--   · level_gte                      -> profiles.level (39번 XP 시스템)
--   · device_source_count_gte        -> runs.device_vendors 배열 겹침 (36번)
--   · device_source_diversity_gte    -> 위 + 원소 간 AND
--   · calendar_date_match 음력 2건   -> public.lunar_holidays 룩업 (38번)
--   · district_diversity_gte         -> 분기 자체를 삭제 (37번에서 뱃지 2종 제거)
--
-- 값이 바뀌는 항목(TRD §10.2 의 ⚠️ 표시)
--   PB 허용오차 / PB 시간 보간 / 루프 150m·2km·샘플10 / 클러스터 300m /
--   스플릿 선형 보간 / 페이스 3종 최소 거리·스플릿 수 / 스트릭 유예
--
-- ⚠️ 임계값이 조여져도 **이미 지급된 뱃지는 회수하지 않는다**(PRD §8.1).
--    evaluate_badges 가 INSERT 전용이라 자동으로 지켜진다 — DELETE/revoke 경로를
--    추가하지 말 것.
-- =============================================================================

-- =========================================================================
-- 41-0. 헬퍼 함수
-- =========================================================================

-- -----------------------------------------------------------------------------
-- 41-0-a. 누적거리 D 지점의 통과 시각 — **선형 보간** (§5.4)
-- -----------------------------------------------------------------------------
-- t(D) = t[i-1] + (t[i] − t[i-1]) × (D − d[i-1]) / (d[i] − d[i-1])
-- 폰 GPS(1~5초 간격)에서는 보간 없이도 오차가 작지만, **워치 동기화 기록은 샘플
-- 간격이 60초 이상**일 수 있어 무보간 근사가 km 스플릿을 최대 1분까지 틀어놓는다.
create or replace function public._run_time_at_distance(p_samples jsonb, p_meters double precision)
returns timestamptz
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with pts as (
    select (elem ->> 'cumulative_distance_meters')::double precision as d,
           (elem ->> 'timestamp')::timestamptz                       as t
    from jsonb_array_elements(coalesce(p_samples, '[]'::jsonb)) as elem
    where elem ->> 'cumulative_distance_meters' is not null
      and elem ->> 'timestamp' is not null
  ),
  o as (
    select d, t,
           lag(d) over (order by d, t) as pd,
           lag(t) over (order by d, t) as pt
    from pts
  ),
  hit as (
    select * from o where d >= p_meters order by d, t limit 1
  )
  select case
           when p_meters is null                then null
           when p_meters <= 0                   then (select min(t) from pts)
           when not exists (select 1 from hit)  then null
           when (select pd from hit) is null    then (select t from hit)
           when (select d - pd from hit) <= 0   then (select t from hit)
           else (select pt + (t - pt) * ((p_meters - pd) / (d - pd)) from hit)
         end;
$$;

comment on function public._run_time_at_distance(jsonb, double precision) is
  '샘플 배열에서 누적거리 p_meters 지점의 통과 시각(선형 보간). 샘플이 그 거리에 못 미치면 null. '
  'km 스플릿과 PB 시간 산정이 공통으로 쓴다. TRD §10.2';

-- -----------------------------------------------------------------------------
-- 41-0-b. km 스플릿 — 보간 기반으로 교체
-- -----------------------------------------------------------------------------
create or replace function public._run_km_split_seconds(p_samples jsonb)
returns table(km_index integer, split_seconds double precision)
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with maxd as (
    select coalesce(max((elem ->> 'cumulative_distance_meters')::double precision), 0) as m
    from jsonb_array_elements(coalesce(p_samples, '[]'::jsonb)) as elem
    where elem ->> 'cumulative_distance_meters' is not null
      and elem ->> 'timestamp' is not null
  ),
  bounds as (
    select generate_series(1, floor((select m from maxd) / 1000.0)::integer) as km_index
  ),
  t as (
    select b.km_index,
           public._run_time_at_distance(p_samples, (b.km_index - 1) * 1000.0) as t_start,
           public._run_time_at_distance(p_samples, b.km_index * 1000.0)       as t_end
    from bounds b
  )
  select km_index, extract(epoch from (t_end - t_start))::double precision
  from t
  where t_start is not null and t_end is not null and t_end > t_start;
$$;

comment on function public._run_km_split_seconds(jsonb) is
  '**완주된 정수 km** 구간별 소요시간. 경계 통과 시각은 선형 보간(_run_time_at_distance). '
  '마지막 자투리 구간은 애초에 방출하지 않는다 — pace_variance_lte 가 요구하는 조건과 일치.';

-- -----------------------------------------------------------------------------
-- 41-0-c. 네거티브 스플릿 — 총 거리의 정확히 절반 지점 기준, 세션 >= 4km
-- -----------------------------------------------------------------------------
-- 이전 구현은 "km 스플릿 개수의 절반"으로 나눴다. 정본은 **거리의 절반 지점**이며
-- 그 지점의 시각은 보간으로 구한다. 4km 하한은 짧은 러닝의 스플릿 차이가 노이즈이기 때문.
create or replace function public._run_negative_split(
  p_samples jsonb, p_distance_meters double precision)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with agg as (
    select coalesce(max((elem ->> 'cumulative_distance_meters')::double precision), 0) as m,
           min((elem ->> 'timestamp')::timestamptz) as t0,
           max((elem ->> 'timestamp')::timestamptz) as tn
    from jsonb_array_elements(coalesce(p_samples, '[]'::jsonb)) as elem
    where elem ->> 'cumulative_distance_meters' is not null
      and elem ->> 'timestamp' is not null
  ),
  h as (
    select a.m, a.t0, a.tn,
           public._run_time_at_distance(p_samples, a.m / 2.0) as th
    from agg a
  )
  select case
           when coalesce(p_distance_meters, 0) < 4000 then false
           when (select m from h) <= 0                then false
           when (select th from h) is null
             or (select t0 from h) is null
             or (select tn from h) is null            then false
           else ((select tn from h) - (select th from h))
              < ((select th from h) - (select t0 from h))
         end;
$$;

comment on function public._run_negative_split(jsonb, double precision) is
  '후반(절반 지점~끝)이 전반(시작~절반 지점)보다 빠르면 true. 분할 기준은 **거리의 절반**(보간). '
  '세션 거리 >= 4km 인 경우에만 판정한다. TRD §10.2';

-- -----------------------------------------------------------------------------
-- 41-0-d. 마지막 1km 가속 — 세션 >= 5km, 마지막 **완주된** 1km vs 그 앞 구간 평균
-- -----------------------------------------------------------------------------
create or replace function public._run_final_km_faster_pct(
  p_samples jsonb, p_pct double precision, p_distance_meters double precision)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with s as (select * from public._run_km_split_seconds(p_samples)),
       n as (select max(km_index) as last_km, count(*) as cnt from s)
  select case
           when p_pct is null                              then false
           when coalesce(p_distance_meters, 0) < 5000      then false
           when (select cnt from n) < 2                    then false
           else (
             (select s.split_seconds from s, n where s.km_index = n.last_km)
             <= (select avg(s.split_seconds) from s, n where s.km_index < n.last_km)
                * (1 - p_pct / 100.0)
           )
         end;
$$;

comment on function public._run_final_km_faster_pct(jsonb, double precision, double precision) is
  '마지막 완주 1km 스플릿이 그 앞 구간 평균 km 페이스보다 p_pct%% 이상 빠르면 true. '
  '자투리 구간은 _run_km_split_seconds 가 애초에 제외한다. 세션 거리 >= 5km 한정.';

-- -----------------------------------------------------------------------------
-- 41-0-e. 페이스 변동계수 — 스플릿 3개 이상일 때만 판정
-- -----------------------------------------------------------------------------
-- 2개짜리 CV 는 무의미하다. 3개 미만이면 null 을 돌려 비교가 항상 false 로 귀결된다.
create or replace function public._run_pace_variance_pct(p_samples jsonb)
returns double precision
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  select case when count(*) < 3 or avg(split_seconds) = 0 then null
              else (stddev_pop(split_seconds) / avg(split_seconds)) * 100.0
         end
  from public._run_km_split_seconds(p_samples);
$$;

comment on function public._run_pace_variance_pct(jsonb) is
  'km 스플릿 변동계수 CV(%%) = stddev/mean × 100. 완주된 정수 km 스플릿만 대상이며 '
  '스플릿 3개 미만이면 null(판정 불가 → 조건은 false).';

-- -----------------------------------------------------------------------------
-- 41-0-f. 경로 다양성 — 반경 300m 그리디 클러스터링 (결정적)
-- -----------------------------------------------------------------------------
-- 이전 구현의 "위경도 소수 3자리 반올림"은 그리드 스내핑이라 경계 문제가 있었다 —
-- 20m 떨어진 두 시작점이 셀 경계를 사이에 두면 서로 다른 경로로 잡힌다.
--
-- 결정성의 세 축(§5.3)
--   ① started_at 오름차순 처리 — 순서를 고정하지 않으면 같은 데이터에서 다른 개수가 나온다
--   ② anchor 갱신 안 함 — 이동 평균으로 갱신하면 결과가 처리 순서·부동소수에 민감해진다
--   ③ 반경 300m — 같은 집/직장 앞 출발(주차 위치 차이, GPS 초기 픽스 편차)을 하나로 묶고
--                 다른 동네·공원은 분리한다. 100m 는 초기 픽스 오차만으로 같은 장소가 쪼개진다
--
-- 구현 노트: 정본은 "가장 가까운 클러스터에 편입"이지만 여기서는 **첫 매칭에서 멈춘다**.
-- anchor 를 갱신하지 않으므로 어느 클러스터에 넣든 **클러스터 개수는 동일**하고,
-- 반환값이 개수뿐이라 결과가 정확히 같다. 최근접 탐색을 생략해 O(n·k) 상수만 줄였다.
create or replace function public._route_cluster_count(p_user_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  r       record;
  v_lat   double precision[] := array[]::double precision[];
  v_lng   double precision[] := array[]::double precision[];
  v_i     integer;
  v_found boolean;
begin
  for r in
    select (rr.samples -> 0 ->> 'latitude')::double precision  as lat,
           (rr.samples -> 0 ->> 'longitude')::double precision as lng
      from public.runs rr
     where rr.user_id = p_user_id
       and rr.status = 'completed'
       and rr.is_flagged = false
       and jsonb_array_length(rr.samples) > 0
       and rr.samples -> 0 ->> 'latitude'  is not null
       and rr.samples -> 0 ->> 'longitude' is not null
     order by rr.started_at asc, rr.id asc
  loop
    v_found := false;
    for v_i in 1..coalesce(array_length(v_lat, 1), 0) loop
      if public._haversine_meters(r.lat, r.lng, v_lat[v_i], v_lng[v_i]) <= 300 then
        v_found := true;
        exit;
      end if;
    end loop;

    if not v_found then
      v_lat := array_append(v_lat, r.lat);
      v_lng := array_append(v_lng, r.lng);
    end if;
  end loop;

  return coalesce(array_length(v_lat, 1), 0);
end;
$$;

comment on function public._route_cluster_count(uuid) is
  '시작점 반경 300m 그리디 클러스터링으로 센 "서로 다른 경로" 수. started_at 오름차순 처리 + '
  'anchor 미갱신으로 결정적. route_diversity_count_gte 판정용. TRD §10.2';

revoke execute on function public._route_cluster_count(uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 41-0-g. 기기 벤더 OR 표현식 파서 (§3.1.2)
-- -----------------------------------------------------------------------------
--   expr  := token ( "_or_" token )*
--   token := device_vendor 5개 라벨 중 하나 (대소문자 구분, exact match)
-- 괄호·중첩·AND·공백은 문법에 없다. 미지 토큰은 파싱 오류로 취급해 null 을 돌리고
-- **로그를 남긴다** — 조용히 무시하면 뱃지가 이유 없이 안 나온다.
create or replace function public._device_vendor_tokens(p_expr text)
returns public.device_vendor[]
language plpgsql
immutable
set search_path to 'public', 'pg_temp'
as $$
declare
  v_parts text[];
  v_tok   text;
  v_out   public.device_vendor[] := '{}'::public.device_vendor[];
  v_valid constant text[] := array['phone', 'watchApple', 'watchGarmin', 'watchOther', 'unknown'];
begin
  if p_expr is null or p_expr = '' then
    raise notice '_device_vendor_tokens: 빈 표현식 — 판정 불가';
    return null;
  end if;

  if p_expr !~ '^[a-z][A-Za-z0-9]*(_or_[a-z][A-Za-z0-9]*)*$' then
    raise notice '_device_vendor_tokens: 문법 오류 — %', p_expr;
    return null;
  end if;

  v_parts := string_to_array(p_expr, '_or_');

  foreach v_tok in array v_parts loop
    if not (v_tok = any (v_valid)) then
      raise notice '_device_vendor_tokens: 미지 토큰 "%" (표현식 %)', v_tok, p_expr;
      return null;
    end if;
    v_out := v_out || v_tok::public.device_vendor;
  end loop;

  return v_out;
end;
$$;

comment on function public._device_vendor_tokens(text) is
  '뱃지 조건의 device 토큰 표현식(`watchApple_or_watchGarmin`)을 device_vendor[] 로 파싱. '
  '문법 오류·미지 토큰이면 null + notice → 해당 뱃지는 false. TRD §3.1.2';

-- -----------------------------------------------------------------------------
-- 41-0-h. PB 기록 시간 — 허용오차 + 초과 세션 보간 (§5.1)
-- -----------------------------------------------------------------------------
-- 이전 구현: 거리 [목표×98%, 목표×115%] 구간 세션의 moving_seconds 최솟값.
--   문제 ① 고정 2% 는 풀마라톤에서 844m 부족까지 인정 — 너무 관대
--   문제 ② 상한 115% 는 42.2km 를 뛴 사람의 5km PB 를 원천 차단하고,
--          11.5km 세션의 **총 시간**을 10km 기록으로 인정해 그 사람에게 불리하게 작동
-- 확정:
--   허용 부족분 = min(목표 × 2%, 300m)  — 상대 오차를 짧은 거리에, 절대 상한을 긴 거리에
--   상한 폐지. 목표의 102% 이하는 moving_seconds 그대로,
--            초과하면 **목표 거리 통과 시각을 보간**해 산출(보간 불가 = 인정하지 않음)
--   ⚠️ 거리 비례 환산(시간 × 목표/실제)은 금지 — 페이스가 균일하지 않아 가짜 PB 를 만든다
create or replace function public._pb_best_seconds(p_user_id uuid, p_target_km double precision)
returns double precision
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  with cfg as (
    select p_target_km * 1000.0                            as target_m,
           least(p_target_km * 1000.0 * 0.02, 300.0)        as tol
  ),
  cand as (
    select r.distance_meters, r.moving_seconds, r.samples, c.target_m
      from public.runs r, cfg c
     where r.user_id = p_user_id
       and r.status = 'completed'
       and r.is_flagged = false
       and r.activity_type <> 'indoor_run'
       and r.distance_meters >= c.target_m - c.tol
  ),
  timed as (
    select case
             when cd.distance_meters <= cd.target_m * 1.02
               then cd.moving_seconds::double precision
             else extract(epoch from (
                    public._run_time_at_distance(cd.samples, cd.target_m)
                    - public._run_time_at_distance(cd.samples, 0)
                  ))::double precision
           end as secs
      from cand cd
  )
  select min(secs) from timed where secs is not null and secs > 0;
$$;

comment on function public._pb_best_seconds(uuid, double precision) is
  '해당 목표 거리의 개인 최고 기록(초). 허용 부족분 min(목표×2%%, 300m), 상한 없음. '
  '목표의 102%% 초과 세션은 GPS 샘플 선형 보간으로 통과 시각을 산출하며, 보간 불가면 인정하지 않는다. '
  '실외·완주·비플래그 세션만. TRD §10.2';

revoke execute on function public._pb_best_seconds(uuid, double precision) from public, anon, authenticated;

-- =========================================================================
-- 41-1. evaluate_badge_condition — 39종 디스패치 (스텁 전량 해제)
-- =========================================================================
-- 33번 함수 전체를 create or replace 로 재정의한다. 변경된 case 는 아래 12개이고
-- 나머지는 33번 그대로다:
--   route_diversity_count_gte / loop_course_count_gte / calendar_date_match /
--   pace_negative_split_count_gte / pace_final_km_faster_pct_gte / pace_variance_lte /
--   pb_first_achieved / pb_time_lte / streak_weeks_gte / level_gte /
--   device_source_count_gte / device_source_diversity_gte / season_weekly_rank_lte
-- district_diversity_gte 분기는 **삭제**했다(37번에서 뱃지·CHECK 모두 제거).
create or replace function public.evaluate_badge_condition(
  p_user_id uuid,
  p_condition_type text,
  p_condition jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_distance_km  double precision;
  v_seconds      double precision;
  v_count        integer;
  v_meters       double precision;
  v_pct          double precision;
  v_sec_per_km   double precision;
  v_weeks        integer;
  v_distinct     integer;
  v_day_str      text;
  v_target_dow   integer;
  v_after_t      time;
  v_before_t     time;
  v_between_lo   time;
  v_between_hi   time;
  v_weekday_only boolean;
  v_type_str     text;
  v_date_str     text;
  v_years        integer;
  v_best_seconds double precision;
  v_sum          double precision;
  v_level        integer;
  v_tokens       public.device_vendor[];
  v_expr         text;
  v_all_ok       boolean;
  v_missing_yrs  integer;
  -- ---- 시즌 뱃지 전용 ------------------------------------------------------
  v_season       text := public.season_id_at(now());
  v_season_start timestamptz := public.season_start(v_season);
  v_season_end   timestamptz := public.season_end(v_season);
  v_tier_cond    public.tier;
  v_bucket       text;
  v_local_start  timestamp;
  v_local_now    timestamp;
  v_season_walk  text;
  v_participated boolean;
  v_seasons_ok   boolean;
  v_i            integer;
  v_top_tier     public.tier;
  v_reached_at   timestamptz;
  v_cutoff       timestamptz;
begin
  if p_user_id is null or p_condition_type is null then
    return false;
  end if;

  case p_condition_type

    -- ---- 누적거리 / 누적횟수 (profiles 캐시 컬럼) --------------------------
    when 'cumulative_distance_gte' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      return exists (
        select 1 from public.profiles p
        where p.id = p_user_id
          and p.total_distance_meters >= v_distance_km * 1000.0
      );

    when 'cumulative_count_gte' then
      v_count := (p_condition ->> 'count')::integer;
      return exists (
        select 1 from public.profiles p
        where p.id = p_user_id and p.total_run_count >= v_count
      );

    -- ---- 단일 세션 --------------------------------------------------------
    when 'session_distance_gte' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.distance_meters >= v_distance_km * 1000.0
      );

    when 'session_duration_gte' then
      v_seconds := (p_condition ->> 'seconds')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.moving_seconds >= v_seconds
      );

    -- ---- 시간대 / 요일 (KST 기준) ------------------------------------------
    when 'session_start_hour_count_gte' then
      v_count        := (p_condition ->> 'count')::integer;
      v_after_t      := nullif(p_condition ->> 'after', '')::time;
      v_before_t     := nullif(p_condition ->> 'before', '')::time;
      v_weekday_only := coalesce((p_condition ->> 'weekdayOnly')::boolean, false);
      if p_condition ? 'between' then
        v_between_lo := (p_condition -> 'between' ->> 0)::time;
        v_between_hi := (p_condition -> 'between' ->> 1)::time;
      else
        v_between_lo := null;
        v_between_hi := null;
      end if;

      return (
        select count(*) >= v_count
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and (v_after_t is null or (r.started_at at time zone 'Asia/Seoul')::time >= v_after_t)
          and (v_before_t is null or (r.started_at at time zone 'Asia/Seoul')::time < v_before_t)
          and (v_between_lo is null or (
                (r.started_at at time zone 'Asia/Seoul')::time >= v_between_lo
                and (r.started_at at time zone 'Asia/Seoul')::time <= v_between_hi
              ))
          and (not v_weekday_only or extract(isodow from r.started_at at time zone 'Asia/Seoul') <= 5)
      );

    when 'weekday_full_week_count_gte' then
      v_count := (p_condition ->> 'count')::integer;
      return (
        select count(*) >= v_count
        from (
          select array_agg(distinct extract(isodow from r.started_at at time zone 'Asia/Seoul')::integer) as dows
          from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          group by date_trunc('week', r.started_at at time zone 'Asia/Seoul')
        ) w
        where w.dows @> array[1,2,3,4,5]
      );

    when 'weekend_both_days_count_gte' then
      v_count := (p_condition ->> 'count')::integer;
      return (
        select count(*) >= v_count
        from (
          select array_agg(distinct extract(isodow from r.started_at at time zone 'Asia/Seoul')::integer) as dows
          from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          group by date_trunc('week', r.started_at at time zone 'Asia/Seoul')
        ) w
        where w.dows @> array[6,7]
      );

    when 'day_of_week_count_gte' then
      v_day_str := upper(coalesce(p_condition ->> 'day', ''));
      v_count   := (p_condition ->> 'count')::integer;
      v_target_dow := case v_day_str
        when 'MON' then 1 when 'TUE' then 2 when 'WED' then 3 when 'THU' then 4
        when 'FRI' then 5 when 'SAT' then 6 when 'SUN' then 7 else null
      end;
      if v_target_dow is null then
        return false;
      end if;
      return (
        select count(*) >= v_count
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and extract(isodow from r.started_at at time zone 'Asia/Seoul') = v_target_dow
      );

    when 'day_of_week_diversity_gte' then
      v_distinct := (p_condition ->> 'distinctDays')::integer;
      return (
        select count(distinct extract(isodow from r.started_at at time zone 'Asia/Seoul')) >= v_distinct
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
      );

    -- ---- 경로 탐험 ----------------------------------------------------------
    -- ⚠️ 41번 변경: 그리드 스내핑 → 반경 300m 그리디 클러스터링
    when 'route_diversity_count_gte' then
      v_distinct := (p_condition ->> 'distinctStartPoints')::integer;
      return public._route_cluster_count(p_user_id) >= v_distinct;

    when 'elevation_gain_cumulative_gte' then
      v_meters := (p_condition ->> 'meters')::double precision;
      select coalesce(sum(r.elevation_gain_meters), 0) into v_sum
      from public.runs r
      where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false;
      return v_sum >= v_meters;

    -- ⚠️ 41번 변경: 200m/1km → 150m/2.0km + GPS 샘플 >= 10
    --   150m : 도심 GPS 시작/종료 픽스 편차가 10~30m 이므로, "건물 앞↔뒤" 수준의
    --          정당한 루프는 살리면서 왕복(out-and-back) 코스를 거른다
    --   2.0km: 1km 루프는 대부분 우연히 성립한다
    --   샘플10: 샘플 없는 수동/실내 기록이 "시작=끝"으로 오판되는 것을 막는다
    --   출발점 최대 이탈 조건은 두지 않는다 — 400m 트랙 5바퀴(최대 이탈 ≈127m)도
    --   정당한 루프이며 이탈 조건은 이를 잘못 배제한다
    when 'loop_course_count_gte' then
      v_count := (p_condition ->> 'count')::integer;
      return (
        select count(*) >= v_count
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.distance_meters >= 2000
          and jsonb_array_length(r.samples) >= 10
          and r.samples -> 0  ->> 'latitude' is not null
          and r.samples -> -1 ->> 'latitude' is not null
          and public._haversine_meters(
                (r.samples -> 0  ->> 'latitude')::double precision,
                (r.samples -> 0  ->> 'longitude')::double precision,
                (r.samples -> -1 ->> 'latitude')::double precision,
                (r.samples -> -1 ->> 'longitude')::double precision
              ) <= 150
      );

    -- ---- 특별한 날 ------------------------------------------------------
    -- ⚠️ 41번 변경: 음력 2종(chuseok/lunar_newyear) 스텁 해제 → lunar_holidays 룩업
    when 'calendar_date_match' then
      v_type_str := p_condition ->> 'type';
      v_date_str := p_condition ->> 'date';

      if v_date_str in ('chuseok', 'lunar_newyear') then
        if exists (
          select 1
          from public.runs r
          join public.lunar_holidays lh
            on lh.holiday_key = v_date_str
           and lh.solar_date  = (r.started_at at time zone 'Asia/Seoul')::date
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
        ) then
          return true;
        end if;

        -- 미등재 연도는 조용히 넘어가지 않는다(§6.1) — 갱신 시점을 놓치지 않기 위한 로그.
        select count(distinct extract(year from r.started_at at time zone 'Asia/Seoul')::integer)
          into v_missing_yrs
          from public.runs r
         where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
           and not exists (
             select 1 from public.lunar_holidays lh
             where lh.holiday_key = v_date_str
               and lh.year = extract(year from r.started_at at time zone 'Asia/Seoul')::integer
           );
        if coalesce(v_missing_yrs, 0) > 0 then
          raise notice 'calendar_date_match: lunar_holidays 미등재 연도 %건 (key=%) — 테이블 갱신 필요',
            v_missing_yrs, v_date_str;
        end if;
        return false;

      elsif v_type_str = 'birthday' then
        return exists (
          select 1
          from public.runs r
          join public.profiles p on p.id = r.user_id
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and p.birth_date is not null
            and to_char(r.started_at at time zone 'Asia/Seoul', 'MM-DD')
              = to_char(p.birth_date at time zone 'Asia/Seoul', 'MM-DD')
        );
      elsif v_date_str is not null then
        return exists (
          select 1 from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and to_char(r.started_at at time zone 'Asia/Seoul', 'MM-DD') = v_date_str
        );
      else
        return false;
      end if;

    when 'membership_anniversary_run' then
      v_years := (p_condition ->> 'years')::integer;
      return exists (
        select 1
        from public.runs r
        join public.profiles p on p.id = r.user_id
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and to_char(r.started_at at time zone 'Asia/Seoul', 'MM-DD')
            = to_char(p.created_at at time zone 'Asia/Seoul', 'MM-DD')
          and extract(year from r.started_at at time zone 'Asia/Seoul')
            - extract(year from p.created_at at time zone 'Asia/Seoul') >= v_years
      );

    -- ---- 페이스 / 속도 ----------------------------------------------------
    when 'pace_avg_lte' then
      v_sec_per_km := (p_condition ->> 'secPerKm')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.avg_pace_sec_per_km is not null
          and r.avg_pace_sec_per_km <= v_sec_per_km
      );

    -- ⚠️ 41번 변경: 거리 절반 지점(보간) 기준 + 세션 >= 4km
    when 'pace_negative_split_count_gte' then
      v_count := (p_condition ->> 'count')::integer;
      return (
        select count(*) >= v_count
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and public._run_negative_split(r.samples, r.distance_meters)
      );

    -- ⚠️ 41번 변경: 세션 >= 5km
    when 'pace_final_km_faster_pct_gte' then
      v_pct := (p_condition ->> 'pct')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and public._run_final_km_faster_pct(r.samples, v_pct, r.distance_meters)
      );

    -- ⚠️ 41번 변경: 스플릿 >= 3 (헬퍼 내부)
    when 'pace_variance_lte' then
      v_pct := (p_condition ->> 'pct')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and public._run_pace_variance_pct(r.samples) is not null
          and public._run_pace_variance_pct(r.samples) <= v_pct
      );

    -- ---- PB (검증된 실외 기록만) --------------------------------------------
    -- ⚠️ 41번 변경: 허용 부족분 min(목표×2%, 300m), 상한 폐지
    when 'pb_first_achieved' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.activity_type <> 'indoor_run'
          and r.distance_meters
              >= v_distance_km * 1000.0 - least(v_distance_km * 1000.0 * 0.02, 300.0)
      );

    -- ⚠️ 41번 변경: 상한 115% 폐지 + 초과 세션은 스플릿 보간
    when 'pb_time_lte' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      v_seconds     := (p_condition ->> 'seconds')::double precision;
      v_best_seconds := public._pb_best_seconds(p_user_id, v_distance_km);
      return v_best_seconds is not null and v_best_seconds <= v_seconds;

    -- ---- 스트릭 (주 단위 + 1회 유예) ---------------------------------------
    -- ⚠️ 41번 변경: 인라인 gaps-and-islands(유예 없음) → 39번 리플레이 결과 캐시.
    --    판정 대상은 longest_streak_weeks — 카탈로그 설명이 "역대 최장"이고
    --    뱃지는 영구 자산이므로 한 번 달성하면 유지된다.
    when 'streak_weeks_gte' then
      v_weeks := (p_condition ->> 'weeks')::integer;
      return exists (
        select 1 from public.profiles p
        where p.id = p_user_id and p.longest_streak_weeks >= v_weeks
      );

    -- ---- 레벨 (스텁 해제 — 39번 XP 시스템) ---------------------------------
    when 'level_gte' then
      v_level := (p_condition ->> 'level')::integer;
      if v_level is null then
        raise notice 'level_gte: condition 에 level 키가 없다 (%)', p_condition;
        return false;
      end if;
      return exists (
        select 1 from public.profiles p
        where p.id = p_user_id and p.level >= v_level
      );

    -- ---- 기기 벤더 (스텁 해제 — 36번 device_vendors 배열) -------------------
    -- 매칭 규칙은 단 하나: device_vendors && ARRAY[tokens(expr)]  (배열 겹침)
    -- 대상 세션: status='completed' AND NOT is_flagged
    -- 하이브리드 세션({phone, watchApple})은 phone 조건과 watchApple 조건을
    -- **동시에** 충족한다 — 의도된 동작이다(TRD §3.1.2).
    when 'device_source_count_gte' then
      v_count  := (p_condition ->> 'count')::integer;
      v_tokens := public._device_vendor_tokens(p_condition ->> 'source');
      if v_tokens is null then
        return false;   -- 파싱 오류. 헬퍼가 이미 notice 를 남겼다.
      end if;
      return (
        select count(*) >= v_count
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.device_vendors && v_tokens
      );

    -- 배열 원소 간은 AND, 원소 내부 `_or_` 는 OR.
    -- "서로 다른 세션" 제약은 두지 않는다(TRD §3.1.2 ⚠️).
    when 'device_source_diversity_gte' then
      -- 빈 배열까지 막는다 — "모든 원소가 충족" 이 공허하게 참이 되는 것을 방지.
      if jsonb_typeof(p_condition -> 'sources') <> 'array'
         or jsonb_array_length(p_condition -> 'sources') = 0 then
        raise notice 'device_source_diversity_gte: sources 배열이 없거나 비어 있다 (%)', p_condition;
        return false;
      end if;

      v_all_ok := true;
      for v_expr in select jsonb_array_elements_text(p_condition -> 'sources') loop
        v_tokens := public._device_vendor_tokens(v_expr);
        if v_tokens is null then
          return false;
        end if;
        if not exists (
          select 1 from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and r.device_vendors && v_tokens
        ) then
          v_all_ok := false;
          exit;
        end if;
      end loop;
      return v_all_ok;

    -- =========================================================================
    -- ---- 시즌: season_tier (절대평가, 현재 시즌 프로필 티어) -------------------
    -- =========================================================================
    when 'season_tier_reached' then
      v_tier_cond := (p_condition ->> 'tier')::public.tier;
      return exists (
        select 1 from public.profiles p
        where p.id = p_user_id
          and p.tier_season_id = v_season
          and p.current_tier >= v_tier_cond
      );

    -- ---- 시즌: season_weekly_rank (티어 내 주간 랭킹) ------------------------
    -- ⚠️ 41번 변경: bucket 도메인 검증 + 최소 모집단 조건
    --   top1     : N >= 10
    --   top10    : N >= 20
    --   top10pct : N >= 20
    -- PRD §5.4.1 은 티어 인원 불균형을 해소하지 않기로 확정했고, 그 결과 시즌 초
    -- 플래티넘은 0~수 명이 된다. 인원 3명 티어에서 "위클리킹"을 주면 뱃지가 참가상이
    -- 되어 다른 사용자의 같은 뱃지 가치까지 떨어뜨린다. §5.4.1 의 "소수 정예를 그대로
    -- 노출한다"는 **순위 표시**에 대한 결정이지 뱃지 발급 기준이 아니다.
    -- 모집단 미달 주에는 아무에게도 지급하지 않는다(에러 아님, 조용히 skip).
    --
    -- top10 과 top10pct 는 포함 관계가 아니다 — N=20 이면 top10pct 가 상위 2명으로
    -- 더 좁고, N=3000 이면 반대가 된다. 각각 독립 판정하는 것이 의도된 설계다.
    when 'season_weekly_rank_lte' then
      v_tier_cond := (p_condition ->> 'tier')::public.tier;
      v_bucket    := p_condition ->> 'bucket';

      if v_bucket is null or v_bucket not in ('top1', 'top10', 'top10pct') then
        raise notice 'season_weekly_rank_lte: 알 수 없는 bucket "%" — 도메인은 {top1,top10,top10pct}', v_bucket;
        return false;
      end if;

      return exists (
        select 1 from public.leaderboard_entries le
        where le.user_id      = p_user_id
          and le.period       = 'weekly'
          and le.metric       = 'distance'
          and le.scope        = 'global'
          and le.tier         = v_tier_cond
          and le.period_start >= v_season_start
          and le.period_start <  v_season_end
          and (
            (v_bucket = 'top1'
              and coalesce(le.participant_count, 0) >= 10
              and le.rank = 1)
            or (v_bucket = 'top10'
              and coalesce(le.participant_count, 0) >= 20
              and le.rank <= 10)
            or (v_bucket = 'top10pct'
              and coalesce(le.participant_count, 0) >= 20
              and le.rank <= ceil(le.participant_count * 0.10))
          )
      );

    -- =========================================================================
    -- ---- 시즌: season_event ---------------------------------------------------
    -- =========================================================================
    when 'season_first_run' then
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.started_at >= v_season_start and r.started_at < v_season_end
      );

    when 'season_first_run_within_days' then
      v_count := (p_condition ->> 'days')::integer;
      return exists (
        select 1 from (
          select min(r.started_at) as first_run
          from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and r.started_at >= v_season_start and r.started_at < v_season_end
        ) f
        where f.first_run is not null
          and f.first_run < v_season_start + make_interval(days => v_count)
      );

    when 'season_weekly_attendance_full', 'season_weekly_attendance_gte_pct' then
      v_pct := case when p_condition_type = 'season_weekly_attendance_gte_pct'
                    then (p_condition ->> 'pct')::double precision
                    else 100 end;
      v_local_start := date_trunc('week', v_season_start at time zone 'Asia/Seoul');
      v_local_now   := date_trunc('week', (least(now(), v_season_end - interval '1 second') at time zone 'Asia/Seoul'));
      return (
        with weeks as (
          select generate_series(v_local_start, v_local_now, interval '7 days')::timestamp as wk
        ),
        active as (
          select distinct date_trunc('week', r.started_at at time zone 'Asia/Seoul') as wk
          from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and r.started_at >= v_season_start and r.started_at < v_season_end
        )
        select case when (select count(*) from weeks) = 0 then false
          else (
            (select count(*) from weeks w where w.wk in (select wk from active))::double precision
            / (select count(*) from weeks)::double precision * 100.0
          ) >= v_pct
        end
      );

    when 'season_weekly_rank_rising_streak_gte' then
      v_count := (p_condition ->> 'weeks')::integer;
      return (
        with weeks as (
          select le.period_start, le.rank,
                 lag(le.rank) over (order by le.period_start) as prev_rank
          from public.leaderboard_entries le
          where le.user_id      = p_user_id
            and le.period       = 'weekly'
            and le.metric       = 'distance'
            and le.scope        = 'global'
            and le.tier         = (select p.current_tier from public.profiles p where p.id = p_user_id)
            and le.period_start >= v_season_start
            and le.period_start <  v_season_end
        ),
        marked as (
          select period_start,
                 case when prev_rank is not null and rank < prev_rank then 0 else 1 end as break_flag
          from weeks
        ),
        grp as (
          select period_start, sum(break_flag) over (order by period_start) as grp_id
          from marked
        )
        select coalesce(max(cnt), 0) >= v_count
        from (select grp_id, count(*) as cnt from grp group by grp_id) g
      );

    when 'season_pb_achieved' then
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.activity_type <> 'indoor_run'
          and r.started_at >= v_season_start and r.started_at < v_season_end
          and r.distance_meters > coalesce((
            select max(r2.distance_meters) from public.runs r2
            where r2.user_id = p_user_id and r2.status = 'completed' and r2.is_flagged = false
              and r2.activity_type <> 'indoor_run'
              and r2.started_at < v_season_start
          ), 0)
      );

    when 'season_best_week_distance_pb' then
      return exists (
        select 1 from public.leaderboard_entries le
        where le.user_id = p_user_id and le.period = 'weekly' and le.metric = 'distance'
          and le.scope = 'global' and le.tier is null
          and le.period_start >= v_season_start and le.period_start < v_season_end
          and le.score > coalesce((
            select max(le2.score) from public.leaderboard_entries le2
            where le2.user_id = p_user_id and le2.period = 'weekly' and le2.metric = 'distance'
              and le2.scope = 'global' and le2.tier is null
              and le2.period_start < v_season_start
          ), 0)
      );

    when 'season_challenge_completed' then
      -- 챌린지 인프라는 있으나 현재 시딩된 챌린지가 0건 — false 는 정상 결과(스텁 아님).
      return exists (
        select 1 from public.challenge_participations cp
        where cp.user_id = p_user_id
          and cp.completed_at is not null
          and cp.completed_at >= v_season_start and cp.completed_at < v_season_end
      );

    when 'season_comeback_run' then
      v_weeks := (p_condition ->> 'gapWeeks')::integer;
      return (
        with last_two as (
          select r.started_at from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and r.started_at >= v_season_start and r.started_at < v_season_end
          order by r.started_at desc
          limit 2
        )
        select count(*) = 2 and (max(started_at) - min(started_at)) >= make_interval(weeks => v_weeks)
        from last_two
      );

    -- 📌 33번 그대로 유지(고정 98%). §5.1 의 새 허용오차 min(목표×2%, 300m)는 정본
    --    문서가 pb_first_achieved / pb_time_lte 에 대해서만 확정한 규칙이라 여기에
    --    임의로 적용하지 않았다. 결과적으로 하프(21.1km) 기준이 두 곳에서 다르다
    --    (PB 20,800m vs 시즌 20,678m). gamification-designer 확인 대상 — 보고서 §다음 라운드.
    when 'season_first_long_distance' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.activity_type <> 'indoor_run'
          and r.started_at >= v_season_start and r.started_at < v_season_end
          and r.distance_meters >= v_distance_km * 1000.0 * 0.98
      );

    when 'season_start_streak_weeks_gte' then
      v_weeks := (p_condition ->> 'weeks')::integer;
      return (
        with wanted_weeks as (
          select generate_series(0, v_weeks - 1) as offset_idx
        ),
        week_starts as (
          select date_trunc('week', v_season_start at time zone 'Asia/Seoul')
                 + (offset_idx * interval '7 days') as wk
          from wanted_weeks
        ),
        active as (
          select distinct date_trunc('week', r.started_at at time zone 'Asia/Seoul') as wk
          from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and r.started_at >= v_season_start and r.started_at < v_season_end
        )
        select coalesce(bool_and(ws.wk in (select wk from active)), false)
        from week_starts ws
      );

    when 'season_streak_weeks_gte' then
      v_weeks := (p_condition ->> 'weeks')::integer;
      return (
        select coalesce(max(len), 0) >= v_weeks
        from (
          select count(*) as len
          from (
            select
              wk,
              wk - (row_number() over (order by wk) * 7)::integer as grp
            from (
              select distinct date_trunc('week', r.started_at at time zone 'Asia/Seoul')::date as wk
              from public.runs r
              where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
                and r.started_at >= v_season_start and r.started_at < v_season_end
            ) weeks
          ) grouped
          group by grp
        ) islands
      );

    when 'season_max_tier_reached_before_pct' then
      v_pct := (p_condition ->> 'pct')::double precision;

      select t into v_top_tier
      from unnest(enum_range(null::public.tier)) as t
      order by t desc
      limit 1;

      select tch.reached_at into v_reached_at
      from public.tier_change_history tch
      where tch.user_id   = p_user_id
        and tch.season_id = v_season
        and tch.tier      = v_top_tier;

      if v_reached_at is null or v_pct is null then
        return false;
      end if;

      v_cutoff := v_season_start + (v_season_end - v_season_start) * (v_pct / 100.0);
      return v_reached_at < v_cutoff;

    else
      raise notice 'evaluate_badge_condition: 알 수 없는 condition_type % (user=%)', p_condition_type, p_user_id;
      return false;

  end case;
end;
$function$;

revoke execute on function public.evaluate_badge_condition(uuid, text, jsonb)
  from public, anon, authenticated;

comment on function public.evaluate_badge_condition(uuid, text, jsonb) is
  '뱃지 조건 판정 디스패치(39종 전량 실제 판정 — 41번부터 raise notice 스텁 0개). '
  '정본 규칙은 TRD §10.2. SECURITY DEFINER, client 호출 불가 — evaluate_badges 내부 전용.';

-- -----------------------------------------------------------------------------
-- 41-2. 구 헬퍼 오버로드 제거
-- -----------------------------------------------------------------------------
-- 위 함수 재정의로 호출부가 새 시그니처로 옮겨졌다. 인자 개수가 다른 구 버전을
-- 남겨두면 다음 사람이 잘못된 쪽을 부를 수 있다.
drop function if exists public._run_negative_split(jsonb);
drop function if exists public._run_final_km_faster_pct(jsonb, double precision);

-- -----------------------------------------------------------------------------
-- 41-3. 전 프로필 뱃지 재평가
-- -----------------------------------------------------------------------------
-- INSERT 전용이므로 임계값이 조여진 항목(루프 150m/2km 등)의 기존 지급분은
-- 회수되지 않는다(PRD §8.1). 새로 판정 가능해진 조건(level/streak/device/음력)만
-- 추가 지급된다.
do $$
declare
  v_id uuid;
begin
  for v_id in select p.id from public.profiles p loop
    perform public.evaluate_badges(v_id, null);
  end loop;
end;
$$;
