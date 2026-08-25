-- 27_badge_evaluation_logic
--
-- 뱃지 v2 판정 로직 구현. 25번 마이그레이션(badge_catalog_v2_schema)에서 배치한
-- evaluate_badge_condition / evaluate_badges 스텁을 실제 디스패치로 교체한다.
--
-- 기준: _workspace/20260825_181914_backend_badge-v2-migration.md §5, §7.2
--       _workspace/20260825_architect_badge-model-v2.md §4 (44종 분류표)
--       docs/badge-catalog.csv (condition jsonb 실측)
--
-- ⚠️ 서버 재검증 원칙: 클라이언트는 자기 뱃지를 확정하지 못한다. user_badges에 대한
-- INSERT 정책이 없고(마이그레이션 25), 이 함수들만 SECURITY DEFINER로 쓴다.
--
-- 이번 라운드에서 구현하는 것 (21종, 논리 그룹 기준):
--   cumulative_distance_gte, cumulative_count_gte, session_distance_gte,
--   session_duration_gte, session_start_hour_count_gte, weekday_full_week_count_gte,
--   weekend_both_days_count_gte, day_of_week_count_gte, day_of_week_diversity_gte,
--   route_diversity_count_gte, elevation_gain_cumulative_gte, loop_course_count_gte,
--   calendar_date_match(일부 — 아래 참조), membership_anniversary_run, pace_avg_lte,
--   pace_negative_split_count_gte, pace_final_km_faster_pct_gte, pace_variance_lte,
--   pb_first_achieved, pb_time_lte, streak_weeks_gte(신규 주 단위 스트릭 함수)
--
-- 이번 라운드에서 계속 스텁(false)으로 남기는 것과 이유:
--   level_gte                        — GM-04 XP/레벨 공식 미정 (지시서 명시)
--   scope='seasonal' 전체(19개 타입) — seasons/user_season_tier/weekly_ranking_cache
--                                       테이블이 없다 (지시서 명시)
--   district_diversity_gte           — 역지오코딩 소스 미정 (지시서 명시)
--   device_source_diversity_gte      — OR 표현식 파서 규약 미정 (지시서 명시)
--   device_source_count_gte          — ⚠️ 추가로 발견한 차단 사유(지시서에는 없었음):
--                                       run_sample_source enum이 phone/watch/external
--                                       3종뿐이라 watchApple/watchGarmin을 원천적으로
--                                       구분할 수 없다. 워치 브랜드 컬럼이 DB에 없다.
--   calendar_date_match의 date='chuseok'/'lunar_newyear' 2건 — 음력 변환 함수/데이터가
--                                       DB에 없다. 같은 condition_type의 나머지 7건
--                                       (양력 고정일 + birthday)은 구현했다.

-- =========================================================================
-- 0. 헬퍼 함수
-- =========================================================================

-- 두 좌표 간 거리(m). loop_course_count_gte 판정용.
create or replace function public._haversine_meters(
  lat1 double precision, lon1 double precision,
  lat2 double precision, lon2 double precision
)
returns double precision
language sql
immutable
set search_path to 'public', 'pg_temp'
as $$
  select 2 * 6371000 * asin(sqrt(
    sin(radians(lat2 - lat1) / 2) ^ 2 +
    cos(radians(lat1)) * cos(radians(lat2)) * sin(radians(lon2 - lon1) / 2) ^ 2
  ));
$$;

comment on function public._haversine_meters is
  '두 WGS84 좌표 간 거리(m). loop_course_count_gte(출발/도착 근접 판정)에서 쓴다.';

