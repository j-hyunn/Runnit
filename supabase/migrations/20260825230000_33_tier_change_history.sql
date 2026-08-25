-- =============================================================================
-- Runnit :: 33. tier_change_history — 시즌 내 티어 최초 도달 시각 이력
-- -----------------------------------------------------------------------------
-- 근거: 사용자 지시(2026-08-25) — 32번에서 유일하게 스텁으로 남은
--       season_max_tier_reached_before_pct("조기졸업" 뱃지, sevent_tier_early)를
--       실제로 판정하려면 "이 유저가 이번 시즌에 언제 최고 티어(플래티넘)에 처음
--       도달했는가" 타임스탬프가 필요하다. profiles.current_tier/tier_season_id는
--       현재 상태만, season_histories는 시즌 "마감" 스냅샷만 갖고 있어 이 질문에
--       답할 수 없다 — 진짜 스키마 갭(32번 보고서 §3 참조).
--
-- 설계
--   1) 티어가 실제로 바뀌는 유일한 지점은 recompute_season_tier(22번)의
--      "3) 티어 판정 + 시즌 포인터 갱신" 블록이다. 여기서만 current_tier를 쓴다.
--      이 함수를 create or replace로 재정의해 티어 갱신 직후 이력 삽입을 추가한다.
--   2) 이력은 "최초 도달"만 의미가 있다 — 같은 시즌에 같은 티어로 반복 재계산되는
--      매 recompute 호출마다 행이 쌓이면 이력이 아니라 로그가 된다. 그래서 매번
--      insert를 시도하되 UNIQUE (user_id, season_id, tier) + ON CONFLICT DO NOTHING으로
--      막는다 — 이미 그 시즌에 그 티어가 기록돼 있으면 조용히 스킵되고 최초
--      reached_at이 그대로 보존된다. profiles 행은 recompute_season_tier 상단에서
--      이미 FOR UPDATE로 잠그므로 동시 호출 경합도 안전하다.
--   3) 시즌 중 강등이 있어도(§8.1, 기록 삭제 시 기준선 미달 하향 — 기존 22번 동작)
--      다시 그 티어로 올라오면 이미 존재하는 행이라 재기록되지 않는다 — "최초" 의미가
--      깨지지 않는다.
--   4) "최고 티어"를 sevent_tier_early 뱃지 조건에서 하드코딩(platinum)하지 않는다.
--      public.tier enum의 선언 순서(bronze<silver<gold<platinum)에서 마지막 값을
--      enum_range()로 구해 사용한다 — enum에 티어가 추가/변경돼도 코드 수정 불필요.
--
-- 소급 처리 불가 — 명시
--   이 테이블은 이 마이그레이션 적용 시점부터 쌓인다. 이미 플래티넘(또는 다른 티어)에
--   도달해 있는 기존 유저는 "진짜 도달 시각"을 알 방법이 없다 —
--   season_histories는 시즌 마감 스냅샷만 있고, 마감 전 진행 중 시즌(현재 2026-Q3)은
--   그 스냅샷조차 없다(final_tier만 있고 도달 시각은 애초에 저장 대상이 아니었다).
--   역산 근거가 될 다른 데이터도 없다 — 억지로 만들지 않는다.
--
--   대신 이 마이그레이션 말미에서 현재 시즌 티어를 강제 재계산(recompute_season_tier)해
--   기존 유저 전원의 tier_change_history를 "지금(마이그레이션 적용 시각)"으로 1행씩
--   채워 넣는다. 이는 진짜 도달 시각이 아니라 "이 마이그레이션이 적용된 시각"이므로:
--     - 진짜로 pct% 이전에 일찍 도달했던 기존 유저는 이 근사치 때문에 그 사실을
--       증명할 수 없어 sevent_tier_early를 못 받을 수 있다(false negative만 발생).
--     - 반대로 실제로는 pct% 이후에 도달한 유저가 이 근사치 때문에 부당하게
--       뱃지를 받는 경우(false positive)는 없다 — 근사 시각이 항상 "지금"이므로
--       실제 도달 시각보다 늦거나 같을 뿐, 빠를 수 없다.
--   즉 오지급 방향으로는 절대 틀리지 않는다. 이 테이블 생성 이후 새로 티어에
--   도달하는 경우부터는 정확한 시각이 기록되어 완전히 정상 동작한다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 33-1. 이력 테이블
-- -----------------------------------------------------------------------------
create table public.tier_change_history (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid        not null references public.profiles (id) on delete cascade,
  season_id  text        not null,
  tier       public.tier not null,
  reached_at timestamptz not null default now(),

  constraint tier_change_history_season_id_format check (season_id ~ '^\d{4}-Q[1-4]$'),
  constraint tier_change_history_user_season_tier_uniq unique (user_id, season_id, tier)
);

