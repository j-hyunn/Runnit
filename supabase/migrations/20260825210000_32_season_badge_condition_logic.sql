-- =============================================================================
-- Runnit :: 32. 시즌 뱃지 판정 로직 (PRD GM-08 / §5.5) — scope='seasonal' 19종 구현
-- -----------------------------------------------------------------------------
-- 근거: 사용자 지시(2026-08-25, 시즌 뱃지 활성화) — 31번(인스턴스 발급)에 이어
--       evaluate_badge_condition의 seasonal 스텁 블록을 실제 판정으로 교체한다.
--
-- 27번에서 seasonal 19종을 전부 스텁으로 남긴 이유는 "seasons/user_season_tier/
-- weekly_ranking_cache 테이블이 없다"였다. 그러나 19~24번 마이그레이션에서 이미
-- 동등한(오히려 더 정교한) 인프라가 구축되어 있었다 — 재조사 결과:
--   · seasons 테이블      -> season_id_at/season_start/season_end (20번, 순수 계산)
--   · user_season_tier    -> profiles.current_tier/season_distance_meters/
--                             tier_season_id (19,22번) + season_histories(21번, 시즌 마감 스냅샷)
--   · weekly_ranking_cache -> leaderboard_entries (period='weekly', metric='distance',
--                             scope='global', tier=<티어>) — 5분 주기로 티어별 4개 보드가
--                             항상 갱신되고(23번 refresh_all_leaderboards), 지난 주차 행도
--                             삭제되지 않고 누적 보존된다(같은 period_start만 정리) —
--                             그래서 "이번 시즌 주간 랭킹 이력"을 그대로 조회할 수 있다.
--
-- 즉 "테이블이 없어서 못 한다"는 전제 자체가 더 이상 유효하지 않았다. 19종 중
-- 18종을 이번에 구현하고, 딱 1종만 데이터 부재로 계속 스텁한다:
--   season_max_tier_reached_before_pct — "시즌 중 최초로 현재 티어에 도달한 시각"이
--     필요한데, profiles는 현재 티어만 들고 있고 season_histories는 시즌 "마감" 시점
--     스냅샷만 남긴다. 티어 변경 이력(tier_history) 테이블이 없으면 특정 시점(pct)
--     이전 도달 여부를 절대 복원할 수 없다 — 진짜 스키마 갭.
--
-- season_challenge_completed 은 challenge_participations/challenges 테이블은 있지만
-- 현재 시딩된 챌린지가 0건이라 항상 false를 반환한다 — 이건 "스텁"이 아니라 정상적인
-- "데이터 없음" 결과다(챌린지가 생기면 별도 코드 변경 없이 바로 동작한다).
--
-- 여러 조건이 "가정"을 명시적으로 깔고 간다(문서화 필요, 후속 튜닝 여지):
--   · season_weekly_rank_rising_streak_gte: 시즌 전체에서 "연속 상승" 최장 길이를 보되,
--     반드시 지금(가장 최근 주)까지 이어질 필요는 없다고 해석한다.
--   · season_start_streak_weeks_gte: 시즌 첫 N주는 "시즌 시작일이 속한 KST 캘린더 주"부터
--     7일 단위로 끊는다 — 시즌 시작이 항상 월요일은 아니라서 첫 주에 이전 분기 며칠이
--     섞여 계산될 수 있다.
--   · season_pb_achieved / season_best_week_distance_pb: "이번 시즌 이전 전체 이력"과
--     비교해 이번 시즌에 신기록이 나왔는지를 본다(이번 시즌 내에서의 상대적 신기록이 아님).
-- =============================================================================

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
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.activity_type <> 'indoor_run'
          and r.distance_meters >= v_distance_km * 1000.0 * 0.98
      );

    when 'pb_time_lte' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      v_seconds     := (p_condition ->> 'seconds')::double precision;
      select min(r.moving_seconds) into v_best_seconds
      from public.runs r
      where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
        and r.activity_type <> 'indoor_run'
        and r.distance_meters between v_distance_km * 1000.0 * 0.98 and v_distance_km * 1000.0 * 1.15;
      return v_best_seconds is not null and v_best_seconds <= v_seconds;

    -- ---- 스트릭 (주 단위) --------------------------------------------------
    when 'streak_weeks_gte' then
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

    -- ---- 차단: device_source_count_gte (watchApple/watchGarmin 구분 컬럼 없음) --
    when 'device_source_count_gte' then
      raise notice 'evaluate_badge_condition: device_source_count_gte 보류 — watchApple/watchGarmin 구분 컬럼이 DB에 없음';
      return false;

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

    -- ---- 시즌: season_cumulative_distance -----------------------------------
    when 'season_cumulative_distance_gte' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      return exists (
        select 1 from public.profiles p
        where p.id = p_user_id
          and p.tier_season_id = v_season
          and p.season_distance_meters >= v_distance_km * 1000.0
      );

    -- ---- 시즌: season_weekly_rank (티어 내 주간 랭킹, leaderboard_entries 재사용) --
    when 'season_weekly_rank_lte' then
      v_tier_cond := (p_condition ->> 'tier')::public.tier;
      v_bucket    := p_condition ->> 'bucket';
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
            (v_bucket = 'top1'     and le.rank <= 1)
            or (v_bucket = 'top10'    and le.rank <= 10)
            or (v_bucket = 'top10pct' and le.rank <= greatest(1, ceil(coalesce(le.participant_count, 1) * 0.1)))
          )
      );

    -- =========================================================================
    -- ---- 시즌: season_event (12종) ------------------------------------------
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
      -- 챌린지 인프라는 있으나 현재 시딩된 챌린지가 0건 — false는 정상 결과(스텁 아님).
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

    -- ---- 차단: season_max_tier_reached_before_pct (티어 도달 시각 이력 없음) ----
    when 'season_max_tier_reached_before_pct' then
      raise notice 'evaluate_badge_condition: season_max_tier_reached_before_pct 보류 — 시즌 중 티어 최초 도달 시각 이력이 DB에 없음(season_histories는 시즌 마감 스냅샷만 기록)';
      return false;

    -- =========================================================================
    -- ---- 시즌: season_finisher (4종) ------------------------------------------
    -- =========================================================================
    when 'season_final_week_active' then
      return (
        now() >= v_season_end - interval '7 days' and now() < v_season_end
        and exists (
          select 1 from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and r.started_at >= v_season_end - interval '7 days' and r.started_at < v_season_end
        )
      );

    when 'season_first_and_last_week_active' then
      return (
        exists (
          select 1 from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and r.started_at >= v_season_start and r.started_at < v_season_start + interval '7 days'
        )
        and now() >= v_season_end - interval '7 days' and now() < v_season_end
        and exists (
          select 1 from public.runs r
          where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
            and r.started_at >= v_season_end - interval '7 days' and r.started_at < v_season_end
        )
      );

    when 'consecutive_seasons_participated_gte' then
      v_count       := (p_condition ->> 'seasons')::integer;
      v_season_walk := v_season;
      v_seasons_ok  := true;
      for v_i in 1..v_count loop
        if v_season_walk = v_season then
          select (p.season_distance_meters > 0 or exists (
                    select 1 from public.runs r
                    where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
                      and r.started_at >= v_season_start and r.started_at < v_season_end
                  ))
            into v_participated
            from public.profiles p
            where p.id = p_user_id;
        else
          v_participated := exists (
            select 1 from public.season_histories sh
            where sh.user_id = p_user_id and sh.season_id = v_season_walk
              and sh.is_voided = false
              and (sh.run_count > 0 or sh.distance_meters > 0)
          );
        end if;

        if not coalesce(v_participated, false) then
          v_seasons_ok := false;
          exit;
        end if;

        v_season_walk := public.season_previous_id(v_season_walk);
      end loop;
      return v_seasons_ok;

    else
      raise notice 'evaluate_badge_condition: 알 수 없는 condition_type % (user=%)', p_condition_type, p_user_id;
      return false;

  end case;
end;
$function$;

revoke execute on function public.evaluate_badge_condition(uuid, text, jsonb)
  from public, anon, authenticated;

comment on function public.evaluate_badge_condition(uuid, text, jsonb) is
  '뱃지 조건 판정 디스패치(44종). 32번부터 scope=seasonal 19종 중 18종을 실제 판정으로 구현
   (season_max_tier_reached_before_pct만 티어 도달 시각 이력 부재로 계속 false). SECURITY DEFINER,
   client 호출 불가 — evaluate_badges 내부에서만 사용.';
