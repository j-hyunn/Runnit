-- =============================================================================
-- Runnit :: 09. 뱃지 카탈로그 시드 (29종)
-- -----------------------------------------------------------------------------
-- 출처: _workspace/20260819_210450_badge_catalog_seed.json (gamification-designer v1.0)
--       키 이름이 컬럼명과 1:1 이라 값만 그대로 옮겼다.
--
-- 재실행 가능(idempotent): ON CONFLICT (id) DO UPDATE.
-- ⚠️ points 는 DO UPDATE 대상에서 **의도적으로 제외**한다 (규칙서 §2.4).
--    evaluate_badges 가 뱃지 획득 시 profiles.total_points 에 badges.points 를
--    가산하므로, 이미 지급이 끝난 뱃지의 points 를 나중에 바꾸면 프로필 누적
--    포인트와 카탈로그가 어긋난다. points 조정이 필요하면 별도 정산 배치를 짠다.
--
-- social 카테고리는 의도적으로 0종이다 (crews 테이블 미정의 — 규칙서 §1.3).
-- 아이콘 에셋 assets/badges/*.png 29개는 flutter-ui-designer 미작업 (규칙서 B4).
-- =============================================================================

insert into public.badges
  (id, name, description, category, tier, icon_asset,
   criteria_type, threshold, points, sort_order, is_secret, is_active)
values
  -- ── special : 횟수/누적 시간 계열 ──────────────────────────────────────────
  ('first_run', '첫 발걸음', '첫 러닝을 완주했습니다. 시작이 절반입니다.',
   'special', 'bronze', 'assets/badges/first_run.png',
   'run_count', 1, 50, 100, false, true),

  ('runs_10', '열 번의 출발', '러닝 10회를 완주했습니다.',
   'special', 'bronze', 'assets/badges/runs_10.png',
   'run_count', 10, 80, 101, false, true),

  ('runs_50', '습관의 증명', '러닝 50회를 완주했습니다.',
   'special', 'silver', 'assets/badges/runs_50.png',
   'run_count', 50, 200, 102, false, true),

  ('runs_200', '이백 번의 길', '러닝 200회를 완주했습니다.',
   'special', 'gold', 'assets/badges/runs_200.png',
   'run_count', 200, 700, 103, false, true),

  ('time_100h', '100시간의 기록', '누적 이동 시간 100시간을 넘겼습니다.',
   'special', 'gold', 'assets/badges/time_100h.png',
   'total_moving_seconds', 360000, 600, 110, false, true),

  ('early_bird_10', '아침형 러너', '오전 5시~7시(KST)에 시작한 러닝을 10회 완주했습니다.',
   'special', 'silver', 'assets/badges/early_bird_10.png',
   'early_run_count', 10, 200, 120, true, true),

  ('night_owl_10', '야행성 러너', '밤 21시~새벽 4시(KST)에 시작한 러닝을 10회 완주했습니다.',
   'special', 'silver', 'assets/badges/night_owl_10.png',
   'night_run_count', 10, 200, 121, true, true),

  -- ── distance : 단일 러닝 ──────────────────────────────────────────────────
  ('single_5k', '5K 러너', '한 번의 러닝에서 5km를 달렸습니다.',
   'distance', 'bronze', 'assets/badges/single_5k.png',
   'single_run_distance_m', 5000, 60, 200, false, true),

  ('single_10k', '10K 러너', '한 번의 러닝에서 10km를 달렸습니다.',
   'distance', 'silver', 'assets/badges/single_10k.png',
   'single_run_distance_m', 10000, 120, 201, false, true),

  ('single_half_marathon', '하프 마라토너', '한 번의 러닝에서 하프마라톤(21.0975km)을 완주했습니다.',
   'distance', 'gold', 'assets/badges/single_half_marathon.png',
   'single_run_distance_m', 21097.5, 300, 202, false, true),

  ('single_marathon', '마라토너', '한 번의 러닝에서 풀마라톤(42.195km)을 완주했습니다.',
   'distance', 'platinum', 'assets/badges/single_marathon.png',
   'single_run_distance_m', 42195, 800, 203, false, true),

  -- ── distance : 누적 ───────────────────────────────────────────────────────
  ('total_50km', '50km 클럽', '누적 50km를 달렸습니다.',
   'distance', 'bronze', 'assets/badges/total_50km.png',
   'total_distance_m', 50000, 80, 210, false, true),

  ('total_250km', '250km 클럽', '누적 250km를 달렸습니다.',
   'distance', 'silver', 'assets/badges/total_250km.png',
   'total_distance_m', 250000, 200, 211, false, true),

  ('total_1000km', '1000km 클럽', '누적 1,000km를 달렸습니다. 서울–부산 왕복보다 먼 거리입니다.',
   'distance', 'gold', 'assets/badges/total_1000km.png',
   'total_distance_m', 1000000, 600, 212, false, true),

  ('total_5000km', '5000km 클럽', '누적 5,000km를 달렸습니다.',
   'distance', 'platinum', 'assets/badges/total_5000km.png',
   'total_distance_m', 5000000, 2000, 213, false, true),

  -- ── streak ────────────────────────────────────────────────────────────────
  ('streak_3', '3일 연속', '3일 연속으로 러닝했습니다.',
   'streak', 'bronze', 'assets/badges/streak_3.png',
   'streak_days', 3, 60, 300, false, true),

  ('streak_7', '일주일 개근', '7일 연속으로 러닝했습니다.',
   'streak', 'silver', 'assets/badges/streak_7.png',
   'streak_days', 7, 150, 301, false, true),

  ('streak_30', '한 달 개근', '30일 연속으로 러닝했습니다.',
   'streak', 'gold', 'assets/badges/streak_30.png',
   'streak_days', 30, 700, 302, false, true),

  ('streak_100', '백일의 약속', '100일 연속으로 러닝했습니다.',
   'streak', 'platinum', 'assets/badges/streak_100.png',
   'streak_days', 100, 2500, 303, false, true),

  -- ── pace : 비교 방향이 <= 인 유일한 계열 ──────────────────────────────────
  ('pace_sub7_5k', '5K 서브7', '5km 이상 러닝에서 평균 페이스 7''00"/km 이내를 기록했습니다.',
   'pace', 'bronze', 'assets/badges/pace_sub7_5k.png',
   'pace_sec_per_km_below_5k', 420, 80, 400, false, true),

  ('pace_sub6_5k', '5K 서브6', '5km 이상 러닝에서 평균 페이스 6''00"/km 이내를 기록했습니다.',
   'pace', 'silver', 'assets/badges/pace_sub6_5k.png',
   'pace_sec_per_km_below_5k', 360, 180, 401, false, true),

  ('pace_sub5_10k', '10K 서브5', '10km 이상 러닝에서 평균 페이스 5''00"/km 이내를 기록했습니다.',
   'pace', 'gold', 'assets/badges/pace_sub5_10k.png',
   'pace_sec_per_km_below_10k', 300, 500, 402, false, true),

  ('pace_sub430_10k', '10K 서브4:30', '10km 이상 러닝에서 평균 페이스 4''30"/km 이내를 기록했습니다.',
   'pace', 'platinum', 'assets/badges/pace_sub430_10k.png',
   'pace_sec_per_km_below_10k', 270, 1200, 403, false, true),

  -- ── elevation ─────────────────────────────────────────────────────────────
  ('elev_single_300', '언덕 정복자', '한 번의 러닝에서 누적 상승 300m를 기록했습니다.',
   'elevation', 'bronze', 'assets/badges/elev_single_300.png',
   'single_run_elevation_gain_m', 300, 100, 500, false, true),

  ('elev_single_1000', '산악 러너', '한 번의 러닝에서 누적 상승 1,000m를 기록했습니다.',
   'elevation', 'silver', 'assets/badges/elev_single_1000.png',
   'single_run_elevation_gain_m', 1000, 300, 501, false, true),

  ('elev_everest', '에베레스트 클럽', '누적 상승 고도 8,848m — 에베레스트 높이만큼 올랐습니다.',
   'elevation', 'gold', 'assets/badges/elev_everest.png',
   'total_elevation_gain_m', 8848, 700, 502, false, true),

  -- ── challenge ─────────────────────────────────────────────────────────────
  ('challenge_first', '첫 챌린지', '챌린지를 처음으로 완주했습니다.',
   'challenge', 'bronze', 'assets/badges/challenge_first.png',
   'challenge_completed_count', 1, 100, 600, false, true),

  ('challenge_5', '챌린지 헌터', '챌린지 5개를 완주했습니다.',
   'challenge', 'silver', 'assets/badges/challenge_5.png',
   'challenge_completed_count', 5, 350, 601, false, true),

  ('challenge_20', '챌린지 마스터', '챌린지 20개를 완주했습니다.',
   'challenge', 'gold', 'assets/badges/challenge_20.png',
   'challenge_completed_count', 20, 1200, 602, false, true)

on conflict (id) do update set
  name          = excluded.name,
  description   = excluded.description,
  category      = excluded.category,
  tier          = excluded.tier,
  icon_asset    = excluded.icon_asset,
  criteria_type = excluded.criteria_type,
  threshold     = excluded.threshold,
  sort_order    = excluded.sort_order,
  is_secret     = excluded.is_secret,
  is_active     = excluded.is_active;
  -- points 는 갱신하지 않는다 (위 주석 참조).
