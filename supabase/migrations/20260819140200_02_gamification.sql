-- =============================================================================
-- Runnit :: 02. 게이미피케이션 (badges / user_badges / challenges / participations)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- badges  <-> Dart Badge (마스터 데이터, 사실상 읽기 전용)
-- id 는 UUID 가 아니라 사람이 읽는 슬러그다(예: distance_10k).
-- -----------------------------------------------------------------------------
create table public.badges (
  id            text primary key,
  name          text not null,
  description   text not null,
  category      public.badge_category not null,
  tier          public.badge_tier     not null,
  icon_asset    text not null,

  -- 판정 지표 키. 접미사에 단위가 내장된다:
  --   single_run_distance_m / total_distance_m / streak_days /
  --   pace_sec_per_km_below / elevation_gain_m / run_count
  -- 최종 목록은 gamification-designer 확정 대기 -> 지금은 자유 text 로 둔다.
  criteria_type text not null,
  threshold     double precision not null,

  points        integer not null default 0,
  sort_order    integer not null default 0,
  is_secret     boolean not null default false,
  is_active     boolean not null default true,

  constraint badges_id_slug_format check (id ~ '^[a-z0-9_]{3,64}$'),
  constraint badges_points_nonneg  check (points >= 0)
);

create index badges_active_sort_idx on public.badges (is_active, sort_order);

comment on table public.badges is
  '뱃지 카탈로그. 시드 데이터는 gamification-designer 확정 후 별도 마이그레이션으로 추가.';

-- -----------------------------------------------------------------------------
-- user_badges  <-> Dart UserBadge
-- Dart 의 `badge` 필드는 DB 컬럼이 아니라 PostgREST 임베드 결과다:
--   .select('*, badge:badges(*)')   <- 임베드 별칭은 컬럼 별칭이 아니므로 허용된다.
-- -----------------------------------------------------------------------------
create table public.user_badges (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  badge_id      text not null references public.badges (id)   on delete cascade,

  -- 서버 시각으로만 확정(클라이언트 시각 조작 방지). 04_server_guards 가 강제.
  earned_at     timestamptz not null default now(),

  source_run_id uuid references public.runs (id) on delete set null,
  is_seen       boolean not null default false,

  constraint user_badges_unique unique (user_id, badge_id)
);

create index user_badges_user_earned_idx on public.user_badges (user_id, earned_at desc);
create index user_badges_unseen_idx      on public.user_badges (user_id) where is_seen = false;
create index user_badges_badge_id_idx    on public.user_badges (badge_id);
create index user_badges_source_run_idx  on public.user_badges (source_run_id) where source_run_id is not null;

-- -----------------------------------------------------------------------------
-- challenges  <-> Dart Challenge
-- -----------------------------------------------------------------------------
create table public.challenges (
  id                uuid primary key default gen_random_uuid(),
  title             text not null,
  description       text not null,
  type              public.challenge_type   not null,
  status            public.challenge_status not null default 'upcoming',

  -- 단위는 type 종속: 거리형 -> m, run_count -> 회, streak_days -> 일
  target_value      double precision not null,

  start_at          timestamptz not null,
  end_at            timestamptz not null,

  banner_image_url  text,
  reward_badge_id   text references public.badges (id) on delete set null,
  reward_points     integer not null default 0,
  crew_id           uuid,                       -- null = 전체 공개

  participant_count integer not null default 0, -- 서버 캐시
  created_at        timestamptz not null default now(),

  constraint challenges_period_order check (end_at > start_at),
  constraint challenges_target_positive check (target_value > 0),
  constraint challenges_reward_nonneg check (reward_points >= 0)
);

create index challenges_status_start_idx on public.challenges (status, start_at desc);
create index challenges_crew_idx on public.challenges (crew_id) where crew_id is not null;
create index challenges_reward_badge_idx on public.challenges (reward_badge_id) where reward_badge_id is not null;

-- -----------------------------------------------------------------------------
-- challenge_participations  <-> Dart ChallengeParticipation
-- Dart 의 `challenge` 필드도 임베드 결과다: .select('*, challenge:challenges(*)')
-- -----------------------------------------------------------------------------
create table public.challenge_participations (
  id             uuid primary key default gen_random_uuid(),
  challenge_id   uuid not null references public.challenges (id) on delete cascade,
  user_id        uuid not null references public.profiles (id)   on delete cascade,

  joined_at      timestamptz not null default now(),

  -- 서버 갱신 전용
  progress_value double precision not null default 0,
  completed_at   timestamptz,
  rank           integer,

  constraint challenge_participations_unique unique (challenge_id, user_id),
  constraint challenge_participations_progress_nonneg check (progress_value >= 0)
);

create index challenge_participations_user_idx      on public.challenge_participations (user_id);
create index challenge_participations_challenge_idx on public.challenge_participations (challenge_id, progress_value desc);
