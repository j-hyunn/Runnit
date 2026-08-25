-- =============================================================================
-- Runnit :: 26. 뱃지 카탈로그 v2 시드 (158종)
-- -----------------------------------------------------------------------------
-- 정본: docs/badge-catalog.csv (158행). 이 파일은 그 CSV에서 기계적으로 생성됐다.
-- 카탈로그를 고칠 때는 CSV를 먼저 고치고 새 마이그레이션을 생성한다 —
-- 이 파일을 직접 편집하면 CSV와 DB가 조용히 어긋난다.
--
-- 열 매핑 (CSV → badges):
--   id            → id
--   display_name  → name
--   description   → description
--   category      → category   (한국어 라벨 → snake_case enum 값, 16종)
--   scope         → scope
--   trigger_type  → trigger_type
--   condition_type→ condition_type
--   condition_value → condition (jsonb)
--   badge_grade   → badge_grade
--   (없음)        → season_id = null
--
--   ⚠️ CSV의 `functional_name`("누적거리 5km 달성" 등)은 시드하지 않는다.
--      description이 같은 내용을 더 완전하게 담고 있고, Dart Badge 모델에도
--      대응 필드가 없다. lib/·test/·docs/ 전체에 참조 0건임을 확인했다.
--
-- scope='seasonal' 41종은 **템플릿**으로 시드된다(season_id = null).
--   → 클라이언트 규약: scope=seasonal AND season_id IS NULL 인 행은
--     "다가올 시즌 뱃지"다. 획득 불가이며 진행률을 그리지 않는다.
--     시즌 시작 시 {templateId}@{seasonId} id로 인스턴스를 복제 발급하는
--     배치 잡이 별도 후속 작업으로 필요하다(설계문서 §6-4).
--
-- 멱등: on conflict (id) do update — 재적용해도 카탈로그가 CSV와 수렴한다.
-- =============================================================================

insert into public.badges
  (id, name, description, category, scope, trigger_type, condition_type, condition, badge_grade, season_id)
