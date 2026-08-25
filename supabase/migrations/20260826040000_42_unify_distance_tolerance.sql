-- gamification-designer 확인(2026-08-26) 반영: `session_distance_gte`/`season_first_long_distance`가
-- `pb_first_achieved`/`pb_time_lte`와 같은 "목표 거리 도달" 판정임에도 서로 다른 허용오차를 쓰고 있었다
-- (고정 98% 또는 허용오차 없음). 정본 규칙 min(목표×2%, 300m)로 통일한다.
-- 완화 방향이므로 기존에 이미 지급된 뱃지는 영향 없다(evaluate_badges는 INSERT 전용, 회수 없음).
-- 대상 필터(실외/실내, completed, is_flagged)는 기존 그대로 유지 — 이번 변경은 거리 임계값 한 줄씩뿐.

create or replace function public.evaluate_badge_condition(p_user_id uuid, p_condition_type text, p_condition jsonb DEFAULT '{}'::jsonb)
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

    when 'session_distance_gte' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.distance_meters
              >= v_distance_km * 1000.0 - least(v_distance_km * 1000.0 * 0.02, 300.0)
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

    when 'route_diversity_count_gte' then
      v_distinct := (p_condition ->> 'distinctStartPoints')::integer;
      return public._route_cluster_count(p_user_id) >= v_distinct;

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
          and public._run_negative_split(r.samples, r.distance_meters)
      );

    when 'pace_final_km_faster_pct_gte' then
      v_pct := (p_condition ->> 'pct')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and public._run_final_km_faster_pct(r.samples, v_pct, r.distance_meters)
      );

    when 'pace_variance_lte' then
      v_pct := (p_condition ->> 'pct')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and public._run_pace_variance_pct(r.samples) is not null
          and public._run_pace_variance_pct(r.samples) <= v_pct
      );

    when 'pb_first_achieved' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      return exists (
        select 1 from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.activity_type <> 'indoor_run'
          and r.distance_meters
              >= v_distance_km * 1000.0 - least(v_distance_km * 1000.0 * 0.02, 300.0)
      );

    when 'pb_time_lte' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      v_seconds     := (p_condition ->> 'seconds')::double precision;
      v_best_seconds := public._pb_best_seconds(p_user_id, v_distance_km);
      return v_best_seconds is not null and v_best_seconds <= v_seconds;

    when 'streak_weeks_gte' then
      v_weeks := (p_condition ->> 'weeks')::integer;
      return exists (
        select 1 from public.profiles p
        where p.id = p_user_id and p.longest_streak_weeks >= v_weeks
      );

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

    when 'device_source_count_gte' then
      v_count  := (p_condition ->> 'count')::integer;
      v_tokens := public._device_vendor_tokens(p_condition ->> 'source');
      if v_tokens is null then
        return false;
      end if;
      return (
        select count(*) >= v_count
        from public.runs r
        where r.user_id = p_user_id and r.status = 'completed' and r.is_flagged = false
          and r.device_vendors && v_tokens
      );

    when 'device_source_diversity_gte' then
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

    when 'season_tier_reached' then
      v_tier_cond := (p_condition ->> 'tier')::public.tier;
      return exists (
        select 1 from public.profiles p
        where p.id = p_user_id
          and p.tier_season_id = v_season
          and p.current_tier >= v_tier_cond
      );

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
          and r.distance_meters
              >= v_distance_km * 1000.0 - least(v_distance_km * 1000.0 * 0.02, 300.0)
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

revoke execute on function public.evaluate_badge_condition(uuid, text, jsonb) from public, anon, authenticated;

-- 허용오차가 넓어졌으므로 미지급분을 채운다(회수는 없음 — evaluate_badges는 INSERT 전용).
do $$
declare
  v_user record;
begin
  for v_user in select id from public.profiles loop
    perform public.evaluate_badges(v_user.id);
  end loop;
end;
$$;