-- RunSample 배열(jsonb)에서 1km 구간별 소요 시간(초)을 뽑는다.
-- cumulative_distance_meters가 없는 샘플(예: 실내 트레드밀, GPS 미기록)은 빈 결과를 낸다
-- → 의존 조건은 안전하게 false/null로 귀결된다(오탐 방지가 우선).
--
-- 가정(문서화 필요 — 실측 샘플 밀도에 따라 후속 튜닝 여지 있음): 각 km 경계 통과 시각을
-- "누적거리가 그 경계를 처음 넘는 샘플의 timestamp"로 근사한다(보간 없음).
create or replace function public._run_km_split_seconds(p_samples jsonb)
returns table(km_index integer, split_seconds double precision)
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with pts as (
    select
      (elem ->> 'cumulative_distance_meters')::double precision as dist_m,
      (elem ->> 'timestamp')::timestamptz as ts
    from jsonb_array_elements(coalesce(p_samples, '[]'::jsonb)) as elem
    where elem ->> 'cumulative_distance_meters' is not null
      and elem ->> 'timestamp' is not null
  ),
  bounds as (
    select generate_series(
      1,
      floor(coalesce((select max(dist_m) from pts), 0) / 1000.0)::integer
    ) as km_index
  ),
  boundary_times as (
    select
      b.km_index,
      (select min(p.ts) from pts p where p.dist_m >= b.km_index * 1000.0)       as t_end,
      (select min(p.ts) from pts p where p.dist_m >= (b.km_index - 1) * 1000.0) as t_start
    from bounds b
  )
  select km_index, extract(epoch from (t_end - t_start))::double precision as split_seconds
  from boundary_times
  where t_end is not null and t_start is not null and t_end > t_start;
$$;

comment on function public._run_km_split_seconds is
  'RunSample 배열의 1km 구간별 소요시간. 보간 없이 "경계를 처음 넘는 샘플 시각" 근사.
   pace_negative_split_count_gte/pace_final_km_faster_pct_gte/pace_variance_lte 가 쓴다.';

create or replace function public._run_negative_split(p_samples jsonb)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with s as (select * from public._run_km_split_seconds(p_samples)),
       n as (select count(*)::double precision as cnt from s)
  select case when (select cnt from n) < 2 then false
    else (
      (select avg(s.split_seconds) from s, n where s.km_index > n.cnt / 2.0)
      <
      (select avg(s.split_seconds) from s, n where s.km_index <= n.cnt / 2.0)
    )
  end;
$$;

comment on function public._run_negative_split is
  '후반 평균 km 페이스가 전반보다 빠르면 true. 2km 미만 스플릿이면 false(음성 판정, 오탐 방지).';

create or replace function public._run_final_km_faster_pct(p_samples jsonb, p_pct double precision)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  with s as (select * from public._run_km_split_seconds(p_samples)),
       n as (select max(km_index) as last_km, count(*) as cnt from s)
  select case when (select cnt from n) < 2 or p_pct is null then false
    else (
      (select s.split_seconds from s, n where s.km_index = n.last_km)
      <=
      (select avg(s.split_seconds) from s, n where s.km_index <> n.last_km) * (1 - p_pct / 100.0)
    )
  end;
$$;

comment on function public._run_final_km_faster_pct is
  '마지막 1km 스플릿이 나머지 구간 평균보다 p_pct%% 이상 빠르면 true.';

create or replace function public._run_pace_variance_pct(p_samples jsonb)
returns double precision
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  select case when count(*) < 2 or avg(split_seconds) = 0 then null
    else (stddev_pop(split_seconds) / avg(split_seconds)) * 100.0
  end
  from public._run_km_split_seconds(p_samples);
$$;

comment on function public._run_pace_variance_pct is
  'km 스플릿 변동계수(%%, stddev/mean*100). 스플릿 2개 미만이면 null → 비교는 항상 false로 귀결.';

