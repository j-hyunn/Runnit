-- =============================================================================
-- Runnit :: 00. Postgres enum 타입
-- -----------------------------------------------------------------------------
-- 계약: _workspace/20260819_132600_architect_data-model.md §1.2
--   Dart enum 은 @JsonValue 로 snake_case 문자열 직렬화된다.
--   Postgres 측 enum 라벨은 그 문자열과 **철자까지 1:1 동일**해야 한다.
--   라벨을 바꾸면 클라이언트 fromJson 이 즉시 깨진다. 추가는 가능(ALTER TYPE ADD VALUE),
--   변경/삭제는 mobile-architect 와 동시 조율 필요.
--
-- 주의: SyncStatus 는 클라이언트 전용(@JsonKey(includeToJson:false)) 이므로
--       enum 타입도 컬럼도 만들지 않는다. (계약서 §1.3)
-- =============================================================================

create type public.run_sample_source as enum ('phone', 'watch', 'external');

create type public.run_status as enum ('recording', 'paused', 'completed', 'discarded');

create type public.activity_type as enum ('outdoor_run', 'indoor_run', 'trail_run', 'walk');

create type public.ranking_period as enum ('daily', 'weekly', 'monthly', 'all_time');

create type public.ranking_metric as enum ('distance', 'duration', 'run_count', 'points');

create type public.ranking_scope as enum ('global', 'crew', 'friends');

create type public.badge_category as enum (
  'distance', 'streak', 'pace', 'elevation', 'social', 'challenge', 'special'
);

create type public.badge_tier as enum ('bronze', 'silver', 'gold', 'platinum');

create type public.challenge_type as enum (
  'distance_total', 'run_count', 'single_run_distance', 'streak_days', 'elevation_total'
);

create type public.challenge_status as enum ('upcoming', 'active', 'ended', 'archived');

create type public.distance_unit as enum ('metric', 'imperial');

create type public.gender as enum ('male', 'female', 'other', 'undisclosed');
