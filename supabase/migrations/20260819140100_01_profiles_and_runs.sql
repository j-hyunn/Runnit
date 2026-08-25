-- =============================================================================
-- Runnit :: 01. profiles / runs 코어 테이블
-- -----------------------------------------------------------------------------
-- 컬럼명 규칙: Dart camelCase 필드 -> FieldRename.snake 변환 결과와 **정확히 동일**.
--   distanceMeters -> distance_meters, avgPaceSecPerKm -> avg_pace_sec_per_km ...
--   쿼리에서 `as` 별칭 사용 금지(fromJson 이 깨진다).
-- 단위: 거리=m, 시간=s, 페이스=s/km, 속도=m/s, 시각=UTC timestamptz.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- profiles  <-> Dart AppUser (lib/models/app_user.dart)
-- -----------------------------------------------------------------------------
create table public.profiles (
  id                    uuid primary key references auth.users (id) on delete cascade,

  username              text not null,
  display_name          text,
  avatar_url            text,
  bio                   text,

  -- crews 테이블은 v1.1 예정(계약서 §3). 확정 전까지 FK 없이 nullable uuid 로만 둔다.
  crew_id               uuid,

  height_cm             double precision,
  weight_kg             double precision,
  birth_date            timestamptz,          -- 계약: UTC 자정. date 가 아니라 timestamptz
  gender                public.gender,

  preferred_unit        public.distance_unit not null default 'metric',

  -- ── 서버 전용 쓰기(클라이언트 읽기 전용). 04_server_guards 트리거가 강제한다 ──
  total_distance_meters double precision not null default 0,
  total_moving_seconds  integer          not null default 0,
  total_run_count       integer          not null default 0,
  total_points          integer          not null default 0,
  level                 integer          not null default 1,
  current_streak_days   integer          not null default 0,
  longest_streak_days   integer          not null default 0,
  last_run_at           timestamptz,

  created_at            timestamptz not null default now(),
  updated_at            timestamptz,

  constraint profiles_username_key unique (username),
  constraint profiles_username_format check (username ~ '^[a-zA-Z0-9._-]{2,30}$'),
  constraint profiles_height_range check (height_cm is null or height_cm between 50 and 260),
  constraint profiles_weight_range check (weight_kg is null or weight_kg between 20 and 400),
  constraint profiles_level_positive check (level >= 1)
);

-- 대소문자만 다른 핸들 중복 방지 (username 자체 UNIQUE 와 별개)
create unique index profiles_username_lower_idx on public.profiles (lower(username));
create index profiles_crew_id_idx on public.profiles (crew_id) where crew_id is not null;

comment on table public.profiles is
  'Dart AppUser. id = auth.users.id. total_* / level / *_streak_days / last_run_at 는 서버 전용 쓰기 캐시.';