-- 판정 쿼리 패턴: "이 유저가 이번 시즌에 최고 티어에 처음 도달한 시각" ->
-- (user_id, season_id, tier) 정확히 일치 조회. UNIQUE 제약의 인덱스가 이미 이 패턴을 커버한다.
comment on table public.tier_change_history is
  '시즌 내 티어 최초 도달 시각 이력. recompute_season_tier가 티어 갱신 직후 기록. '
  'UNIQUE(user_id, season_id, tier) + ON CONFLICT DO NOTHING으로 같은 시즌·같은 티어 재기록 방지 '
  '(= 최초 도달 시각만 보존). 이 테이블 생성 이전 도달분은 소급 복원 불가(정확한 시각 데이터 부재) — '
  '마이그레이션 33 적용 시점에 기존 유저는 "지금"을 근사치로 1행씩 백필했다(false negative만 유발, 오지급 없음).';
comment on column public.tier_change_history.reached_at is
  '해당 (user_id, season_id, tier) 조합에 처음 도달한 시각. 강등 후 재도달해도 갱신되지 않는다.';

create index tier_change_history_user_season_idx
  on public.tier_change_history (user_id, season_id);

-- -----------------------------------------------------------------------------
-- 33-2. RLS — 조회는 본인 것만, write는 client 전면 금지(서버 함수 경로만)
-- -----------------------------------------------------------------------------
-- season_histories(21번)와 달리 이 이력은 "언제 도달했는가"라는 세부 타임스탬프라
-- 굳이 전체 공개할 이유가 없다(프로필 공개 조회는 current_tier로 이미 충족).
-- 본인만 조회 가능하게 좁혀 둔다 — 필요해지면 나중에 완화하는 편이 안전하다.
alter table public.tier_change_history enable row level security;

create policy tier_change_history_select_own
  on public.tier_change_history
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- insert/update/delete 정책 없음 = 클라이언트 write 전면 금지.
-- 유일한 쓰기 경로는 security definer 함수 recompute_season_tier(아래 33-3).

-- -----------------------------------------------------------------------------
-- 33-3. recompute_season_tier 재정의 — 티어가 실제로 바뀔 때만 이력 삽입
-- -----------------------------------------------------------------------------
-- 22번 원본과 동일하되, "3) 티어 판정 + 시즌 포인터 갱신" 직후에 이력 삽입 1문만 추가.
-- 그 외 로직(이전 시즌 마감, 현재 시즌 거리 재계산)은 변경 없이 그대로 복사했다 —
-- 기존 마이그레이션 파일은 고치지 않는 관례를 지키기 위해 함수 전체를
-- create or replace로 재정의한다.
create or replace function public.recompute_season_tier(
  p_user_id uuid,
  p_at      timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_season      text        := public.season_id_at(p_at);
  v_start       timestamptz := public.season_start(v_season);
  v_end         timestamptz := public.season_end(v_season);
  v_prev_season text;
  v_prev_tier   public.tier;
  v_prev_dist   double precision;
  v_dist        double precision := 0;
  v_new_tier    public.tier;
begin
  -- 동시에 두 러닝이 업로드돼도 마감/리셋이 한 번만 일어나도록 행 잠금.
  select p.tier_season_id, p.current_tier, p.season_distance_meters
    into v_prev_season, v_prev_tier, v_prev_dist
    from public.profiles p
   where p.id = p_user_id
     for update;

  if not found then
    return;   -- 프로필이 없으면(삭제 cascade 중) 조용히 종료
  end if;

  -- ── 1) 시즌 경계를 넘었으면 이전 시즌 확정 마감 (§8.1) ─────────────────────
  -- UNIQUE (user_id, season_id) + ON CONFLICT DO NOTHING = 중복 마감 불가.
  if v_prev_season is distinct from v_season and v_prev_season is not null then
    insert into public.season_histories (
      user_id, season_id, final_tier, distance_meters,
      run_count, moving_seconds, best_weekly_rank, closed_at
    )
    select
      p_user_id,
      v_prev_season,
      v_prev_tier,                        -- 마감 시점 확정 티어(소급 변경 금지)
      coalesce(v_prev_dist, 0),           -- profiles.season_distance_meters 스냅샷
      coalesce(agg.run_count, 0),
      coalesce(agg.moving_seconds, 0),
      (
        select min(le.rank)
          from public.leaderboard_entries le
         where le.user_id      = p_user_id
           and le.period       = 'weekly'
           and le.metric       = 'distance'
           and le.scope        = 'global'
           and le.period_start >= public.season_start(v_prev_season)
           and le.period_start <  public.season_end(v_prev_season)
      ),
      now()
    from (
      select count(*)::integer                        as run_count,
             coalesce(sum(r.moving_seconds), 0)::integer as moving_seconds
        from public.runs r
       where r.user_id       = p_user_id
         and r.status        = 'completed'
         and r.is_flagged    = false
         and r.activity_type <> 'indoor_run'
         and r.started_at   >= public.season_start(v_prev_season)
         and r.started_at   <  public.season_end(v_prev_season)
    ) agg
    on conflict (user_id, season_id) do nothing;
  end if;

  -- ── 2) 현재 시즌 거리 재계산 (§8.3 실외만 / §8.5 시작 시각 귀속) ──────────
  select coalesce(sum(r.distance_meters), 0)
    into v_dist
    from public.runs r
   where r.user_id       = p_user_id
     and r.status        = 'completed'
     and r.is_flagged    = false
     and r.activity_type <> 'indoor_run'
     and r.started_at   >= v_start
     and r.started_at   <  v_end;

  -- ── 3) 티어 판정 + 시즌 포인터 갱신 ───────────────────────────────────────
  v_new_tier := public.tier_for_distance(v_dist);

  perform set_config('runnit.server_write', 'on', true);

  update public.profiles p
     set season_distance_meters = v_dist,
         current_tier           = v_new_tier,
         tier_season_id         = v_season,
         updated_at             = now()
   where p.id = p_user_id;

  perform set_config('runnit.server_write', 'off', true);

  -- ── 4) (33번 신규) 티어 최초 도달 이력 — 같은 시즌·같은 티어는 최초 1행만 ──
  -- 매 recompute 호출마다 시도하지만 UNIQUE(user_id, season_id, tier) +
  -- ON CONFLICT DO NOTHING이 "실제로 바뀔 때만" 행이 생기도록 보장한다.
  insert into public.tier_change_history (user_id, season_id, tier, reached_at)
  values (p_user_id, v_season, v_new_tier, p_at)
  on conflict (user_id, season_id, tier) do nothing;
