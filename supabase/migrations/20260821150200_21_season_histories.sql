-- =============================================================================
-- Runnit :: 21. season_histories — 역대 시즌 기록 (PRD HI-06 / TI-06)
-- -----------------------------------------------------------------------------
-- 근거: architect 문서 §5 표. Dart 모델은 lib/models/season_history.dart.
-- 컬럼명은 FieldRename.snake 변환 결과와 정확히 동일하다(별칭 금지).
--
-- 불변 규칙
--   - 유저당 시즌당 정확히 1행 (UNIQUE (user_id, season_id)) — 중복 마감 방지.
--   - **끝난 시즌만** 들어간다. 진행 중 시즌 상태는 profiles.current_tier /
--     season_distance_meters 가 들고 있다(두 곳에 쓰면 진실이 모호해진다).
--   - 마감 이후에는 수정하지 않는다. 사후 부정 판정은 행 삭제가 아니라
--     is_voided 를 세운다(§8.4 이의 제기 대응 근거 보존).
--   - start_at / end_at 은 컬럼이 아니다 — season_id 에서 파생되는 Dart getter.
-- =============================================================================

create table public.season_histories (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles (id) on delete cascade,

  season_id        text        not null,
  final_tier       public.tier not null,

  -- 아래 3개는 전부 "검증 통과 + 실외" 필터로 집계된 값이다(§8.3).
  distance_meters  double precision not null default 0,
  run_count        integer          not null default 0,
  moving_seconds   integer          not null default 0,

  best_weekly_rank integer,
  closed_at        timestamptz not null default now(),
  is_voided        boolean     not null default false,

  constraint season_histories_user_season_uniq unique (user_id, season_id),
  constraint season_histories_season_id_format check (season_id ~ '^\d{4}-Q[1-4]$'),
  constraint season_histories_distance_nonneg  check (distance_meters >= 0),
  constraint season_histories_run_count_nonneg check (run_count >= 0),
  constraint season_histories_moving_nonneg    check (moving_seconds >= 0),
  constraint season_histories_rank_positive    check (best_weekly_rank is null or best_weekly_rank >= 1)
);

-- 프로필 화면: "내 역대 시즌" 최신순. UNIQUE 인덱스는 (user_id, season_id) 오름차순이라
-- desc 정렬을 그대로 커버하지 못하므로 별도로 둔다.
create index season_histories_user_season_desc_idx
  on public.season_histories (user_id, season_id desc);

comment on table public.season_histories is
  'Dart SeasonHistory. 시즌 마감 스냅샷 — 끝난 시즌만 1행씩. 클라이언트 write 전면 금지.';
comment on column public.season_histories.distance_meters is
  '마감 시점 profiles.season_distance_meters 스냅샷. 검증 통과 + 실외(activity_type <> ''indoor_run'')만.';
comment on column public.season_histories.is_voided is
  '사후 부정 판정 무효화(§8.1). 행은 남기고 표시만 지운다 — 삭제하면 이의 제기 대응 근거가 사라진다.';

-- -----------------------------------------------------------------------------
-- RLS : 조회만. INSERT/UPDATE/DELETE 정책 없음 = 클라이언트 write 전면 금지.
--       (마감은 security definer 함수 / service_role 경로로만 일어난다.)
-- -----------------------------------------------------------------------------
alter table public.season_histories enable row level security;

-- profiles 가 이미 전체 공개 조회(profiles_select_all)이므로 시즌 기록도 공개다
-- (TI-09 "역대 최고 티어 프로필 표시"의 전제). 단 **무효화된 행은 본인에게만** 보인다 —
-- 남의 무효 기록을 굳이 노출할 이유가 없고, 본인은 이의 제기를 위해 봐야 한다.
create policy season_histories_select_visible
  on public.season_histories for select
  to authenticated
  using (is_voided = false or user_id = (select auth.uid()));

-- 익명(게스트) 롤에는 열지 않는다 — 17 파일의 공개 범위(badges + global 랭킹)를 유지한다.
revoke all on public.season_histories from anon;
