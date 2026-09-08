-- =============================================================================
-- Runnit :: 65. user_badges.achieved_value 신설 + evaluate_badge_condition 전문 관리
--              (TRD §14 #18 · #33 동시 해소)
-- -----------------------------------------------------------------------------
-- 왜 한 마이그레이션인가
--   #18(판정 확정값 기록)은 `evaluate_badge_condition` 이 boolean 으로 버리는 값을
--   다시 살려내야 하고, #33(앵커 치환 회귀 가드 제거)은 바로 그 함수를 전문으로
--   되찾아 오는 작업이다. 같은 함수를 두 번 재정의할 이유가 없고, 무엇보다
--   **판정과 값이 서로 다른 SQL 을 갖게 되는 순간이 새로운 #33** 이다.
--   그래서 갈라질 수 있는 분기는 전부 작은 함수로 뽑아 **양쪽이 같은 것을 부르게**
--   한다 — 그것이 이 마이그레이션의 설계 원칙이다.
--
-- -----------------------------------------------------------------------------
-- #33 — 회귀 가드 의존 제거 (마이그레이션 63 대체)
-- -----------------------------------------------------------------------------
--   63 은 두 가지를 **문자열 존재 검사**로 지켰다:
--     · 57-5 : `season_weekly_rank_lte` 분기의 `and le.finalized_at is not null`
--     · 61-3 : 판정 시즌을 `current_setting('runnit.badge_season')` 로 읽는 것
--   둘 다 **앵커 치환(replace(pg_get_functiondef(...)))** 으로 들어간 조각이라,
--   누군가 함수를 전문 재정의하면 조용히 사라진다. 63 은 그 사고를 "막는" 게 아니라
--   "터뜨려서 알린다"는 안전망이었다.
--
--   이번에 두 가지를 동시에 한다:
--     (a) **전문 관리** — 이 파일이 `evaluate_badge_condition` 의 정본이다.
--         앵커 치환은 더 이상 쓰지 않는다. 원격에서 `pg_get_functiondef` 를 떠와
--         편집하던 관행이 여기서 끝난다.
--     (b) **분해** — 사라지면 안 되는 두 술어를 함수 경계 뒤로 옮긴다:
--           `_badge_eval_season()`              ← 61-3 의 GUC
--           `_season_weekly_rank_badge_rank()`  ← 57-5 의 finalized_at
--         디스패처는 이제 그 함수를 **호출**할 뿐이라, 전문 재정의로 술어가
--         빠지려면 호출 자체를 지워야 한다(= 컴파일이 아니라 의도가 필요하다).
--
--   가드는 없애지 않고 **형태를 바꿔** 남긴다(65-7). 문자열 조각이 아니라
--   "두 헬퍼가 존재하고, 디스패처가 그것을 부른다"를 확인한다 — 훨씬 읽기 쉽고,
--   헬퍼 안의 SQL 을 자유롭게 고쳐도 오탐하지 않는다.
--
-- -----------------------------------------------------------------------------
-- #18 — user_badges.achieved_value
-- -----------------------------------------------------------------------------
--   목적: PB 공유 카드가 서버 확정 기록(초)을 그리지 못하는 구간을 없앤다
--   (TRD §3.9.1, `lib/features/sharing/domain/share_card_data.dart` 의 주석).
--   지금 클라이언트는 "세션 거리 ≤ 목표×102% 면 `moving_seconds`, 초과면 null" 로
--   **서버 규칙을 흉내 내는 폴백**을 갖고 있다. 그 분기가 존재하는 이유는 단 하나,
--   서버가 확정한 숫자를 아무 데도 적어 두지 않기 때문이다.
--
--   시맨틱은 **조건 타입마다 다르고, 단위도 다르다**. 그래서 컬럼 하나에 값만
--   담고 단위는 `badges.condition_type` 이 정한다(65-2 표 참조). 진행률이 아니라
--   **판정이 참이 된 그 순간의 확정값**이다 — 이후 기록이 좋아져도 갱신하지 않는다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 65-1. 컬럼
-- -----------------------------------------------------------------------------
alter table public.user_badges
  add column if not exists achieved_value numeric null;

comment on column public.user_badges.achieved_value is
  '뱃지 판정이 참이 된 **그 시점의 확정값**(마이그레이션 65, TRD §14 #18). '
  '단위는 컬럼이 아니라 `badges.condition_type` 이 정한다 — '
  'pb_time_lte·pb_first_achieved = 초(소수 가능), '
  'streak_weeks_gte·season_streak_weeks_gte = 주 수, '
  'season_weekly_rank_lte = 등수(작을수록 상위), '
  'season_weekly_rank_rising_streak_gte = 연속 상승 주 수. '
  '그 밖의 condition_type 은 확정값 시맨틱이 정의되지 않아 항상 null 이다. '
  '⚠️ **진행률이 아니다.** 판정 이후 기록이 좋아져도 이 값은 갱신되지 않는다 — '
  '"이 뱃지를 딸 때 당신은 이랬다"를 영구 보존하는 값이고, 그래서 공유 카드가 '
  '앱 화면과 어긋나지 않는다. '
  '⚠️ null 은 "값 없음"이지 "0"이 아니다. 마이그레이션 65 이전에 지급된 행은 '
  '전부 null 이다(백필하지 않는다 — 근거는 65 파일 헤더 주석 65-8).';

-- -----------------------------------------------------------------------------
-- 65-2. 판정 시즌 헬퍼 — 61-3 의 GUC 를 함수 경계 뒤로
-- -----------------------------------------------------------------------------
-- 판정 대상은 "지금"이 아니라 **판정 중인 뱃지 인스턴스의 시즌**이다.
-- `evaluate_badges` 가 뱃지마다 `runnit.badge_season` 에 `badges.season_id` 를 싣고,
-- permanent 뱃지는 빈 문자열이라 `season_id_at(now())` 로 폴백한다.
-- 이것 없이는 시즌 말에 걸친 주의 RK-06 이 영영 지급되지 않고(QA C-2),
-- 미획득으로 남은 과거 시즌 인스턴스가 현재 시즌 데이터로 재판정된다(TRD #30).
create or replace function public._badge_eval_season()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    nullif(current_setting('runnit.badge_season', true), ''),
    public.season_id_at(now())
  );
$$;

comment on function public._badge_eval_season() is
  '뱃지 판정이 기준으로 삼을 시즌 id(마이그레이션 65, 61-3 을 함수로 분해). '
  '`runnit.badge_season` GUC → 없으면 `season_id_at(now())`. '
  '⚠️ 이 함수를 거치지 않고 판정 로직이 `season_id_at(now())` 를 직접 쓰면 '
  '시즌 말 걸친 주 RK-06 미지급과 과거 시즌 인스턴스 오판정이 되살아난다.';

revoke execute on function public._badge_eval_season() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 65-3. 주간 랭킹 뱃지 — **등수를 돌려준다**
-- -----------------------------------------------------------------------------
-- 57-5 의 `finalized_at is not null` 가 사는 곳. 판정(boolean)과 확정값(등수)이
-- 같은 술어를 봐야 하므로, boolean 이 아니라 **자격을 만족한 최상위 등수**를
-- 반환한다. 디스패처는 `is not null` 로 boolean 을 만들고, 값 디스패처는 그대로
-- 쓴다 — 두 경로가 갈라질 수 없다.
create or replace function public._season_weekly_rank_badge_rank(
  p_user_id uuid,
  p_tier    public.tier,
  p_bucket  text,
  p_season  text
)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_end   timestamptz;
  v_rank  integer;
begin
  if p_user_id is null or p_season is null then
    return null;
  end if;

  if p_bucket is null or p_bucket not in ('top1', 'top10', 'top10pct') then
    raise notice '_season_weekly_rank_badge_rank: 알 수 없는 bucket "%" — 도메인은 {top1,top10,top10pct}', p_bucket;
    return null;
  end if;

  v_start := public.season_start(p_season);
  v_end   := public.season_end(p_season);

  select min(le.rank)
    into v_rank
    from public.leaderboard_entries le
   where le.user_id      = p_user_id
     and le.period       = 'weekly'
     and le.metric       = 'distance'
     and le.scope        = 'global'
     and le.tier         = p_tier
     and le.period_start >= v_start
     and le.period_start <  v_end
     -- (57번, TRD §14 #23 결함 #2) 확정된 지난 주만 판정 대상.
     -- 진행 중인 주의 일시적 1위로 영구 뱃지가 나가던 경로를 닫는다.
     and le.finalized_at is not null
     and (
       (p_bucket = 'top1'
         and coalesce(le.participant_count, 0) >= 10
         and le.rank = 1)
       or (p_bucket = 'top10'
         and coalesce(le.participant_count, 0) >= 20
         and le.rank <= 10)
       or (p_bucket = 'top10pct'
         and coalesce(le.participant_count, 0) >= 20
         and le.rank <= ceil(le.participant_count * 0.10))
     );

  return v_rank;
end;
$$;

comment on function public._season_weekly_rank_badge_rank(uuid, public.tier, text, text) is
  '`season_weekly_rank_lte` 뱃지의 **자격 등수**(마이그레이션 65, 57-5 를 함수로 분해). '
  '자격을 만족한 주가 여러 개면 그중 가장 좋은(작은) 등수, 없으면 null. '
  '판정(boolean)은 `is not null`, 확정값(`user_badges.achieved_value`)은 이 값 그대로 — '
  '두 경로가 같은 술어를 보게 만드는 것이 이 함수의 존재 이유다. '
  '⚠️ `finalized_at is not null` 를 빼면 진행 중인 주의 일시적 1위로 영구 뱃지가 나간다.';

revoke execute on function public._season_weekly_rank_badge_rank(uuid, public.tier, text, text)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 65-4. 시즌 스트릭 / 순위 상승 스트릭 — 판정과 값이 공유하는 계산
-- -----------------------------------------------------------------------------
-- 27/41 에서 디스패처 안에 인라인돼 있던 두 CTE 를 그대로 옮겼다(로직 변경 없음).
-- 옮기는 이유는 #18 — 값 디스패처가 같은 계산을 복붙하면 그 순간 새로운 #33 이 된다.

create or replace function public._season_streak_weeks(p_user_id uuid, p_season text)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_end   timestamptz;
  v_len   integer;
begin
  if p_user_id is null or p_season is null then
    return null;
  end if;

  v_start := public.season_start(p_season);
  v_end   := public.season_end(p_season);

  select coalesce(max(len), 0)
    into v_len
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
            and r.started_at >= v_start and r.started_at < v_end
        ) weeks
      ) grouped
      group by grp
    ) islands;

  return v_len;
