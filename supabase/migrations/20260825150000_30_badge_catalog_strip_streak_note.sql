-- 최장스트릭 뱃지(strk_longest_*) 설명에서 "(주 1회 이상 러닝 기준, 1회 유예 포함)"
-- 부가 설명 괄호를 제거한다. 정본 `docs/badge-catalog.csv`도 동일하게 수정.

update public.badges
set description = trim(regexp_replace(description, '\(주 1회 이상 러닝 기준, 1회 유예 포함\)', '', 'g'))
where id like 'strk_longest_%';
