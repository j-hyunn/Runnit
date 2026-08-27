-- =============================================================================
-- Runnit :: 37. district_diversity_gte 삭제 마무리 (route_district_3 / _10)
-- -----------------------------------------------------------------------------
-- 정본: _workspace/20260826_000340_gamification_badge-backlog-decisions.md §7
--       docs/badge-catalog.csv (이미 82·83행 삭제됨) · docs/TRD.md §10.1
--
-- §7.2 부수 영향 전수 확인 결과 "없음":
--   · 지급된 user_badges 0건 (판정이 계속 false 스텁이었다) — 아래에서 방어적으로 먼저 삭제
--   · 카테고리 공동화 없음 — route_exploration 은 9종 → 7종으로 줄 뿐 유지된다.
--     마이그레이션 35(카테고리 통째 삭제)와 달리 **category enum/CHECK 삭제는 불필요**
--   · 뱃지 간 의존 관계 없음, 진행률 계산은 총 개수를 하드코딩하지 않음
--   · 역지오코딩(PostGIS·법정동 경계·외부 API) 의존이 통째로 소멸 — 다른 뱃지 중 사용처 없음
--
-- 결과 규모: 템플릿 148 → **146**, distinct condition_type 40 → **39**.
-- 멱등: DELETE 는 재실행 안전, CHECK 는 drop-if-exists 후 재생성.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 37-1. 지급 이력 → 뱃지 행 순서로 삭제 (FK 순서)
-- -----------------------------------------------------------------------------
delete from public.user_badges
 where badge_id in ('route_district_3', 'route_district_10');

delete from public.badges
 where id in ('route_district_3', 'route_district_10');

-- -----------------------------------------------------------------------------
-- 37-2. condition_type CHECK 재정의 — 44종 → 39종
-- -----------------------------------------------------------------------------
-- 마이그레이션 25 가 정의한 목록에서 이번 district 1종과, 마이그레이션 35 에서
-- 뱃지는 지웠지만 CHECK 목록에는 남아 있던 시즌 4종
-- (season_cumulative_distance_gte / consecutive_seasons_participated_gte /
--  season_first_and_last_week_active / season_final_week_active) 을 함께 제거한다.
-- 44 − 4 − 1 = 39 로, docs/TRD.md §4.1·§10.1 의 "39종" 서술과 일치하게 된다.
alter table public.badges drop constraint if exists badges_condition_type_check;

alter table public.badges add constraint badges_condition_type_check check (
  condition_type = any (array[
    -- 누적 / 세션
    'cumulative_distance_gte',
    'cumulative_count_gte',
    'session_distance_gte',
    'session_duration_gte',
    -- 스트릭
    'streak_weeks_gte',
    -- PB
    'pb_first_achieved',
    'pb_time_lte',
    -- 시간대 / 요일
    'session_start_hour_count_gte',
    'weekday_full_week_count_gte',
    'weekend_both_days_count_gte',
    'day_of_week_count_gte',
    'day_of_week_diversity_gte',
    -- 경로 탐험 (district_diversity_gte 제거됨 — 37번)
    'route_diversity_count_gte',
    'elevation_gain_cumulative_gte',
    'loop_course_count_gte',
    -- 특별한 날
    'calendar_date_match',
    'membership_anniversary_run',
    -- 페이스
    'pace_avg_lte',
    'pace_negative_split_count_gte',
    'pace_final_km_faster_pct_gte',
    'pace_variance_lte',
    -- 기기 연동
    'device_source_count_gte',
    'device_source_diversity_gte',
    -- 레벨
    'level_gte',
    -- 시즌 (season_cumulative_distance_gte / consecutive_seasons_participated_gte /
    --       season_first_and_last_week_active / season_final_week_active 는 35번에서 삭제됨)
    'season_tier_reached',
    'season_weekly_rank_lte',
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
    'season_streak_weeks_gte'
  ])
);

-- -----------------------------------------------------------------------------
-- 37-3. category CHECK 재정의 — 16종 → 14종
-- -----------------------------------------------------------------------------
-- 마이그레이션 35 가 season_cumulative_distance / season_finisher 카테고리의
-- 뱃지를 전부 지웠으나 CHECK 목록은 그대로였다. 데이터와 제약을 일치시킨다.
-- (docs/TRD.md §4.1 "text (enum check, 14종)")
alter table public.badges drop constraint if exists badges_category_check;

alter table public.badges add constraint badges_category_check check (
  category = any (array[
    'cumulative_distance',
    'cumulative_count',
    'longest_streak',
    'personal_best',
    'single_session_distance',
    'time_of_day_weekday',
    'route_exploration',
    'special_day',
    'pace_speed',
    'device_integration',
    'level',
    'season_tier',
    'season_weekly_rank',
    'season_event'
  ])
);

-- -----------------------------------------------------------------------------
-- 37-4. season_weekly_rank_lte 조건 도메인 CHECK 신설
-- -----------------------------------------------------------------------------
-- 정본 §2.1: bucket ∈ {top1, top10, top10pct} 정확히 3종, tier 는 public.tier 4종.
-- "backend는 CHECK 제약으로 이 두 도메인을 강제할 것" — 오타 하나로 뱃지가 조용히
-- 미지급되는 것을 시드 단계에서 막는다.
alter table public.badges drop constraint if exists badges_season_weekly_rank_domain;

alter table public.badges add constraint badges_season_weekly_rank_domain check (
  condition_type <> 'season_weekly_rank_lte'
  or (
    (condition ->> 'tier')   = any (array['bronze', 'silver', 'gold', 'platinum'])
    and (condition ->> 'bucket') = any (array['top1', 'top10', 'top10pct'])
  )
);
