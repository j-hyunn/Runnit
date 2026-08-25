-- 뱃지 카탈로그 문구 오류 3건 수정 (backend-engineer 보고서
-- `_workspace/20260825_181914_backend_badge-v2-migration.md` §7.4).
-- 정본 `docs/badge-catalog.csv` 수정과 함께 적용 — 26번 시드의 name/description만
-- CSV와 다시 수렴시킨다. functional_name은 DB에 시드하지 않으므로 여기 대상 아님.

update public.badges set name = '서브100'
where id = 'pb_half_sub100';

update public.badges set
  description = '단일 러닝 세션에서 50km 이상 거리를 완주하면 획득'
where id = 'session_dist_ultra50';

update public.badges set
  description = '가민으로 기록한 러닝이 처음 검증될 때 획득'
where id = 'device_watchGarmin_1';

update public.badges set
  description = '가민으로 기록한 러닝이 누적 50회일 때 획득'
where id = 'device_watchGarmin_50';
