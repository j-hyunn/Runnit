-- =============================================================================
-- Runnit :: 19. 경쟁 티어 enum + profiles 티어 컬럼 3종
-- -----------------------------------------------------------------------------
-- 근거: _workspace/20260821_144047_tier_system_architecture.md §1, §3
--       PRD §5.3(티어 기준선), §8.1(판정 규칙)
--
-- public.tier 는 기존 public.badge_tier 와 **라벨이 같지만 별개 타입**이다.
--   - badge_tier : 뱃지 카탈로그의 희소도 속성
--   - tier       : 사용자 프로필의 시즌 경쟁 등급 (시즌마다 리셋)
-- 통합하면 뱃지 희소도 체계를 바꾸는 순간 경쟁 티어가 딸려 움직인다.
-- =============================================================================

create type public.tier as enum ('bronze', 'silver', 'gold', 'platinum');

comment on type public.tier is
  '시즌 경쟁 티어(PRD §5.3). badge_tier(뱃지 희소도)와 라벨이 같지만 의미가 다른 별개 타입.';

-- -----------------------------------------------------------------------------
-- 티어 기준선 판정 — Dart TierX.fromSeasonDistanceMeters() 와 동일 규약
-- -----------------------------------------------------------------------------
-- 기준선(m): bronze 0 / silver 25,000 / gold 100,000 / platinum 250,000.
-- 경계값은 **이상(>=)** 에서 승급한다 (24999 -> bronze, 25000 -> silver).
create or replace function public.tier_for_distance(p_meters double precision)
returns public.tier
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when coalesce(p_meters, 0) >= 250000 then 'platinum'::public.tier
    when coalesce(p_meters, 0) >= 100000 then 'gold'::public.tier
    when coalesce(p_meters, 0) >=  25000 then 'silver'::public.tier
    else 'bronze'::public.tier
  end;
$$;

-- -----------------------------------------------------------------------------
-- profiles 티어 필드 3종 (architect 문서 §3 표 그대로)
-- -----------------------------------------------------------------------------
-- Dart AppUser: currentTier / seasonDistanceMeters / tierSeasonId
--   -> FieldRename.snake 변환 결과와 정확히 동일한 컬럼명. 별칭 금지.
alter table public.profiles
  add column current_tier           public.tier      not null default 'bronze',
  add column season_distance_meters double precision not null default 0,
  add column tier_season_id         text;

alter table public.profiles
  add constraint profiles_tier_season_id_format
    check (tier_season_id is null or tier_season_id ~ '^\d{4}-Q[1-4]$');

comment on column public.profiles.season_distance_meters is
  '현재 시즌 누적 거리(m). **티어 판정 기준값.** total_distance_meters 와 달리 '
  'activity_type <> ''indoor_run'' 만 합산한다(PRD §8.3: 트레드밀은 누적 통계에는 들어가되 '
  '티어/랭킹에는 들어가지 않는다). 서버 전용 쓰기.';
comment on column public.profiles.current_tier is
  '현재 시즌 경쟁 티어. 서버가 단일 진실 원천(PRD §6) — 클라이언트 계산값으로 덮어쓰기 금지.';
comment on column public.profiles.tier_season_id is
  'season_distance_meters/current_tier 가 어느 시즌 기준인지. ''2026-Q3'' 형식. '
  '현재 시즌과 다르면 시즌 리셋이 필요하다는 신호(멱등 지연 복구의 기준점).';

-- -----------------------------------------------------------------------------
-- 05_server_guards 의 서버 전용 컬럼 가드에 3개 등록
-- -----------------------------------------------------------------------------
-- 클라이언트가 AppUser.toJson() 을 통째로 upsert 해도 세 컬럼은 조용히 서버 값으로
-- 되돌린다(05 파일의 "EXCEPTION 이 아니라 덮어쓰기" 원칙 유지).
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
      new.total_distance_meters := 0;
      new.total_moving_seconds  := 0;
      new.total_run_count       := 0;
      new.total_points          := 0;
      new.level                 := 1;
      new.current_streak_days   := 0;
      new.longest_streak_days   := 0;
      new.last_run_at           := null;
      -- 19: 티어 3종
      new.current_tier           := 'bronze';
      new.season_distance_meters := 0;
      new.tier_season_id         := null;
    end if;
    return new;
  end if;

  -- UPDATE
  new.id         := old.id;            -- PK 변조 차단
  new.created_at := old.created_at;
  new.updated_at := now();

  if not public.is_server_write() then
    new.total_distance_meters := old.total_distance_meters;
    new.total_moving_seconds  := old.total_moving_seconds;
    new.total_run_count       := old.total_run_count;
    new.total_points          := old.total_points;
    new.level                 := old.level;
    new.current_streak_days   := old.current_streak_days;
    new.longest_streak_days   := old.longest_streak_days;
    new.last_run_at           := old.last_run_at;
    new.crew_id               := old.crew_id;
    -- 19: 티어 3종
    new.current_tier           := old.current_tier;
    new.season_distance_meters := old.season_distance_meters;
    new.tier_season_id         := old.tier_season_id;
  end if;

  return new;
end;
$$;

-- 14/15 와 동일: 트리거 함수를 재정의하면 기본 EXECUTE 권한이 다시 붙으므로 회수한다.
revoke execute on function public.trg_profiles_guard() from public, anon, authenticated;