-- -----------------------------------------------------------------------------
-- runs  <-> Dart RunRecord (lib/models/run_record.dart)
-- -----------------------------------------------------------------------------
-- id 는 **클라이언트가 생성한 UUID v4** 를 그대로 PK 로 수용한다(오프라인 멱등성).
-- default gen_random_uuid() 는 서버측 생성 경로를 위한 폴백일 뿐이다.
--
-- samples: jsonb 단일 컬럼 (리더 확정사항).
--   1시간 러닝 ≈ 3,600 샘플 -> 압축 전 대략 500KB~1MB.
--   Postgres 는 2KB 초과 행을 TOAST 로 분리 저장하므로 samples 는 사실상 항상
--   out-of-line + LZ 압축 저장된다. 즉 **SELECT 목록에서 samples 를 빼면
--   TOAST 청크를 아예 읽지 않는다** -> 목록 조회 비용은 samples 크기와 무관.
--   반대로 select('*') 를 쓰면 목록 1페이지에 수십 MB 가 실린다. 절대 금지.
--   -> public.run_summaries 뷰 또는 명시적 컬럼 목록을 사용할 것(03 파일 및 문서 참조).
-- -----------------------------------------------------------------------------
create table public.runs (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.profiles (id) on delete cascade,

  started_at              timestamptz not null,
  ended_at                timestamptz,

  activity_type           public.activity_type not null,
  status                  public.run_status    not null,

  distance_meters         double precision not null default 0,
  elapsed_seconds         integer          not null default 0,
  moving_seconds          integer          not null default 0,

  avg_pace_sec_per_km     double precision,
  max_speed_mps           double precision,
  elevation_gain_meters   double precision,
  elevation_loss_meters   double precision,
  avg_heart_rate_bpm      integer,
  max_heart_rate_bpm      integer,
  calories_kcal           integer,
  avg_cadence_spm         integer,

  samples                 jsonb not null default '[]'::jsonb,
  route_polyline          text,

  title                   text,
  note                    text,

  -- List<RunSampleSource> -> Postgres enum 배열. PostgREST 는 JSON 배열로 직렬화한다.
  sources                 public.run_sample_source[] not null default '{}',

  -- 서버 확정값. 클라이언트가 보낸 값은 무시된다(04_server_guards).
  awarded_points          integer,

  created_at              timestamptz not null default now(),
  updated_at              timestamptz,

  -- ── 모델에 없는 서버 전용 컬럼 (부정행위/이상치 플래그) ───────────────────
  -- json_serializable 은 인식하지 못한 키를 무시하므로 fromJson 을 깨지 않는다.
  -- 삭제하지 않고 플래그만 남긴다(오탐 시 근거 데이터 보존).
  is_flagged              boolean not null default false,
  flag_reason             text,

  constraint runs_distance_nonneg      check (distance_meters >= 0),
  constraint runs_elapsed_nonneg       check (elapsed_seconds >= 0),
  constraint runs_moving_nonneg        check (moving_seconds >= 0),
  constraint runs_samples_is_array     check (jsonb_typeof(samples) = 'array'),
  constraint runs_time_order           check (ended_at is null or ended_at >= started_at)
);

comment on column public.runs.samples is
  'List<RunSample> 원본. TOAST 저장. 목록 조회에서 절대 SELECT 하지 말 것.';
comment on column public.runs.is_flagged is
  '서버 재검증 이상치 플래그. 모델에 없는 서버 전용 컬럼. 랭킹/통계 집계에서 제외된다.';

-- ── 인덱스 ──────────────────────────────────────────────────────────────────
-- (1) 히스토리 목록: where user_id = ? order by started_at desc  (계약서 §2.2 권장)
create index runs_user_started_idx on public.runs (user_id, started_at desc);

-- (2) 랭킹/통계 집계: 정상 완료 기록만 스캔하는 부분 인덱스.
--     기간 필터(started_at 범위) + 사용자 그룹핑을 한 인덱스로 커버한다.
create index runs_completed_period_idx
  on public.runs (started_at, user_id)
  where status = 'completed' and is_flagged = false;

-- (3) 사용자별 집계 재계산(recompute_profile_stats)용.
create index runs_user_completed_idx
  on public.runs (user_id, ended_at)
  where status = 'completed' and is_flagged = false;

-- -----------------------------------------------------------------------------
-- run_summaries : samples 를 제외한 목록 조회 전용 뷰
-- -----------------------------------------------------------------------------
-- security_invoker = true -> 조회자의 권한/RLS 로 평가된다(뷰가 RLS 우회구멍이 되지 않도록).
-- samples 키가 없으면 RunRecord.fromJson 은 @Default(<RunSample>[]) 로 빈 배열을 채운다.
create view public.run_summaries with (security_invoker = true) as
select
  r.id, r.user_id, r.started_at, r.ended_at, r.activity_type, r.status,
  r.distance_meters, r.elapsed_seconds, r.moving_seconds, r.avg_pace_sec_per_km,
  r.max_speed_mps, r.elevation_gain_meters, r.elevation_loss_meters,
  r.avg_heart_rate_bpm, r.max_heart_rate_bpm, r.calories_kcal, r.avg_cadence_spm,
  r.route_polyline, r.title, r.note, r.sources, r.awarded_points,
  r.created_at, r.updated_at
from public.runs r;

comment on view public.run_summaries is
  'runs 에서 samples 만 제외한 목록 조회용 뷰. RunRecord.fromJson 과 호환(samples 는 기본값 []).';
