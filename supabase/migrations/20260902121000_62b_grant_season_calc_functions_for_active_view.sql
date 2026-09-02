-- =============================================================================
-- Runnit :: 62b. leaderboard_entries_active 뷰용 season 계산 함수 grant
-- -----------------------------------------------------------------------------
-- 마이그레이션 62(`leaderboard_entries_active` 뷰)는 `security_invoker = true` 라
-- 뷰 정의 안의 `leaderboard_period_bounds(period, now())` 가 **호출자 권한**으로
-- 평가된다. 그 함수는 다시 `season_start` / `season_end` / `season_next_id` /
-- `season_id_at` 을 부르는데, 이 4종에 `anon`/`authenticated` execute 권한이
-- 없으면 게스트·일반 사용자의 뷰 조회가 42501 로 실패한다.
--
-- season 계산 함수는 테이블 접근이 0인 순수 계산(IMMUTABLE, ARCHITECTURE v0.3)
-- 이라 노출해도 정보 유출이 없다.
--
-- ⚠️ 원격(xwtbwexcofcgmbvktwdo)에는 2026-09-02 에 이미 적용됐다(schema_migrations
--    version 20260902045502). 이 파일은 `db reset`/브랜치 DB 정합을 위한 사후 파일화다.
-- =============================================================================

grant execute on function
  public.season_start(text),
  public.season_end(text),
  public.season_next_id(text),
  public.season_id_at(timestamptz)
to anon, authenticated;
