-- =============================================================================
-- Runnit :: 25. 뱃지 시스템 v2 스키마 재구성
-- -----------------------------------------------------------------------------
-- 근거: docs/TRD.md §3.6 / §4.1 / §5, docs/PRD.md §5.5(GM-01~09) · §8.1 · §8.4,
--       _workspace/20260825_architect_badge-model-v2.md (§2 결정사항, §4 44종 분류표)
--
-- v1 → v2 격차 요약:
--   criteria_type(text) + threshold(double)  →  condition_type(text) + condition(jsonb)
--   category enum 7종                        →  category text CHECK 16종
--   tier enum 4단계                          →  badge_grade text 6단계(+diamond/+special)
--   is_active(bool)                          →  scope(permanent/seasonal) + season_id
--   (없음)                                   →  trigger_type(session/cumulative)
--   (없음)                                   →  user_badges.verified / user_badges.revoked
--
-- ⚠️ 파괴적 마이그레이션이다. 기존 badges 29종 / user_badges 53건은 v1 판정 스키마
--    (criteria_type/threshold) 산물이라 v2 카탈로그로 매핑할 대응 관계가 없다.
--    프로덕션 사용자가 없는 개발 단계라 전량 폐기한다(사용자 확인 완료).
--
-- 판정 함수(evaluate_badges)는 이 라운드 범위 밖이다. v1 본문이 삭제된 컬럼을
-- 참조하므로 **스텁으로 교체**해 업로드 파이프라인이 깨지지 않게만 한다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 25-0. v1 컬럼(points / criteria_type / threshold / is_active / sort_order)을
--       참조하는 기존 함수 3종을 먼저 정리한다.
--       plpgsql 본문은 컬럼 의존성을 추적하지 않으므로 DROP COLUMN 이 성공해도
--       런타임에 42703 으로 터진다 — 컬럼을 없애기 전에 반드시 갈아끼운다.
-- -----------------------------------------------------------------------------

