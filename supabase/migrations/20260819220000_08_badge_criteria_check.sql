-- =============================================================================
-- Runnit :: 08. badges.criteria_type 값 집합 확정 (CHECK 제약)
-- -----------------------------------------------------------------------------
-- 근거: _workspace/20260819_210450_badge_rules.md §1.1 — "이 12개가 전부다".
-- 02_gamification.sql 은 gamification-designer 확정 전이라 자유 text 로 두었다.
-- 이미 적용된 마이그레이션 파일은 수정하지 않고, 여기서 증분으로 제약을 건다.
--
-- 값 추가는 gamification-designer 승인 후 새 마이그레이션으로만.
-- (크루 기능 착수 시 crew_member_days 등 신규 값이 여기에 추가된다 — 규칙서 §1.3)
-- =============================================================================

alter table public.badges
  add constraint badges_criteria_type_check
  check (criteria_type in (
    'run_count',                    -- profiles.total_run_count          (>=)
    'single_run_distance_m',        -- max(runs.distance_meters)         (>=)
    'total_distance_m',             -- profiles.total_distance_meters    (>=)
    'total_moving_seconds',         -- profiles.total_moving_seconds     (>=)
    'streak_days',                  -- profiles.longest_streak_days      (>=)
    'pace_sec_per_km_below_5k',     -- min pace over >=5km runs          (<=)
    'pace_sec_per_km_below_10k',    -- min pace over >=10km runs         (<=)
    'single_run_elevation_gain_m',  -- max(runs.elevation_gain_meters)   (>=)
    'total_elevation_gain_m',       -- sum(runs.elevation_gain_meters)   (>=)
    'early_run_count',              -- KST 05:00~06:59 시작 러닝 수      (>=)
    'night_run_count',              -- KST 21:00~03:59 시작 러닝 수      (>=)
    'challenge_completed_count'     -- 완주 챌린지 수                    (>=)
  ));

comment on column public.badges.criteria_type is
  '판정 지표 키. 확정 12종(badge_rules §1.1). pace_sec_per_km_below% 만 비교 방향이 <= 이며, '
  '나머지는 >=. 판정은 public.evaluate_badges() 가 유일한 정본이다.';

comment on table public.badges is
  '뱃지 카탈로그 마스터. 시드는 09_badge_seed.sql. 뱃지 폐기는 DELETE 가 아니라 is_active=false 로 한다.';
