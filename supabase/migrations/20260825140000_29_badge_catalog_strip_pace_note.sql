-- 누적거리 뱃지(dist_cum_*) 설명에서 "(플래티넘 페이스 기준 약 N시즌 분량)" 같은
-- 부가 환산 안내 괄호를 제거한다. 정본 `docs/badge-catalog.csv`도 동일하게 수정.

update public.badges
set description = trim(regexp_replace(description, '\s*\(플래티넘 페이스 기준[^)]*\)', '', 'g'))
where id like 'dist_cum_%';