-- (a) evaluate_badges — v2 판정 미구현 스텁. 시그니처/권한은 그대로 유지해
--     runs 트리거(trg_runs_evaluate_badges)와 챌린지 경로가 계속 컴파일된다.
create or replace function public.evaluate_badges(
  p_user_id       uuid,
  p_source_run_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- TODO(backend): v2 판정 구현. 44종 condition_type 을
  --   public.evaluate_badge_condition(user_id, condition_type, condition) 으로
  --   디스패치하고, 통과분을 user_badges 에 (verified=true) 로 insert 한다.
  --   분류표: _workspace/20260825_architect_badge-model-v2.md §4
  --     client 18 / partial 8 / SERVER 18 — 어느 쪽이든 확정은 100% 서버다.
  raise notice 'evaluate_badges: v2 판정 미구현 (user=%, run=%)',
    p_user_id, p_source_run_id;
  return 0;
end;
$$;

revoke execute on function public.evaluate_badges(uuid, uuid) from public, anon, authenticated;

comment on function public.evaluate_badges(uuid, uuid) is
  '[v2 스텁] 뱃지 자동 판정. v1(criteria_type/threshold) 로직은 스키마 v2 에서 삭제됐고 '
  'v2 판정은 후속 라운드에서 evaluate_badge_condition 디스패치로 구현한다. 현재 항상 0.';

-- (b) recompute_profile_stats — badges.points 합산 제거.
--     PRD §5.6 이 포인트 이코노미를 Phase 4 로 못박았고 카탈로그에 points 열이 없다
--     (설계문서 §2.3). 뱃지발 포인트 원천이 사라지므로 total_points 는
--     러닝 + 완주 챌린지 두 원천만 합산한다.
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

  -- ⚠️ v2: 뱃지 포인트 합산 블록 삭제(badges.points 컬럼 제거). 위 주석 참조.

  select coalesce(sum(c.reward_points), 0)
  into v_chal_pts
  from public.challenge_participations cp
  join public.challenges c on c.id = cp.challenge_id
  where cp.user_id = p_user_id
    and cp.completed_at is not null;

  v_points := v_run_pts + v_chal_pts;

  -- 스트릭: KST 기준 started_at 날짜 집합의 연속 구간(gaps-and-islands).
  -- ⚠️ 이건 **일 단위**다. PRD GM-05 의 뱃지 스트릭(streak_weeks_gte)은 **주 단위**라
  --    별도 계산이 필요하다(설계문서 §4 #3 / §7-4, gamification-designer 확정 대기).
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

-- (c) recompute_challenge_progress — 보상 뱃지 지급 시 badges.points 가산 제거.
--     보상 뱃지 자체는 계속 지급하되, v2 에서는 서버가 부여한 것이므로
--     verified=true 로 넣는다.
create or replace function public.recompute_challenge_progress(
  p_user_id uuid,
  p_run_id  uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  cp           record;
  v_started_at timestamptz;
  v_has_run    boolean := false;
  v_progress   double precision := 0;
  v_updated    integer := 0;
begin
  if p_user_id is null then
    return 0;
  end if;

  if p_run_id is not null then
    select r.started_at into v_started_at from public.runs r where r.id = p_run_id;
    v_has_run := found;
  end if;

  perform set_config('runnit.server_write', 'on', true);

  for cp in
    select part.id            as part_id,
           part.completed_at  as completed_at,
           c.id               as challenge_id,
           c.type             as ctype,
           c.target_value     as target_value,
           c.start_at         as start_at,
           c.end_at           as end_at,
           c.reward_points    as reward_points,
           c.reward_badge_id  as reward_badge_id
    from public.challenge_participations part
    join public.challenges c on c.id = part.challenge_id
    where part.user_id = p_user_id
      and c.status in ('upcoming', 'active')
      and (not v_has_run
           or (v_started_at >= c.start_at and v_started_at < c.end_at))
  loop
    if cp.ctype = 'streak_days' then
      with d as (
        select distinct (r.started_at at time zone 'Asia/Seoul')::date as run_date
        from public.runs r
        where r.user_id = p_user_id
          and r.status = 'completed'
          and r.is_flagged = false
          and r.started_at >= cp.start_at
          and r.started_at <  cp.end_at
      ),
      g as (
        select run_date,
               run_date - (row_number() over (order by run_date))::integer as grp
        from d
      )
      select coalesce(max(s.cnt), 0)
      into v_progress
      from (select count(*) as cnt from g group by g.grp) s;
    else
      select case cp.ctype
               when 'distance_total'      then coalesce(sum(r.distance_meters), 0)
               when 'run_count'           then count(*)::double precision
               when 'single_run_distance' then coalesce(max(r.distance_meters), 0)
               when 'elevation_total'     then coalesce(sum(coalesce(r.elevation_gain_meters, 0)), 0)
               else 0
             end
      into v_progress
      from public.runs r
      where r.user_id = p_user_id
        and r.status = 'completed'
        and r.is_flagged = false
        and r.started_at >= cp.start_at
        and r.started_at <  cp.end_at;
    end if;

    v_progress := greatest(coalesce(v_progress, 0), 0);

    update public.challenge_participations
    set progress_value = v_progress
    where id = cp.part_id;

    v_updated := v_updated + 1;

    if cp.completed_at is null and v_progress >= cp.target_value then
      update public.challenge_participations
      set completed_at = now()
      where id = cp.part_id;

      if cp.reward_points > 0 then
        update public.profiles
        set total_points = total_points + cp.reward_points
        where id = p_user_id;
      end if;

      if cp.reward_badge_id is not null then
        -- v2: 서버(security definer)가 직접 확정하는 경로이므로 verified=true.
        -- ⚠️ v2 에서 badges.points 가산 블록은 삭제됐다(포인트 원천 아님).
        insert into public.user_badges
          (user_id, badge_id, earned_at, source_run_id, is_seen, verified, revoked)
        values (p_user_id, cp.reward_badge_id, now(),
                case when v_has_run then p_run_id else null end, false, true, false)
        on conflict (user_id, badge_id) do nothing;
      end if;

      update public.profiles
      set level = public.compute_level(total_points)
      where id = p_user_id;
    end if;
  end loop;

  perform set_config('runnit.server_write', 'off', true);

  return v_updated;
end;
$$;

revoke execute on function public.recompute_profile_stats(uuid)        from public, anon, authenticated;
revoke execute on function public.recompute_challenge_progress(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 25-1. 기존 데이터 폐기
--       user_badges 를 먼저 지운다(badges 로의 FK). challenges.reward_badge_id 는
--       on delete set null 이라 별도 처리 불필요.
-- -----------------------------------------------------------------------------
delete from public.user_badges;
delete from public.badges;

-- -----------------------------------------------------------------------------
-- 25-2. badges 재구성
-- -----------------------------------------------------------------------------
alter table public.badges drop constraint if exists badges_criteria_type_check;
alter table public.badges drop constraint if exists badges_points_nonneg;
alter table public.badges drop constraint if exists badges_id_slug_format;
drop index if exists public.badges_active_sort_idx;

alter table public.badges
  drop column if exists tier,
  drop column if exists icon_asset,
  drop column if exists criteria_type,
  drop column if exists threshold,
  drop column if exists points,
  drop column if exists sort_order,
  drop column if exists is_secret,
  drop column if exists is_active;

-- category 는 v1 에서 public.badge_category enum(7종)이었다. v2 는 16종이고
-- 이름도 전부 다르다 — enum 을 확장하는 대신 text + CHECK 로 간다.
-- 이유: 카탈로그 운영 중 카테고리가 늘어날 수 있는데 enum 값 추가는
-- 트랜잭션 제약이 있고 롤백이 어렵다. CHECK 는 단순 재정의로 끝난다.
alter table public.badges
  alter column category type text using category::text;

alter table public.badges
  add column if not exists scope        text not null default 'permanent',
  add column if not exists trigger_type text not null default 'cumulative',
  add column if not exists condition_type text not null default 'cumulative_distance_gte',
  add column if not exists condition   jsonb not null default '{}'::jsonb,
  add column if not exists badge_grade text not null default 'bronze',
  add column if not exists season_id   text;

-- default 는 ALTER 를 통과시키기 위한 임시값이다. 시드가 모든 행을 명시적으로
-- 채우므로 컬럼 기본값은 걷어낸다 — 값 없는 뱃지가 조용히 들어오면 안 된다.
alter table public.badges
  alter column scope          drop default,
  alter column trigger_type   drop default,
  alter column condition_type drop default,
  alter column badge_grade    drop default;
-- condition 만 default '{}' 를 남긴다: 파라미터 없는 조건 6종이 실제로 {} 이고,
-- Dart 쪽도 @Default(<String,dynamic>{}) 라 NULL 과 {} 를 동치로 취급한다(설계문서 §2.8).

-- id 슬러그 규칙 완화.
--  (1) 카탈로그에 `device_watchApple_1` 등 camelCase 를 포함한 id 4개가 있다
--      (device_source_count_gte 의 source 값이 `watchApple` 이라 id 에 그대로 박혔다).
--  (2) seasonal 인스턴스 id 는 `{templateId}@{seasonId}` 형태다(예: `stier_platinum@2026-Q3`).
alter table public.badges
  add constraint badges_id_slug_format
  check (id ~ '^[A-Za-z0-9_]{3,64}(@[A-Za-z0-9-]{1,20})?$');

alter table public.badges
  add constraint badges_category_check check (category in (
    'cumulative_distance', 'cumulative_count', 'longest_streak', 'personal_best',
    'single_session_distance', 'time_of_day_weekday', 'route_exploration', 'special_day',
    'pace_speed', 'device_integration', 'level',
    'season_tier', 'season_weekly_rank', 'season_cumulative_distance',
    'season_event', 'season_finisher'
  ));

alter table public.badges
  add constraint badges_scope_check check (scope in ('permanent', 'seasonal'));

alter table public.badges
  add constraint badges_trigger_type_check check (trigger_type in ('session', 'cumulative'));

alter table public.badges
  add constraint badges_badge_grade_check check (badge_grade in (
    'bronze', 'silver', 'gold', 'platinum', 'diamond', 'special'
  ));

-- 44종. 정본은 docs/badge-catalog.csv 의 distinct condition_type 이며,
-- 클라이언트 사본은 lib/features/gamification/domain/badge_condition.dart 다.
-- ⚠️ 세 곳을 항상 동시에 고친다.
alter table public.badges
  add constraint badges_condition_type_check check (condition_type in (
    'cumulative_distance_gte',
    'cumulative_count_gte',
    'streak_weeks_gte',
    'pb_first_achieved',
    'pb_time_lte',
    'session_distance_gte',
    'session_duration_gte',
    'session_start_hour_count_gte',
    'weekday_full_week_count_gte',
    'weekend_both_days_count_gte',
    'day_of_week_count_gte',
    'day_of_week_diversity_gte',
    'route_diversity_count_gte',
    'elevation_gain_cumulative_gte',
    'district_diversity_gte',
    'loop_course_count_gte',
    'calendar_date_match',
    'membership_anniversary_run',
    'pace_avg_lte',
    'pace_negative_split_count_gte',
    'pace_final_km_faster_pct_gte',
    'pace_variance_lte',
    'device_source_count_gte',
    'device_source_diversity_gte',
    'level_gte',
    'season_tier_reached',
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
    'consecutive_seasons_participated_gte'
  ));

-- permanent 뱃지에 season_id 가 붙는 건 데이터 오류다. 여기서 막는다.
alter table public.badges
  add constraint badges_season_id_scope check (
    season_id is null or scope = 'seasonal'
  );

-- 판정 배치가 "이번에 볼 뱃지"를 좁히는 접근 경로.
create index if not exists badges_trigger_scope_idx on public.badges (trigger_type, scope);
-- 시즌 인스턴스 조회(현재 시즌 뱃지 목록).
create index if not exists badges_season_id_idx on public.badges (season_id) where season_id is not null;
-- 갤러리 카테고리 그룹핑.
create index if not exists badges_category_idx on public.badges (category);
-- condition 의 표현식 인덱스는 만들지 않는다: 카탈로그는 158행이고 판정은
-- "사용자 1명 × 뱃지 전량" 루프라 어차피 전체 스캔이다. 행 수가 수천으로 늘고
-- 특정 키 조회가 병목으로 확인되면 그때 (condition->>'distanceKm') 인덱스를 검토한다.

comment on table public.badges is
  '뱃지 카탈로그 v2 (158종 / 16카테고리). 정본은 docs/badge-catalog.csv, 스펙은 TRD §3.6. '
  'scope=seasonal 행은 **템플릿**이고 season_id 가 null 이다. 시즌 시작 시 '
  '{templateId}@{seasonId} id 로 인스턴스를 복제 발급한다(후속 작업).';
comment on column public.badges.condition_type is
  '판정 함수 디스패치 키(44종). condition 맵만으로는 어느 판정 함수를 쓸지 알 수 없다.';
comment on column public.badges.condition is
  '판정 함수 입력 파라미터(jsonb). 키 집합은 condition_type 마다 다르다. 파라미터가 없는 종류는 {}.';
comment on column public.badges.badge_grade is
  '표시용 등급. ⚠️ scope=seasonal 의 stier_* 4종을 뺀 나머지는 경쟁 Tier 와 무관한 장식값이다.';
comment on column public.badges.season_id is
  'seasonal **인스턴스**일 때만 값 존재(예: 2026-Q3). 카탈로그 템플릿과 permanent 는 null. '
  'seasons 테이블이 아직 없어 FK 없이 text 로 둔다 — 테이블 생성 시 FK 추가 검토.';

-- -----------------------------------------------------------------------------
-- 25-3. user_badges — verified / revoked
-- -----------------------------------------------------------------------------
alter table public.user_badges
  add column if not exists verified boolean not null default false,
  add column if not exists revoked  boolean not null default false;

comment on column public.user_badges.verified is
  '서버 재검증 통과 여부(TRD §3.6). 기본 false — 미검증 뱃지를 확정 획득으로 표시하지 않는다.';
comment on column public.user_badges.revoked is
  '부정 기록 판정 시 회수(PRD §8.1). 행은 남기고 플래그만 세운다 — 감사 추적 보존.';
comment on column public.user_badges.source_run_id is
  '[서버 전용 감사 컬럼] 이 뱃지를 유발한 러닝. Dart UserBadge 에는 대응 필드가 없고 '
  '(설계문서 §2.7) json_serializable 이 미지 키를 무시하므로 select * 로 내려가도 무해하다. '
  'PRD §8.1 회수 판정 시 "어느 기록 때문에 지급됐나"를 추적하려고 남겼다.';

-- 타인 프로필에서 공개 뱃지만 훑는 경로(RLS 술어와 동일 조건).
create index if not exists user_badges_public_idx
  on public.user_badges (user_id, earned_at desc)
  where revoked = false and verified = true;

-- -----------------------------------------------------------------------------
-- 25-4. 서버 가드 갱신 — verified / revoked 는 클라이언트가 못 건드린다
-- -----------------------------------------------------------------------------
create or replace function public.trg_user_badges_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if not public.is_server_write() then
      -- 클라이언트 INSERT 경로는 RLS 정책 자체가 없어 도달 불가하지만,
      -- 혹시 뚫려도 시각/검증 상태는 서버 값으로 강제한다.
      new.earned_at := now();
      new.verified  := false;
      new.revoked   := false;
    end if;
    return new;
  end if;

  -- UPDATE: 서버 경로가 아니면 is_seen 외 모든 컬럼을 되돌린다.
  if not public.is_server_write() then
    new.id            := old.id;
    new.user_id       := old.user_id;
    new.badge_id      := old.badge_id;
    new.earned_at     := old.earned_at;
    new.source_run_id := old.source_run_id;
    new.verified      := old.verified;   -- v2
    new.revoked       := old.revoked;    -- v2
  end if;
  return new;
end;
$$;

revoke execute on function public.trg_user_badges_guard() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 25-5. RLS (TRD §5)
-- -----------------------------------------------------------------------------

-- badges : 카탈로그는 정적 공개 데이터. anon(게스트) 포함 전체 SELECT.
--          쓰기 정책은 두지 않는다 → service_role(BYPASSRLS)만 쓸 수 있다.
drop policy if exists badges_select_all  on public.badges;
drop policy if exists badges_select_anon on public.badges;

create policy badges_select_all
  on public.badges for select
  to anon, authenticated
  using (true);

-- 정책이 없어도 RLS 가 막지만, 권한 자체를 회수해 오류를 더 이르게 낸다.
revoke insert, update, delete, truncate on public.badges from anon, authenticated;
grant select on public.badges to anon, authenticated;

-- user_badges :
--   본인   → 전량 조회(미검증/회수분 포함. 자기 상태는 자기가 알아야 한다)
--   타인   → revoked=false and verified=true 만 (PRD §8.1/§8.4)
--   INSERT → 정책 없음(service_role 전용). 클라이언트는 뱃지를 확정할 수 없다.
--   UPDATE → is_seen 만. 나머지는 25-4 가드가 되돌린다.
drop policy if exists user_badges_select_own on public.user_badges;
drop policy if exists user_badges_select_public on public.user_badges;

create policy user_badges_select_own
  on public.user_badges for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy user_badges_select_public
  on public.user_badges for select
  to authenticated
  using (
    user_id <> (select auth.uid())
    and revoked = false
    and verified = true
  );

revoke insert, delete, truncate on public.user_badges from anon, authenticated;

-- -----------------------------------------------------------------------------
-- 25-6. v2 판정 디스패치 스텁
-- -----------------------------------------------------------------------------
-- 44종 전체 구현은 후속 라운드. 지금은 시그니처만 못 박아 둔다 —
-- 호출부(evaluate_badges)와 개별 판정 구현을 서로 독립적으로 붙일 수 있게 하려는 것.
--
-- 반환값 규약: true = 조건 충족. **미구현 종류는 false 를 반환한다**(notice 만 남김).
-- 미구현을 true 로 두면 시드 직후 158종이 전원에게 지급된다.
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
begin
  if p_user_id is null or p_condition_type is null then
    return false;
  end if;

  -- TODO(backend): condition_type 별 분기. 우선순위는 카탈로그 빈도 순:
  --   cumulative_distance_gte(14) / pb_time_lte(14) / season_weekly_rank_lte(12) /
  --   cumulative_count_gte(9) / streak_weeks_gte(9) / session_start_hour_count_gte(9) /
  --   level_gte(9) / calendar_date_match(9) …
  -- 분류/파라미터 키는 _workspace/20260825_architect_badge-model-v2.md §4 표.
  --
  -- 선행 의존성(미해결):
  --   level_gte(9종)                  ← GM-04 XP 공식 미정
  --   season_*(20종)                  ← seasons / user_season_tier / weekly_ranking_cache 테이블 미생성
  --   district_diversity_gte(2종)     ← 행정구역 역지오코딩 소스 미정
  --   device_source_diversity_gte(1종)← "watchApple_or_watchGarmin" OR 표현식 파서 규약 미정
  raise notice 'evaluate_badge_condition: % 미구현 (user=%, cond=%)',
    p_condition_type, p_user_id, p_condition;
  return false;
end;
$$;

revoke execute on function public.evaluate_badge_condition(uuid, text, jsonb)
  from public, anon, authenticated;

comment on function public.evaluate_badge_condition(uuid, text, jsonb) is
  '[스텁] 뱃지 조건 판정 디스패처. 44종 전부 미구현 — 항상 false. '
  'ARCHITECTURE §7 순수 함수 규약에 따라 클라이언트 badge_condition.dart 와 동일 규칙으로 구현할 것.';
