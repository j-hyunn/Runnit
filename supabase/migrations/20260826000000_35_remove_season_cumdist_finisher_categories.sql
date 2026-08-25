-- 사용자 요청으로 "시즌누적거리"(season_cumulative_distance)/"시즌완주"(season_finisher)
-- 카테고리 뱃지를 카탈로그에서 완전히 제거한다. 템플릿(season_id=null)과 현재 시즌
-- 인스턴스(season_id='2026-Q3') 모두 대상 — 정본 `docs/badge-catalog.csv`도 동일하게 수정.

delete from public.user_badges
where badge_id in (
  select id from public.badges where category in ('season_cumulative_distance', 'season_finisher')
);

delete from public.badges
where category in ('season_cumulative_distance', 'season_finisher');