values
  ('dist_cum_5km', '첫걸음', '평생 누적 러닝 거리가 5km를 넘으면 획득', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 5}'::jsonb, 'bronze', null),
  ('dist_cum_15km', '워밍업', '평생 누적 러닝 거리가 15km를 넘으면 획득', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 15}'::jsonb, 'bronze', null),
  ('dist_cum_30km', '루트', '평생 누적 러닝 거리가 30km를 넘으면 획득', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 30}'::jsonb, 'bronze', null),
  ('dist_cum_60km', '페이서', '평생 누적 러닝 거리가 60km를 넘으면 획득', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 60}'::jsonb, 'silver', null),
  ('dist_cum_120km', '질주', '평생 누적 러닝 거리가 120km를 넘으면 획득', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 120}'::jsonb, 'silver', null),
  ('dist_cum_300km', '질주자', '평생 누적 러닝 거리가 300km를 넘으면 획득 (플래티넘 페이스 기준 약 1.2시즌 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 300}'::jsonb, 'silver', null),
  ('dist_cum_600km', '장정', '평생 누적 러닝 거리가 600km를 넘으면 획득 (플래티넘 페이스 기준 약 2.4시즌 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 600}'::jsonb, 'gold', null),
  ('dist_cum_1000km', '천리길', '평생 누적 러닝 거리가 1000km를 넘으면 획득 (플래티넘 페이스 기준 약 4시즌=1.0년 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 1000}'::jsonb, 'gold', null),
  ('dist_cum_1500km', '로드러너', '평생 누적 러닝 거리가 1500km를 넘으면 획득 (플래티넘 페이스 기준 약 6시즌=1.5년 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 1500}'::jsonb, 'gold', null),
  ('dist_cum_2500km', '레인저', '평생 누적 러닝 거리가 2500km를 넘으면 획득 (플래티넘 페이스 기준 약 10시즌=2.5년 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 2500}'::jsonb, 'platinum', null),
  ('dist_cum_4000km', '노마드', '평생 누적 러닝 거리가 4000km를 넘으면 획득 (플래티넘 페이스 기준 약 16시즌=4.0년 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 4000}'::jsonb, 'platinum', null),
  ('dist_cum_6000km', '개척자', '평생 누적 러닝 거리가 6000km를 넘으면 획득 (플래티넘 페이스 기준 약 24시즌=6.0년 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 6000}'::jsonb, 'platinum', null),
  ('dist_cum_8000km', '정복자', '평생 누적 러닝 거리가 8000km를 넘으면 획득 (플래티넘 페이스 기준 약 32시즌=8.0년 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 8000}'::jsonb, 'diamond', null),
  ('dist_cum_10000km', '레전드', '평생 누적 러닝 거리가 10000km를 넘으면 획득 (플래티넘 페이스 기준 약 40시즌=10.0년 분량)', 'cumulative_distance', 'permanent', 'cumulative', 'cumulative_distance_gte', '{"distanceKm": 10000}'::jsonb, 'diamond', null),
  ('cnt_cum_1', '첫 러닝', '검증된 러닝 세션 누적 1회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 1}'::jsonb, 'bronze', null),
  ('cnt_cum_10', '루틴', '검증된 러닝 세션 누적 10회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 10}'::jsonb, 'bronze', null),
  ('cnt_cum_25', '습관', '검증된 러닝 세션 누적 25회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 25}'::jsonb, 'silver', null),
  ('cnt_cum_50', '단골', '검증된 러닝 세션 누적 50회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 50}'::jsonb, 'silver', null),
  ('cnt_cum_100', '터줏대감', '검증된 러닝 세션 누적 100회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 100}'::jsonb, 'gold', null),
  ('cnt_cum_250', '고인물', '검증된 러닝 세션 누적 250회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 250}'::jsonb, 'gold', null),
  ('cnt_cum_500', '장인', '검증된 러닝 세션 누적 500회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 500}'::jsonb, 'platinum', null),
  ('cnt_cum_750', '달인', '검증된 러닝 세션 누적 750회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 750}'::jsonb, 'platinum', null),
  ('cnt_cum_1000', '마스터러너', '검증된 러닝 세션 누적 1000회 달성 시 획득', 'cumulative_count', 'permanent', 'cumulative', 'cumulative_count_gte', '{"count": 1000}'::jsonb, 'diamond', null),
  ('strk_longest_2w', '꾸준함', '역대 최장 주간 연속 러닝 스트릭이 2주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 2}'::jsonb, 'bronze', null),
  ('strk_longest_4w', '리듬', '역대 최장 주간 연속 러닝 스트릭이 4주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 4}'::jsonb, 'bronze', null),
  ('strk_longest_8w', '습관력', '역대 최장 주간 연속 러닝 스트릭이 8주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 8}'::jsonb, 'silver', null),
  ('strk_longest_12w', '한결같음', '역대 최장 주간 연속 러닝 스트릭이 12주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 12}'::jsonb, 'silver', null),
  ('strk_longest_26w', '뚝심', '역대 최장 주간 연속 러닝 스트릭이 26주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 26}'::jsonb, 'gold', null),
  ('strk_longest_38w', '우직함', '역대 최장 주간 연속 러닝 스트릭이 38주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 38}'::jsonb, 'gold', null),
  ('strk_longest_52w', '불굴', '역대 최장 주간 연속 러닝 스트릭이 52주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 52}'::jsonb, 'platinum', null),
  ('strk_longest_78w', '철인', '역대 최장 주간 연속 러닝 스트릭이 78주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 78}'::jsonb, 'platinum', null),
  ('strk_longest_104w', '불멸', '역대 최장 주간 연속 러닝 스트릭이 104주 이상일 때 획득(주 1회 이상 러닝 기준, 1회 유예 포함)', 'longest_streak', 'permanent', 'cumulative', 'streak_weeks_gte', '{"weeks": 104}'::jsonb, 'diamond', null),
  ('pb_first_1km', '스타트', '1km 거리를 검증된 실외 기록으로 처음 완주하고 PB로 등록될 때 획득', 'personal_best', 'permanent', 'session', 'pb_first_achieved', '{"distanceKm": 1}'::jsonb, 'special', null),
  ('pb_first_5km', '각성', '5km 거리를 검증된 실외 기록으로 처음 완주하고 PB로 등록될 때 획득', 'personal_best', 'permanent', 'session', 'pb_first_achieved', '{"distanceKm": 5}'::jsonb, 'special', null),
  ('pb_first_10km', '돌파', '10km 거리를 검증된 실외 기록으로 처음 완주하고 PB로 등록될 때 획득', 'personal_best', 'permanent', 'session', 'pb_first_achieved', '{"distanceKm": 10}'::jsonb, 'special', null),
  ('pb_first_15km', '가속', '15km 거리를 검증된 실외 기록으로 처음 완주하고 PB로 등록될 때 획득', 'personal_best', 'permanent', 'session', 'pb_first_achieved', '{"distanceKm": 15}'::jsonb, 'special', null),
  ('pb_first_half', '하프러너', '하프마라톤 거리를 검증된 실외 기록으로 처음 완주하고 PB로 등록될 때 획득', 'personal_best', 'permanent', 'session', 'pb_first_achieved', '{"distanceKm": 21.1}'::jsonb, 'special', null),
  ('pb_first_full', '마라토너', '풀마라톤 거리를 검증된 실외 기록으로 처음 완주하고 PB로 등록될 때 획득', 'personal_best', 'permanent', 'session', 'pb_first_achieved', '{"distanceKm": 42.2}'::jsonb, 'special', null),
  ('pb_1km_sub5', '쾌속', '1km 검증된 실외 기록이 5분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 1, "seconds": 300}'::jsonb, 'bronze', null),
  ('pb_5km_sub30', '순항', '5km 검증된 실외 기록이 30분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 5, "seconds": 1800}'::jsonb, 'bronze', null),
  ('pb_5km_sub25', '역주', '5km 검증된 실외 기록이 25분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 5, "seconds": 1500}'::jsonb, 'silver', null),
  ('pb_5km_sub20', '서브20', '5km 검증된 실외 기록이 20분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 5, "seconds": 1200}'::jsonb, 'gold', null),
  ('pb_10km_sub60', '완주력', '10km 검증된 실외 기록이 1시간 0분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 10, "seconds": 3600}'::jsonb, 'bronze', null),
  ('pb_10km_sub50', '스퍼트', '10km 검증된 실외 기록이 50분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 10, "seconds": 3000}'::jsonb, 'silver', null),
  ('pb_10km_sub40', '서브40', '10km 검증된 실외 기록이 40분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 10, "seconds": 2400}'::jsonb, 'gold', null),
  ('pb_15km_sub90', '지구력', '15km 검증된 실외 기록이 1시간 30분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 15, "seconds": 5400}'::jsonb, 'bronze', null),
  ('pb_half_sub150', '완주자', '하프마라톤 검증된 실외 기록이 2시간 30분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 21.1, "seconds": 9000}'::jsonb, 'bronze', null),
  ('pb_half_sub120', '서브투', '하프마라톤 검증된 실외 기록이 2시간 0분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 21.1, "seconds": 7200}'::jsonb, 'silver', null),
  ('pb_half_sub100', '서브100', '하프마라톤 검증된 실외 기록이 1시간 40분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 21.1, "seconds": 6000}'::jsonb, 'gold', null),
  ('pb_full_sub300', '완주혼', '풀마라톤 검증된 실외 기록이 5시간 0분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 42.2, "seconds": 18000}'::jsonb, 'bronze', null),
  ('pb_full_sub240', '서브포', '풀마라톤 검증된 실외 기록이 4시간 0분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 42.2, "seconds": 14400}'::jsonb, 'silver', null),
  ('pb_full_sub210', '서브330', '풀마라톤 검증된 실외 기록이 3시간 30분 이내일 때 획득', 'personal_best', 'permanent', 'session', 'pb_time_lte', '{"distanceKm": 42.2, "seconds": 12600}'::jsonb, 'gold', null),
  ('session_dist_10km', '텐런', '단일 러닝 세션에서 10km 이상 거리를 완주하면 획득', 'single_session_distance', 'permanent', 'session', 'session_distance_gte', '{"distanceKm": 10}'::jsonb, 'special', null),
  ('session_dist_15km', '롱런', '단일 러닝 세션에서 15km 이상 거리를 완주하면 획득', 'single_session_distance', 'permanent', 'session', 'session_distance_gte', '{"distanceKm": 15}'::jsonb, 'special', null),
  ('session_dist_half', '하프런', '단일 러닝 세션에서 하프마라톤 이상 거리를 완주하면 획득', 'single_session_distance', 'permanent', 'session', 'session_distance_gte', '{"distanceKm": 21.1}'::jsonb, 'special', null),
  ('session_dist_full', '풀런', '단일 러닝 세션에서 풀마라톤 이상 거리를 완주하면 획득', 'single_session_distance', 'permanent', 'session', 'session_distance_gte', '{"distanceKm": 42.2}'::jsonb, 'special', null),
  ('session_dist_ultra50', '울트라런', '단일 러닝 세션에서 50km 이상 거리를 완주하면 획득', 'single_session_distance', 'permanent', 'session', 'session_distance_gte', '{"distanceKm": 50}'::jsonb, 'special', null),
  ('session_duration_2h', '투아워런', '단일 러닝 세션 시간이 2시간 이상일 때 획득', 'single_session_distance', 'permanent', 'session', 'session_duration_gte', '{"seconds": 7200}'::jsonb, 'special', null),
  ('session_duration_3h', '쓰리아워런', '단일 러닝 세션 시간이 3시간 이상일 때 획득', 'single_session_distance', 'permanent', 'session', 'session_duration_gte', '{"seconds": 10800}'::jsonb, 'special', null),
  ('tod_dawn_1', '새벽런', '오전 5시 이전 시작한 러닝이 누적 1회일 때 획득', 'time_of_day_weekday', 'permanent', 'session', 'session_start_hour_count_gte', '{"before": "05:00", "count": 1}'::jsonb, 'bronze', null),
  ('tod_dawn_10', '새벽형인간', '오전 5시 이전 시작한 러닝이 누적 10회일 때 획득', 'time_of_day_weekday', 'permanent', 'session', 'session_start_hour_count_gte', '{"before": "05:00", "count": 10}'::jsonb, 'silver', null),
  ('tod_dawn_50', '새벽러너', '오전 5시 이전 시작한 러닝이 누적 50회일 때 획득', 'time_of_day_weekday', 'permanent', 'session', 'session_start_hour_count_gte', '{"before": "05:00", "count": 50}'::jsonb, 'platinum', null),
  ('tod_night_1', '심야런', '오후 10시 이후 시작한 러닝이 누적 1회일 때 획득', 'time_of_day_weekday', 'permanent', 'session', 'session_start_hour_count_gte', '{"after": "22:00", "count": 1}'::jsonb, 'bronze', null),
  ('tod_night_10', '올빼미', '오후 10시 이후 시작한 러닝이 누적 10회일 때 획득', 'time_of_day_weekday', 'permanent', 'session', 'session_start_hour_count_gte', '{"after": "22:00", "count": 10}'::jsonb, 'silver', null),
  ('tod_night_50', '나이트러너', '오후 10시 이후 시작한 러닝이 누적 50회일 때 획득', 'time_of_day_weekday', 'permanent', 'session', 'session_start_hour_count_gte', '{"after": "22:00", "count": 50}'::jsonb, 'platinum', null),
  ('tod_lunch_10', '점심런', '11:30~13:30 사이 시작한 러닝이 누적 10회일 때 획득', 'time_of_day_weekday', 'permanent', 'session', 'session_start_hour_count_gte', '{"between": ["11:30", "13:30"], "count": 10}'::jsonb, 'bronze', null),
  ('tod_lunch_50', '런치러너', '11:30~13:30 사이 시작한 러닝이 누적 50회일 때 획득', 'time_of_day_weekday', 'permanent', 'session', 'session_start_hour_count_gte', '{"between": ["11:30", "13:30"], "count": 50}'::jsonb, 'gold', null),
  ('tod_weekday5_1', '풀출근런', '월~금 5일 모두 러닝한 주가 누적 1회일 때 획득', 'time_of_day_weekday', 'permanent', 'cumulative', 'weekday_full_week_count_gte', '{"count": 1}'::jsonb, 'bronze', null),
  ('tod_weekday5_10', '위크데이러너', '월~금 5일 모두 러닝한 주가 누적 10회일 때 획득', 'time_of_day_weekday', 'permanent', 'cumulative', 'weekday_full_week_count_gte', '{"count": 10}'::jsonb, 'gold', null),
  ('tod_weekend_1', '주말런', '토·일 이틀 모두 러닝한 주가 누적 1회일 때 획득', 'time_of_day_weekday', 'permanent', 'cumulative', 'weekend_both_days_count_gte', '{"count": 1}'::jsonb, 'bronze', null),
  ('tod_weekend_10', '위켄더', '토·일 이틀 모두 러닝한 주가 누적 10회일 때 획득', 'time_of_day_weekday', 'permanent', 'cumulative', 'weekend_both_days_count_gte', '{"count": 10}'::jsonb, 'gold', null),
  ('tod_monday_10', '월요킬러', '월요일 러닝이 누적 10회일 때 획득', 'time_of_day_weekday', 'permanent', 'cumulative', 'day_of_week_count_gte', '{"count": 10, "day": "MON"}'::jsonb, 'silver', null),
  ('tod_all_days_diversity', '요일마스터', '월~일 7개 요일 모두에서 최소 1회씩 러닝한 적이 있을 때 획득', 'time_of_day_weekday', 'permanent', 'cumulative', 'day_of_week_diversity_gte', '{"distinctDays": 7}'::jsonb, 'gold', null),
  ('tod_prework_10', '출근전사', '평일 오전 7시 이전 러닝이 누적 10회일 때 획득', 'time_of_day_weekday', 'permanent', 'cumulative', 'session_start_hour_count_gte', '{"before": "07:00", "count": 10, "weekdayOnly": true}'::jsonb, 'silver', null),
  ('route_diverse_5', '탐험가', '시작 지점 기준 서로 다른 경로에서 러닝한 곳이 5곳 이상일 때 획득', 'route_exploration', 'permanent', 'cumulative', 'route_diversity_count_gte', '{"distinctStartPoints": 5}'::jsonb, 'bronze', null),
  ('route_diverse_10', '루트헌터', '시작 지점 기준 서로 다른 경로에서 러닝한 곳이 10곳 이상일 때 획득', 'route_exploration', 'permanent', 'cumulative', 'route_diversity_count_gte', '{"distinctStartPoints": 10}'::jsonb, 'silver', null),
  ('route_diverse_25', '지도제작자', '시작 지점 기준 서로 다른 경로에서 러닝한 곳이 25곳 이상일 때 획득', 'route_exploration', 'permanent', 'cumulative', 'route_diversity_count_gte', '{"distinctStartPoints": 25}'::jsonb, 'platinum', null),
  ('route_elev_500', '언덕러너', '평생 누적 고도상승(elevation gain)이 500m를 넘으면 획득', 'route_exploration', 'permanent', 'cumulative', 'elevation_gain_cumulative_gte', '{"meters": 500}'::jsonb, 'bronze', null),
  ('route_elev_2000', '클라이머', '평생 누적 고도상승(elevation gain)이 2000m를 넘으면 획득', 'route_exploration', 'permanent', 'cumulative', 'elevation_gain_cumulative_gte', '{"meters": 2000}'::jsonb, 'silver', null),
  ('route_elev_5000', '마운티니어', '평생 누적 고도상승(elevation gain)이 5000m를 넘으면 획득', 'route_exploration', 'permanent', 'cumulative', 'elevation_gain_cumulative_gte', '{"meters": 5000}'::jsonb, 'platinum', null),
  ('route_district_3', '동네탐방', '서로 다른 행정구역(구/동)에서 러닝한 곳이 3곳 이상일 때 획득', 'route_exploration', 'permanent', 'cumulative', 'district_diversity_gte', '{"distinctDistricts": 3}'::jsonb, 'bronze', null),
  ('route_district_10', '구역정복', '서로 다른 행정구역(구/동)에서 러닝한 곳이 10곳 이상일 때 획득', 'route_exploration', 'permanent', 'cumulative', 'district_diversity_gte', '{"distinctDistricts": 10}'::jsonb, 'gold', null),
  ('route_loop_10', '루프마스터', '출발지와 도착지가 같은 순환(루프) 코스 러닝이 누적 10회일 때 획득', 'route_exploration', 'permanent', 'cumulative', 'loop_course_count_gte', '{"count": 10}'::jsonb, 'silver', null),
  ('special_birthday', '생일런', '내 생일에 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"type": "birthday"}'::jsonb, 'special', null),
  ('special_newyear', '새해런', '1월 1일에 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"date": "01-01"}'::jsonb, 'special', null),
  ('special_lunar_newyear', '설날런', '설날 당일 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"date": "lunar_newyear"}'::jsonb, 'special', null),
  ('special_childrens_day', '동심런', '5월 5일 어린이날 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"date": "05-05"}'::jsonb, 'special', null),
  ('special_liberation_day', '광복런', '8월 15일 광복절 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"date": "08-15"}'::jsonb, 'special', null),
  ('special_chuseok', '추석런', '추석 당일 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"date": "chuseok"}'::jsonb, 'special', null),
  ('special_hangeul_day', '한글런', '10월 9일 한글날 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"date": "10-09"}'::jsonb, 'special', null),
  ('special_christmas', '산타런', '12월 25일 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"date": "12-25"}'::jsonb, 'special', null),
  ('special_last_day_of_year', '라스트런', '12월 31일 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'calendar_date_match', '{"date": "12-31"}'::jsonb, 'special', null),
  ('special_anniv_1y', '1주년', '앱 가입 1주년 당일 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'membership_anniversary_run', '{"years": 1}'::jsonb, 'special', null),
  ('special_anniv_3y', '3주년', '앱 가입 3주년 당일 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'membership_anniversary_run', '{"years": 3}'::jsonb, 'special', null),
  ('special_anniv_5y', '5주년', '앱 가입 5주년 당일 러닝을 완료하면 획득', 'special_day', 'permanent', 'session', 'membership_anniversary_run', '{"years": 5}'::jsonb, 'special', null),
  ('pace_avg_sub600', '안정페이스', '단일 세션 평균 페이스가 6:00/km 이내일 때 획득', 'pace_speed', 'permanent', 'session', 'pace_avg_lte', '{"secPerKm": 360}'::jsonb, 'special', null),
  ('pace_avg_sub530', '빠른걸음', '단일 세션 평균 페이스가 5:30/km 이내일 때 획득', 'pace_speed', 'permanent', 'session', 'pace_avg_lte', '{"secPerKm": 330}'::jsonb, 'special', null),
  ('pace_avg_sub500', '질주페이스', '단일 세션 평균 페이스가 5:00/km 이내일 때 획득', 'pace_speed', 'permanent', 'session', 'pace_avg_lte', '{"secPerKm": 300}'::jsonb, 'special', null),
  ('pace_avg_sub430', '레이서', '단일 세션 평균 페이스가 4:30/km 이내일 때 획득', 'pace_speed', 'permanent', 'session', 'pace_avg_lte', '{"secPerKm": 270}'::jsonb, 'special', null),
  ('pace_negsplit_1', '후반스퍼트', '후반 구간이 전반보다 빠른 네거티브 스플릿 러닝이 누적 1회일 때 획득', 'pace_speed', 'permanent', 'session', 'pace_negative_split_count_gte', '{"count": 1}'::jsonb, 'bronze', null),
  ('pace_negsplit_10', '네거티브마스터', '후반 구간이 전반보다 빠른 네거티브 스플릿 러닝이 누적 10회일 때 획득', 'pace_speed', 'permanent', 'cumulative', 'pace_negative_split_count_gte', '{"count": 10}'::jsonb, 'gold', null),
  ('pace_spurt_finish_1', '라스트스퍼트', '마지막 1km 페이스가 세션 평균보다 20% 이상 빠를 때 획득', 'pace_speed', 'permanent', 'session', 'pace_final_km_faster_pct_gte', '{"pct": 20}'::jsonb, 'special', null),
  ('pace_consistent_1', '메트로놈', '세션 내 km별 페이스 변동폭이 평균 대비 ±5% 이내일 때 획득(5km 이상 세션 한정)', 'pace_speed', 'permanent', 'session', 'pace_variance_lte', '{"pct": 5}'::jsonb, 'special', null),
  ('device_watchApple_1', '애플워치런', '애플워치로 기록한 러닝이 처음 검증될 때 획득', 'device_integration', 'permanent', 'session', 'device_source_count_gte', '{"count": 1, "source": "watchApple"}'::jsonb, 'special', null),
  ('device_watchApple_50', '애플워치러너', '애플워치로 기록한 러닝이 누적 50회일 때 획득', 'device_integration', 'permanent', 'cumulative', 'device_source_count_gte', '{"count": 50, "source": "watchApple"}'::jsonb, 'gold', null),
  ('device_watchGarmin_1', '가민런', '가민으로 기록한 러닝이 처음 검증될 때 획득', 'device_integration', 'permanent', 'session', 'device_source_count_gte', '{"count": 1, "source": "watchGarmin"}'::jsonb, 'special', null),
  ('device_watchGarmin_50', '가민러너', '가민으로 기록한 러닝이 누적 50회일 때 획득', 'device_integration', 'permanent', 'cumulative', 'device_source_count_gte', '{"count": 50, "source": "watchGarmin"}'::jsonb, 'gold', null),
  ('device_both_used', '올라운더', '폰 단독 기록과 워치 연동 기록을 각각 최소 1회 이상 보유하면 획득', 'device_integration', 'permanent', 'cumulative', 'device_source_diversity_gte', '{"sources": ["phone", "watchApple_or_watchGarmin"]}'::jsonb, 'special', null),
  ('lvl_5', '루키', '사용자 레벨이 5에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 5}'::jsonb, 'bronze', null),
  ('lvl_10', '러너', '사용자 레벨이 10에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 10}'::jsonb, 'bronze', null),
  ('lvl_15', '에이스', '사용자 레벨이 15에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 15}'::jsonb, 'silver', null),
  ('lvl_20', '베테랑', '사용자 레벨이 20에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 20}'::jsonb, 'silver', null),
  ('lvl_25', '엘리트', '사용자 레벨이 25에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 25}'::jsonb, 'gold', null),
  ('lvl_30', '챔피언', '사용자 레벨이 30에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 30}'::jsonb, 'gold', null),
  ('lvl_40', '마스터', '사용자 레벨이 40에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 40}'::jsonb, 'platinum', null),
  ('lvl_50', '그랜드마스터', '사용자 레벨이 50에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 50}'::jsonb, 'platinum', null),
  ('lvl_60', '만렙', '사용자 레벨이 60에 도달하면 획득', 'level', 'permanent', 'cumulative', 'level_gte', '{"level": 60}'::jsonb, 'diamond', null),
  ('stier_bronze', '시즌브론즈', '해당 시즌 누적거리 기준 브론즈 티어에 도달하면 발급. 시즌 라벨과 함께 영구 보존(예: ''2026 Q3 브론즈'')', 'season_tier', 'seasonal', 'cumulative', 'season_tier_reached', '{"tier": "bronze"}'::jsonb, 'bronze', null),
  ('stier_silver', '시즌실버', '해당 시즌 누적거리 기준 실버 티어에 도달하면 발급. 시즌 라벨과 함께 영구 보존(예: ''2026 Q3 실버'')', 'season_tier', 'seasonal', 'cumulative', 'season_tier_reached', '{"tier": "silver"}'::jsonb, 'silver', null),
  ('stier_gold', '시즌골드', '해당 시즌 누적거리 기준 골드 티어에 도달하면 발급. 시즌 라벨과 함께 영구 보존(예: ''2026 Q3 골드'')', 'season_tier', 'seasonal', 'cumulative', 'season_tier_reached', '{"tier": "gold"}'::jsonb, 'gold', null),
  ('stier_platinum', '시즌플래티넘', '해당 시즌 누적거리 기준 플래티넘 티어에 도달하면 발급. 시즌 라벨과 함께 영구 보존(예: ''2026 Q3 플래티넘'')', 'season_tier', 'seasonal', 'cumulative', 'season_tier_reached', '{"tier": "platinum"}'::jsonb, 'platinum', null),
  ('srank_bronze_top1', '브론즈 위클리킹', '브론즈 티어 내 주간 누적거리 랭킹에서 주간 1위에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top1", "tier": "bronze"}'::jsonb, 'bronze', null),
  ('srank_bronze_top10', '브론즈 탑텐', '브론즈 티어 내 주간 누적거리 랭킹에서 주간 TOP10에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top10", "tier": "bronze"}'::jsonb, 'bronze', null),
  ('srank_bronze_top10pct', '브론즈 라이징', '브론즈 티어 내 주간 누적거리 랭킹에서 주간 상위 10%에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top10pct", "tier": "bronze"}'::jsonb, 'bronze', null),
  ('srank_silver_top1', '실버 위클리킹', '실버 티어 내 주간 누적거리 랭킹에서 주간 1위에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top1", "tier": "silver"}'::jsonb, 'silver', null),
  ('srank_silver_top10', '실버 탑텐', '실버 티어 내 주간 누적거리 랭킹에서 주간 TOP10에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top10", "tier": "silver"}'::jsonb, 'silver', null),
  ('srank_silver_top10pct', '실버 라이징', '실버 티어 내 주간 누적거리 랭킹에서 주간 상위 10%에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top10pct", "tier": "silver"}'::jsonb, 'silver', null),
  ('srank_gold_top1', '골드 위클리킹', '골드 티어 내 주간 누적거리 랭킹에서 주간 1위에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top1", "tier": "gold"}'::jsonb, 'gold', null),
  ('srank_gold_top10', '골드 탑텐', '골드 티어 내 주간 누적거리 랭킹에서 주간 TOP10에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top10", "tier": "gold"}'::jsonb, 'gold', null),
  ('srank_gold_top10pct', '골드 라이징', '골드 티어 내 주간 누적거리 랭킹에서 주간 상위 10%에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top10pct", "tier": "gold"}'::jsonb, 'gold', null),
  ('srank_platinum_top1', '플래티넘 위클리킹', '플래티넘 티어 내 주간 누적거리 랭킹에서 주간 1위에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top1", "tier": "platinum"}'::jsonb, 'platinum', null),
  ('srank_platinum_top10', '플래티넘 탑텐', '플래티넘 티어 내 주간 누적거리 랭킹에서 주간 TOP10에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top10", "tier": "platinum"}'::jsonb, 'platinum', null),
  ('srank_platinum_top10pct', '플래티넘 라이징', '플래티넘 티어 내 주간 누적거리 랭킹에서 주간 상위 10%에 들면 그 주 발급', 'season_weekly_rank', 'seasonal', 'cumulative', 'season_weekly_rank_lte', '{"bucket": "top10pct", "tier": "platinum"}'::jsonb, 'platinum', null),
  ('sdist_10km', '스타트런', '해당 시즌 누적거리가 10km를 넘으면 획득(티어 임계값과 별도의 세부 마일스톤)', 'season_cumulative_distance', 'seasonal', 'cumulative', 'season_cumulative_distance_gte', '{"distanceKm": 10}'::jsonb, 'bronze', null),
  ('sdist_25km', '워밍업런', '해당 시즌 누적거리가 25km를 넘으면 획득(티어 임계값과 별도의 세부 마일스톤)', 'season_cumulative_distance', 'seasonal', 'cumulative', 'season_cumulative_distance_gte', '{"distanceKm": 25}'::jsonb, 'bronze', null),
  ('sdist_50km', '시즌하프', '해당 시즌 누적거리가 50km를 넘으면 획득(티어 임계값과 별도의 세부 마일스톤)', 'season_cumulative_distance', 'seasonal', 'cumulative', 'season_cumulative_distance_gte', '{"distanceKm": 50}'::jsonb, 'silver', null),
  ('sdist_100km', '시즌질주', '해당 시즌 누적거리가 100km를 넘으면 획득(티어 임계값과 별도의 세부 마일스톤)', 'season_cumulative_distance', 'seasonal', 'cumulative', 'season_cumulative_distance_gte', '{"distanceKm": 100}'::jsonb, 'gold', null),
  ('sdist_150km', '시즌스퍼트', '해당 시즌 누적거리가 150km를 넘으면 획득(티어 임계값과 별도의 세부 마일스톤)', 'season_cumulative_distance', 'seasonal', 'cumulative', 'season_cumulative_distance_gte', '{"distanceKm": 150}'::jsonb, 'platinum', null),
  ('sdist_200km', '파이널랩', '해당 시즌 누적거리가 200km를 넘으면 획득(티어 임계값과 별도의 세부 마일스톤)', 'season_cumulative_distance', 'seasonal', 'cumulative', 'season_cumulative_distance_gte', '{"distanceKm": 200}'::jsonb, 'diamond', null),
  ('sevent_welcome', '시즌웰컴', '그 시즌 첫 러닝을 완료하면 획득', 'season_event', 'seasonal', 'session', 'season_first_run', '{}'::jsonb, 'special', null),
  ('sevent_full_attendance', '시즌개근', '시즌 전체 기간 동안 매주 최소 1회 이상 러닝하면 시즌 종료 시 획득', 'season_event', 'seasonal', 'cumulative', 'season_weekly_attendance_full', '{}'::jsonb, 'special', null),
  ('sevent_half_attendance', '시즌반개근', '시즌 기간 중 절반 이상의 주에 최소 1회 러닝하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_weekly_attendance_gte_pct', '{"pct": 50}'::jsonb, 'special', null),
  ('sevent_early_start', '얼리버드', '시즌 시작일 다음 날까지 첫 러닝을 완료하면 획득', 'season_event', 'seasonal', 'session', 'season_first_run_within_days', '{"days": 1}'::jsonb, 'special', null),
  ('sevent_season_pb', '시즌PB', '그 시즌 안에서 개인 최고기록(PB)을 새로 세우면 획득', 'season_event', 'seasonal', 'session', 'season_pb_achieved', '{}'::jsonb, 'special', null),
  ('sevent_best_week', '베스트위크', '그 시즌 안에서 개인 주간 누적거리 최고 기록을 경신하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_best_week_distance_pb', '{}'::jsonb, 'special', null),
  ('sevent_challenge_complete', '챌린지클리어', '그 시즌 중 설정한 개인 챌린지(GM-09)를 완료하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_challenge_completed', '{}'::jsonb, 'special', null),
  ('sevent_rank_rising_3w', '라이징스타', '같은 시즌 내에서 주간 티어 내 순위가 3주 연속 상승하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_weekly_rank_rising_streak_gte', '{"weeks": 3}'::jsonb, 'special', null),
  ('sevent_tier_early', '조기졸업', '시즌 진행률 50% 이전에 해당 시즌 최고 티어(플래티넘)를 달성하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_max_tier_reached_before_pct', '{"pct": 50}'::jsonb, 'special', null),
  ('sevent_comeback', '컴백러너', '4주 이상 공백 후 해당 시즌에 복귀해 러닝하면 획득', 'season_event', 'seasonal', 'session', 'season_comeback_run', '{"gapWeeks": 4}'::jsonb, 'special', null),
  ('sevent_first_long_distance', '시즌첫롱런', '그 시즌 안에서 처음으로 하프마라톤 이상 거리를 완주하면 획득', 'season_event', 'seasonal', 'session', 'season_first_long_distance', '{"distanceKm": 21.1}'::jsonb, 'special', null),
  ('sevent_start_dash_3w', '스타트대시', '시즌 시작 후 첫 3주 연속으로 매주 러닝하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_start_streak_weeks_gte', '{"weeks": 3}'::jsonb, 'special', null),
  ('sevent_streak_4w', '불씨', '해당 시즌 내에서 4주 연속 러닝(시즌 경계 밖 스트릭은 미포함)하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_streak_weeks_gte', '{"weeks": 4}'::jsonb, 'bronze', null),
  ('sevent_streak_8w', '불꽃', '해당 시즌 내에서 8주 연속 러닝(시즌 경계 밖 스트릭은 미포함)하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_streak_weeks_gte', '{"weeks": 8}'::jsonb, 'silver', null),
  ('sevent_streak_12w', '완전연소', '해당 시즌 내에서 12주 연속 러닝(시즌 경계 밖 스트릭은 미포함)하면 획득', 'season_event', 'seasonal', 'cumulative', 'season_streak_weeks_gte', '{"weeks": 12}'::jsonb, 'platinum', null),
  ('sfin_last_week_active', '시즌파이널', '시즌 마지막 주에 러닝 활동이 있으면 시즌 종료 시 획득(HI-06 리텐션 지표 연동)', 'season_finisher', 'seasonal', 'cumulative', 'season_final_week_active', '{}'::jsonb, 'special', null),
  ('sfin_full_participation', '완주시즌', '시즌 첫째 주와 마지막 주 모두 러닝 활동이 있으면 획득', 'season_finisher', 'seasonal', 'cumulative', 'season_first_and_last_week_active', '{}'::jsonb, 'special', null),
  ('sfin_consecutive_2_seasons', '2시즌러너', '직전 시즌에 이어 연속 2개 시즌에서 유효 티어를 달성하면 획득', 'season_finisher', 'seasonal', 'cumulative', 'consecutive_seasons_participated_gte', '{"seasons": 2}'::jsonb, 'silver', null),
  ('sfin_consecutive_4_seasons', '1년개근', '연속 4개 시즌(만 1년) 동안 유효 티어를 달성하면 획득', 'season_finisher', 'seasonal', 'cumulative', 'consecutive_seasons_participated_gte', '{"seasons": 4}'::jsonb, 'gold', null)
on conflict (id) do update set
  name           = excluded.name,
  description    = excluded.description,
  category       = excluded.category,
  scope          = excluded.scope,
  trigger_type   = excluded.trigger_type,
  condition_type = excluded.condition_type,
  condition      = excluded.condition,
  badge_grade    = excluded.badge_grade;

-- CSV에서 사라진 뱃지가 DB에 남아 있으면 카탈로그가 어긋난다.
-- 시드 직후 총계를 단언해 조용한 드리프트를 막는다.
do $$
declare v_cnt integer;
begin
  select count(*) into v_cnt from public.badges;
  if v_cnt <> 158 then
    raise exception '뱃지 카탈로그 총계 불일치: 기대 158, 실제 %', v_cnt;
  end if;
end;
$$;