end;
$$;

comment on function public._season_streak_weeks(uuid, text) is
  '한 시즌 안에서의 **최장 연속 러닝 주 수**(마이그레이션 65). '
  '`season_streak_weeks_gte` 판정과 그 확정값이 같은 계산을 쓰도록 분해했다.';

revoke execute on function public._season_streak_weeks(uuid, text)
  from public, anon, authenticated;

create or replace function public._season_weekly_rank_rising_streak(p_user_id uuid, p_season text)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_end   timestamptz;
  v_len   integer;
begin
  if p_user_id is null or p_season is null then
    return null;
  end if;

  v_start := public.season_start(p_season);
  v_end   := public.season_end(p_season);

  with weeks as (
    select le.period_start, le.rank,
           lag(le.rank) over (order by le.period_start) as prev_rank
    from public.leaderboard_entries le
    where le.user_id      = p_user_id
      and le.period       = 'weekly'
      and le.metric       = 'distance'
      and le.scope        = 'global'
      and le.tier         = (select p.current_tier from public.profiles p where p.id = p_user_id)
      and le.period_start >= v_start
      and le.period_start <  v_end
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
  select coalesce(max(cnt), 0)
    into v_len
    from (select grp_id, count(*) as cnt from grp group by grp_id) g;

  return v_len;
end;
$$;

comment on function public._season_weekly_rank_rising_streak(uuid, text) is
  '한 시즌 안에서 주간 순위가 **연속으로 상승한 최장 주 수**(마이그레이션 65). '
  '27/41 의 인라인 CTE 를 로직 변경 없이 옮긴 것이며, 판정과 확정값이 이 함수를 '
  '함께 쓴다. ⚠️ 이 계산은 사용자의 **현재 티어** 행만 본다(원 로직 유지) — '
  '시즌 중 승급하면 승급 이전 주는 집계에서 빠진다. 알려진 한계이며 이번 범위 아님.';

revoke execute on function public._season_weekly_rank_rising_streak(uuid, text)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 65-5. evaluate_badge_condition — **전문 정본** (앵커 치환 폐기)
-- -----------------------------------------------------------------------------
-- 원격(마이그레이션 27/32/41 + 57-5·61-3 치환본)에서 떠온 본문을 그대로 옮기고,
-- 세 곳만 바꿨다:
--   ① v_season  : GUC 인라인 → `_badge_eval_season()`
--   ② season_weekly_rank_lte           : 인라인 exists → `_season_weekly_rank_badge_rank(...) is not null`
--   ③ season_streak_weeks_gte /
--     season_weekly_rank_rising_streak : 인라인 CTE → 65-4 헬퍼 호출
-- 그 외 분기는 **한 글자도 바꾸지 않았다** — 이 마이그레이션은 판정 결과를 바꾸는
-- 마이그레이션이 아니다. (declare 절에서 어느 분기도 쓰지 않는 죽은 변수
--  `v_season_walk` · `v_participated` · `v_seasons_ok` · `v_i` 는 함께 지웠다.)
--
-- 마이그레이션 63 은 이 시점부터 **효력을 잃는다** — 63 이 찾던 두 문자열이 이제
-- 헬퍼 안에 있기 때문이다. 63 파일은 이력이므로 그대로 두되(신규 환경에서는 65
-- 이전 순서에 실행돼 정상 통과한다), **그 블록을 이후 마이그레이션에 복사하지 마라.**
-- 대체 가드는 65-8 이다.
create or replace function public.evaluate_badge_condition(
  p_user_id        uuid,
  p_condition_type text,
  p_condition      jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
  -- (61번 → 65번) 판정 시즌은 "지금"이 아니라 판정 중인 뱃지 인스턴스의 시즌이다.
  v_season       text := public._badge_eval_season();
  v_season_start timestamptz := public.season_start(v_season);
  v_season_end   timestamptz := public.season_end(v_season);
  v_tier_cond    public.tier;
  v_bucket       text;
  v_local_start  timestamp;
  v_local_now    timestamp;
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
      -- (65번) 57-5 의 `finalized_at` 술어와 bucket 문턱은 이제 헬퍼 안에 있다.
      -- 확정값(`achieved_value`)도 같은 헬퍼를 부른다 — 판정과 값이 갈라질 수 없다.
      v_tier_cond := (p_condition ->> 'tier')::public.tier;
      v_bucket    := p_condition ->> 'bucket';
      return public._season_weekly_rank_badge_rank(p_user_id, v_tier_cond, v_bucket, v_season)
             is not null;

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
      return coalesce(public._season_weekly_rank_rising_streak(p_user_id, v_season), 0) >= v_count;

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
      return coalesce(public._season_streak_weeks(p_user_id, v_season), 0) >= v_weeks;

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
$$;

comment on function public.evaluate_badge_condition(uuid, text, jsonb) is
  '뱃지 조건 판정 디스패처(27/32/41 → **65 부터 전문 관리**). '
  '⚠️ 마이그레이션 57-5·61-3 이 쓰던 `replace(pg_get_functiondef(...))` **앵커 치환은 '
  '폐기됐다.** 이 함수를 고칠 때는 마이그레이션 파일에 전문을 다시 실어라. '
  '사라지면 안 되는 두 술어는 `_badge_eval_season()` 과 '
  '`_season_weekly_rank_badge_rank()` 뒤에 있다 — 그 호출을 지우면 '
  'TRD #23(진행 중인 주의 일시적 1위로 영구 뱃지) 과 #30(시즌 말 걸친 주 RK-06 '
  '미지급) 이 되살아난다. 65-7 가드가 그 호출을 확인한다.';

revoke execute on function public.evaluate_badge_condition(uuid, text, jsonb)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 65-6. badge_achieved_value — 확정값 디스패처
-- -----------------------------------------------------------------------------
-- 판정이 **참이 된 직후** 호출된다. 조건 타입별 시맨틱은 65-1 컬럼 코멘트 참조.
-- 정의되지 않은 타입은 null — "값 없음"이 정상 상태이며, 클라이언트는 null 을
-- "그 항목을 표기하지 않는다"로 다뤄야 한다(0 으로 대체 금지).
create or replace function public.badge_achieved_value(
  p_user_id        uuid,
  p_condition_type text,
  p_condition      jsonb default '{}'::jsonb
)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_season      text := public._badge_eval_season();
  v_distance_km double precision;
  v_secs        double precision;
  v_int         integer;
  v_tier_cond   public.tier;
begin
  if p_user_id is null or p_condition_type is null then
    return null;
  end if;

  case p_condition_type

    -- 초. `_pb_best_seconds` 는 세션 거리가 목표의 102% 를 넘으면 GPS 샘플 선형
    -- 보간으로 목표 통과 시각을 쓴다(TRD §10.2) — 그 보간값을 여기서 처음으로
    -- 영구 보존한다. 이 값이 있으면 클라이언트의 `moving_seconds` 폴백이 불필요하다.
    when 'pb_time_lte', 'pb_first_achieved' then
      v_distance_km := (p_condition ->> 'distanceKm')::double precision;
      if v_distance_km is null then
        return null;
      end if;
      v_secs := public._pb_best_seconds(p_user_id, v_distance_km);
      return v_secs::numeric;

    -- 주 수(영구 누적). 판정 시점의 `profiles.longest_streak_weeks`.
    when 'streak_weeks_gte' then
      select p.longest_streak_weeks into v_int
        from public.profiles p where p.id = p_user_id;
      return v_int::numeric;

    -- 주 수(시즌 내 최장 연속).
    when 'season_streak_weeks_gte' then
      return public._season_streak_weeks(p_user_id, v_season)::numeric;

    -- 등수. 판정과 **같은 헬퍼**가 돌려준 자격 등수 그대로.
    when 'season_weekly_rank_lte' then
      v_tier_cond := (p_condition ->> 'tier')::public.tier;
      return public._season_weekly_rank_badge_rank(
               p_user_id, v_tier_cond, p_condition ->> 'bucket', v_season
             )::numeric;

    -- 연속 상승 주 수.
    when 'season_weekly_rank_rising_streak_gte' then
      return public._season_weekly_rank_rising_streak(p_user_id, v_season)::numeric;

    else
      -- 확정값 시맨틱이 정의되지 않은 조건 타입. 조용히 null 을 돌려준다 —
      -- `evaluate_badge_condition` 의 else 와 달리 여기서는 notice 조차 내지 않는다.
      -- 대부분의 뱃지가 이 경로이고, 그것이 정상이다.
      return null;

  end case;
end;
$$;

comment on function public.badge_achieved_value(uuid, text, jsonb) is
  '`user_badges.achieved_value` 에 적을 **판정 시점 확정값**(마이그레이션 65, TRD §14 #18). '
  '단위는 조건 타입이 정한다(초 / 주 수 / 등수) — 컬럼 코멘트 참조. '
  '정의되지 않은 타입은 null 이며 그것이 대부분이자 정상이다. '
  '⚠️ `evaluate_badge_condition` 이 참을 낸 직후에만 부른다. 판정과 값이 같은 헬퍼를 '
  '보도록 설계돼 있으니, 새 조건 타입을 추가할 때 계산식을 이쪽에 복사하지 말고 '
  '**양쪽이 함께 부르는 함수**로 뽑아라(그게 #33 이 남긴 교훈이다).';

revoke execute on function public.badge_achieved_value(uuid, text, jsonb)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 65-7. evaluate_badges — 지급 시 확정값을 함께 적는다
-- -----------------------------------------------------------------------------
create or replace function public.evaluate_badges(
  p_user_id       uuid,
  p_source_run_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_badge     record;
  v_awarded   integer := 0;
  v_pass_cnt  integer;
  v_pass      integer;
  v_value     numeric;
begin
  if p_user_id is null then
    return 0;
  end if;

  perform set_config('runnit.server_write', 'on', true);
  perform set_config('runnit.badge_eval',   'on', true);

  for v_pass in 1..3 loop
    v_pass_cnt := 0;

    for v_badge in
      select b.id, b.condition_type, b.condition, b.season_id
      from public.badges b
      where (b.scope = 'permanent' or (b.scope = 'seasonal' and b.season_id is not null))
        and not exists (
          select 1 from public.user_badges ub
          where ub.user_id = p_user_id and ub.badge_id = b.id
        )
    loop
      -- (61번) 이 뱃지가 어느 시즌의 인스턴스인지를 판정 함수에 넘긴다.
      -- permanent 뱃지는 '' 이고 `_badge_eval_season()` 이 season_id_at(now()) 로 폴백한다.
      perform set_config('runnit.badge_season', coalesce(v_badge.season_id, ''), true);

      if public.evaluate_badge_condition(p_user_id, v_badge.condition_type, v_badge.condition) then
        -- (65번) 확정값은 **판정 직후, 같은 GUC 아래에서** 계산한다.
        -- 여기서 미루면 다음 러닝이 기록을 갱신했을 때 "판정 시점 값"이 아니게 된다.
        v_value := public.badge_achieved_value(
                     p_user_id, v_badge.condition_type, v_badge.condition
                   );

        insert into public.user_badges (
          user_id, badge_id, earned_at, source_run_id, is_seen, verified, revoked, achieved_value
        )
        values (p_user_id, v_badge.id, now(), p_source_run_id, false, true, false, v_value)
        on conflict (user_id, badge_id) do nothing;

        if found then
          v_pass_cnt := v_pass_cnt + 1;
        end if;
      end if;
    end loop;

    v_awarded := v_awarded + v_pass_cnt;
    exit when v_pass_cnt = 0;

    perform public.recompute_profile_stats(p_user_id);
  end loop;

  perform set_config('runnit.badge_season', '',    true);
  perform set_config('runnit.badge_eval',   'off', true);
  perform set_config('runnit.server_write', 'off', true);

  return v_awarded;
end;
$$;

comment on function public.evaluate_badges(uuid, uuid) is
  '미획득 뱃지 전량 재평가(27/61 → 65). **뱃지마다 `runnit.badge_season` GUC 에 '
  '`badges.season_id` 를 실어** 판정 함수가 "지금"이 아니라 그 인스턴스의 시즌을 '
  '보게 한다(61번). 지급 시 `badge_achieved_value()` 로 판정 시점 확정값을 함께 '
  '적는다(65번, TRD §14 #18) — 값 계산은 반드시 INSERT 와 같은 반복 안에서, '
  '같은 GUC 아래에서 이뤄져야 한다.';

revoke execute on function public.evaluate_badges(uuid, uuid)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 65-8. 회귀 가드 — 문자열 조각이 아니라 **호출 관계**를 확인한다
-- -----------------------------------------------------------------------------
-- 마이그레이션 63 의 두 검사를 대체한다. 63 은 함수 본문에서 술어 문자열을 찾았고,
-- 그래서 술어를 한 글자만 고쳐도 오탐했다. 이제는 헬퍼가 실재하고 디스패처가
-- 그것을 부르는지만 본다 — 헬퍼 **안**의 SQL 은 자유롭게 고칠 수 있다.
--
-- ⚠️ 이 가드는 이후 마이그레이션에 **복사하지 않는다.** 63 이 그렇게 요구했던 이유는
--    앵커 치환이라는 취약한 시공법 때문이었고, 그 시공법이 이 마이그레이션에서
--    사라졌다. 여기 한 번 있으면 족하다.
do $$
declare
  v_src text;
begin
  if to_regprocedure('public._badge_eval_season()') is null then
    raise exception '65: _badge_eval_season() 이 없다 — 뱃지 판정이 "지금"의 시즌을 보게 된다 (TRD #30)';
  end if;

  if to_regprocedure('public._season_weekly_rank_badge_rank(uuid, public.tier, text, text)') is null then
    raise exception '65: _season_weekly_rank_badge_rank() 가 없다 — 진행 중인 주의 일시적 1위로 영구 뱃지가 나간다 (TRD #23)';
  end if;

  select pg_get_functiondef(oid) into v_src
    from pg_proc
   where proname = 'evaluate_badge_condition'
     and pronamespace = 'public'::regnamespace;

  if position('_badge_eval_season' in v_src) = 0
     or position('_season_weekly_rank_badge_rank' in v_src) = 0 then
    raise exception '65: evaluate_badge_condition 이 두 헬퍼를 더 이상 부르지 않는다 — TRD #23/#30 이 되살아났다';
  end if;

  if position('and le.finalized_at is not null'
              in pg_get_functiondef(
                   to_regprocedure('public._season_weekly_rank_badge_rank(uuid, public.tier, text, text)')::oid
                 )) = 0 then
    raise exception '65: _season_weekly_rank_badge_rank 에서 finalized_at 필터가 사라졌다 (TRD #23)';
  end if;
end $$;
