-- =============================================================================
-- Runnit :: 15. pg_cron 주기 갱신 등록
-- -----------------------------------------------------------------------------
-- 03_leaderboard.sql 에 주석으로 준비해 두었던 스케줄을 실제로 활성화한다.
-- 사용자 승인 후(원격 반영 확정) 실행.
-- =============================================================================

create extension if not exists pg_cron;

select cron.schedule(
  'runnit-leaderboard',
  '*/5 * * * *',
  $cron$ select public.refresh_all_leaderboards(); $cron$
);

select cron.schedule(
  'runnit-challenge-status',
  '*/10 * * * *',
  $cron$ select public.transition_challenge_statuses(); $cron$
);