-- =========================================================================
-- 1. evaluate_badge_condition — 44종 디스패치
-- =========================================================================

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
  v_distance_km double precision;
  v_seconds     double precision;
  v_count       integer;
  v_meters      double precision;
  v_pct         double precision;
  v_sec_per_km  double precision;
  v_weeks       integer;
  v_distinct    integer;
  v_day_str     text;
  v_target_dow  integer;
  v_after_t     time;
  v_before_t    time;
  v_between_lo  time;
  v_between_hi  time;
  v_weekday_only boolean;
  v_type_str    text;
  v_date_str    text;
  v_years       integer;
  v_best_seconds double precision;
  v_sum         double precision;
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
    when 'route_diversity_count_gte' then
      v_distinct := (p_condition ->> 'distinctStartPoints')::integer;
      -- 가정(문서화 필요): 시작점을 위경도 소수 3자리(~100m)로 반올림해 클러스터링한다.
      -- 정식 지오해시/DBSCAN 클러스터링이 아니므로 경계 근처는 오차가 있을 수 있다.
      return (
        select count(distinct
          round((r.samples -> 0 ->> 'latitude')::numeric, 3)::text || ',' ||
          round((r.samples -> 0 ->> 'longitude')::numeric, 3)::text
        ) >= v_distinct
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and jsonb_array_length(r.samples) > 0
          and r.samples -> 0 ->> 'latitude' is not null
      );

    when 'elevation_gain_cumulative_gte' then
      v_meters := (p_condition ->> 'meters')::double precision;
      select coalesce(sum(r.elevation_gain_meters), 0) into v_sum
      from public.runs r
      where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false;
      return v_sum >= v_meters;

    when 'loop_course_count_gte' then
      v_count := (p_condition ->> 'count')::integer;
      -- 가정(문서화 필요): 출발-도착 직선거리 200m 이내 + 총 거리 1km 이상을 "루프 코스"로 본다.
      return (
        select count(*) >= v_count
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.distance_meters >= 1000
          and jsonb_array_length(r.samples) >= 2
          and r.samples -> 0 ->> 'latitude' is not null
          and r.samples -> -1 ->> 'latitude' is not null
          and public._haversine_meters(
                (r.samples -> 0 ->> 'latitude')::double precision,
                (r.samples -> 0 ->> 'longitude')::double precision,
                (r.samples -> -1 ->> 'latitude')::double precision,
                (r.samples -> -1 ->> 'longitude')::double precision
              ) <= 200
      );

    -- ---- 특별한 날 ------------------------------------------------------
    when 'calendar_date_match' then
      v_type_str := p_condition ->> 'type';
      v_date_str := p_condition ->> 'date';

      if v_date_str in ('chuseok', 'lunar_newyear') then
        -- 음력 변환 함수/데이터가 DB에 없다. 구현 불가 — 계속 false.
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

    when 'pace_negative_split_count_gte' then
      v_count := (p_condition ->> 'count')::integer;
      return (
        select count(*) >= v_count
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and public._run_negative_split(r.samples)
      );

    when 'pace_final_km_faster_pct_gte' then
      v_pct := (p_condition ->> 'pct')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and public._run_final_km_faster_pct(r.samples, v_pct)
      );

    when 'pace_variance_lte' then
      v_pct := (p_condition ->> 'pct')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and public._run_pace_variance_pct(r.samples) is not null
          and public._run_pace_variance_pct(r.samples) <= v_pct
      );

    -- ---- PB (검증된 실외 기록만) --------------------------------------------
    when 'pb_first_achieved' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      -- 가정: GPS 오차를 감안해 목표 거리의 98% 이상이면 해당 거리를 완주한 것으로 본다.
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.activity_type <> 'indoor_run'
          and r.distance_meters >= v_distance_km * 1000.0 * 0.98
      );

    when 'pb_time_lte' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      v_seconds     := (p_condition ->> 'seconds')::double precision;
      -- 가정: 목표거리의 [98%, 115%] 구간에 든 세션만 "그 거리의 기록"으로 인정한다
      -- (훨씬 긴 세션의 스플릿 타임이 아니라 실제 그 거리를 뛴 세션의 총 시간).
      select min(r.moving_seconds) into v_best_seconds
      from public.runs r
      where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
        and r.activity_type <> 'indoor_run'
        and r.distance_meters between v_distance_km * 1000.0 * 0.98 and v_distance_km * 1000.0 * 1.15;
      return v_best_seconds is not null and v_best_seconds <= v_seconds;

    -- ---- 스트릭 (신규: 주 단위) --------------------------------------------
    when 'streak_weeks_gte' then
      v_weeks := (p_condition ->> 'weeks')::integer;
      -- 가정(문서화 필요 — 유예/freeze 규칙 없음, 가장 단순한 해석):
      -- KST 기준 ISO 주(월~일) 중 러닝이 1회 이상 있었던 "연속 주"의 최장 길이.
      -- permanent 뱃지이므로 스트릭이 끊긴 뒤에도 한 번 달성했으면 유지된다(daily 버전과 동일 철학).
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
            ) weeks
          ) grouped
          group by grp
        ) islands
      );

    -- ---- 차단: level_gte (GM-04 XP/레벨 공식 미정) ---------------------------
    when 'level_gte' then
      raise notice 'evaluate_badge_condition: level_gte 보류 — GM-04 XP/레벨 공식 미정';
      return false;

    -- ---- 차단: district_diversity_gte (역지오코딩 소스 미정) -----------------
    when 'district_diversity_gte' then
      raise notice 'evaluate_badge_condition: district_diversity_gte 보류 — 역지오코딩 소스 미정 (§7.1)';
      return false;

    -- ---- 차단: device_source_diversity_gte (OR 표현식 파서 규약 미정) --------
    when 'device_source_diversity_gte' then
      raise notice 'evaluate_badge_condition: device_source_diversity_gte 보류 — OR 표현식 파서 규약 미정';
      return false;

    -- ---- 차단(신규 발견): device_source_count_gte ---------------------------
    -- run_sample_source enum이 phone/watch/external 뿐이라 watchApple/watchGarmin을
    -- 구분할 원천 데이터가 DB에 없다. gps-tracking-engineer가 워치 브랜드를 기록하는
    -- 컬럼(예: runs.device_vendor 또는 samples 내 vendor 키)을 추가해야 구현 가능하다.
    when 'device_source_count_gte' then
      raise notice 'evaluate_badge_condition: device_source_count_gte 보류 — watchApple/watchGarmin 구분 컬럼이 DB에 없음';
      return false;

    -- ---- 차단: scope=seasonal 41종 템플릿(19개 condition_type) ---------------
    -- seasons / user_season_tier / weekly_ranking_cache 테이블이 없다.
    -- season_id가 항상 null이라 evaluate_badges의 스코프 필터에서 이미 걸러지지만,
    -- 방어적으로 이 함수도 명시적으로 false를 반환한다.
    when 'season_tier_reached',
         'season_weekly_rank_lte',
         'season_cumulative_distance_gte',
         'season_first_run',
         'season_weekly_attendance_full',
         'season_weekly_attendance_gte_pct',
         'season_first_run_within_days',
         'season_pb_achieved',
         'season_best_week_distance_pb',
         'season_challenge_completed',
         'season_weekly_rank_rising_streak_gte',
         'season_max_tier_reached_before_pct',
         'season_comeback_run',
         'season_first_long_distance',
         'season_start_streak_weeks_gte',
         'season_streak_weeks_gte',
         'season_final_week_active',
         'season_first_and_last_week_active',
         'consecutive_seasons_participated_gte' then
      raise notice 'evaluate_badge_condition: % 보류 — seasons/user_season_tier/weekly_ranking_cache 테이블 없음', p_condition_type;
      return false;

    else
      raise notice 'evaluate_badge_condition: 알 수 없는 condition_type % (user=%)', p_condition_type, p_user_id;
      return false;

  end case;
end;
$function$;

revoke execute on function public.evaluate_badge_condition(uuid, text, jsonb) from public, anon, authenticated;

-- =========================================================================
-- 2. evaluate_badges — 카탈로그 순회 + 지급
-- =========================================================================

create or replace function public.evaluate_badges(p_user_id uuid, p_source_run_id uuid default null)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_badge   record;
  v_awarded integer := 0;
begin
  if p_user_id is null then
    return 0;
  end if;

  perform set_config('runnit.server_write', 'on', true);

  -- scope='permanent' 이거나, scope='seasonal'이면서 season_id가 채워진(발급된) 인스턴스만
  -- 대상으로 한다. 현재 모든 seasonal 행은 season_id=null 템플릿이라 자동으로 제외된다
  -- (시즌 인스턴스 발급 잡은 별도 후속 작업, backend-engineer §7.3).
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
        v_awarded := v_awarded + 1;
      end if;
    end if;
  end loop;

  perform set_config('runnit.server_write', 'off', true);

  return v_awarded;
end;
$function$;

revoke execute on function public.evaluate_badges(uuid, uuid) from public, anon, authenticated;