end;
$$;

revoke execute on function public.recompute_season_tier(uuid, timestamptz)
  from public, anon, authenticated;

comment on function public.recompute_season_tier(uuid, timestamptz) is
  '시즌 누적 거리 전체 재계산 + 티어 판정 + 시즌 경계 시 이전 시즌 마감 + '
  '티어 최초 도달 이력(tier_change_history) 기록. 멱등.';

-- -----------------------------------------------------------------------------
-- 33-4. evaluate_badge_condition — season_max_tier_reached_before_pct 실제 판정
-- -----------------------------------------------------------------------------
-- 32번 함수 전체를 create or replace로 재정의하되, 유일한 변경점은
-- 'season_max_tier_reached_before_pct' 케이스 하나뿐이다. 나머지 43개 case는
-- 32번 그대로(문자 그대로) 복사 유지 — 로직 변경 없음.
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
  -- ---- 33번 신규: season_max_tier_reached_before_pct ----------------------
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

    -- ---- 33번 신규: season_max_tier_reached_before_pct 실제 판정 ------------
    -- "이번 시즌 최고 티어(enum 선언 순서상 마지막 값 — 하드코딩 금지)에 시즌
    -- 진행률 pct% 이전에 처음 도달했는가"를 tier_change_history에서 조회한다.
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
  '뱃지 조건 판정 디스패치(44종). 33번부터 scope=seasonal 19종 전부 실제 판정으로 구현
   (season_max_tier_reached_before_pct는 tier_change_history 기반). SECURITY DEFINER,
   client 호출 불가 — evaluate_badges 내부에서만 사용.';

-- -----------------------------------------------------------------------------
-- 33-5. 기존 유저 백필 — tier_change_history를 "지금"으로 근사 채움
-- -----------------------------------------------------------------------------
-- 위 소급 처리 불가 설명 참조. recompute_season_tier를 프로필 전원에 대해 강제
-- 호출하면 새로 추가된 4)번 단계(이력 삽입)가 자연히 실행되어, 현재 티어에 대한
-- 근사 이력(reached_at = 지금)이 채워진다. 이미 그 시즌·그 티어 조합이 있으면
-- ON CONFLICT DO NOTHING이라 안전하게 반복 실행 가능(멱등).
do $$
declare
  v_id uuid;
begin
  for v_id in select p.id from public.profiles p loop
    perform public.recompute_season_tier(v_id);
  end loop;
end;
$$;
