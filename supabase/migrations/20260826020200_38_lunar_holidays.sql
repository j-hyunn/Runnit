-- =============================================================================
-- Runnit :: 38. 음력 명절 고정 룩업 테이블 (설날 / 추석, 2026~2040)
-- -----------------------------------------------------------------------------
-- 정본: _workspace/20260826_000340_gamification_badge-backlog-decisions.md §6
--       docs/TRD.md §10.2 (calendar_date_match 음력)
--
-- 왜 변환 함수를 만들지 않는가 (§6.1)
--   정확한 한국 음력은 한국천문연구원의 삭(朔) 계산을 **동경 135°E(KST)** 기준으로
--   따라야 한다. 중국 음력(120°E)과 날짜가 갈리는 해가 실제로 있다 —
--   삭이 KST 자정 직후에 들면 한국은 하루 뒤가 초하루가 된다.
--     · 2027 설날: 한국 2/7 vs 중국 2/6
--     · 2028 설날: 한국 1/27 vs 중국 1/26
--   범용 음력 라이브러리를 쓰면 이 차이를 그대로 버그로 들여온다. 필요한 건
--   연간 2일뿐이므로(15년 = 30행) 룩업 테이블이 유지보수 비용 0에 정확도 100%다.
--
-- 갱신: 2038년경 다음 15년치를 INSERT 한 줄로 추가한다.
--       미등재 연도는 판정 false(뱃지 미지급) + raise notice — 조용히 넘어가지 않는다.
--
-- ⚠️ holiday_key 는 badges.condition ->> 'date' 값(`lunar_newyear` / `chuseok`)과
--    **같은 문자열**이다. 매핑 테이블을 하나 더 두지 않는다(§6.3).
-- =============================================================================

create table public.lunar_holidays (
  holiday_key text    not null,
  year        integer not null,
  solar_date  date    not null,

  constraint lunar_holidays_pkey primary key (holiday_key, year),
  constraint lunar_holidays_key_domain check (holiday_key in ('lunar_newyear', 'chuseok')),
  constraint lunar_holidays_year_matches_date check (extract(year from solar_date)::integer = year)
);

comment on table public.lunar_holidays is
  '음력 명절의 KST 양력 날짜 룩업(한국천문연구원 기준, 동경 135°E). '
  'holiday_key 는 badges.condition ->> ''date'' 값과 동일 문자열 — 매핑 계층을 두지 않는다. '
  '미등재 연도는 calendar_date_match 가 false + notice 로 처리한다. TRD §10.2';
comment on column public.lunar_holidays.solar_date is
  'KST 기준 양력 날짜. ⚠️ 중국 음력(120°E) 기준 라이브러리와 다른 해가 있다(2027·2028 설날).';

-- -----------------------------------------------------------------------------
-- 38-1. RLS — 공개 상수. 조회 전체 허용, 쓰기는 service_role 만
-- -----------------------------------------------------------------------------
alter table public.lunar_holidays enable row level security;

create policy lunar_holidays_select_all
  on public.lunar_holidays
  for select
  to anon, authenticated
  using (true);

-- insert/update/delete 정책 없음 = 클라이언트 write 전면 금지.
-- public 스키마 default privileges 가 anon/authenticated 에 ALL 을 주므로
-- RLS 만으로도 막히지만, 권한 자체를 회수해 표면을 좁힌다.
revoke insert, update, delete, truncate on public.lunar_holidays from anon, authenticated;

-- -----------------------------------------------------------------------------
-- 38-2. 2026~2040 15년치 (§6.2)
-- -----------------------------------------------------------------------------
insert into public.lunar_holidays (holiday_key, year, solar_date) values
  ('lunar_newyear', 2026, date '2026-02-17'),
  ('lunar_newyear', 2027, date '2027-02-07'),   -- ⚠️ 중국 기준은 2027-02-06
  ('lunar_newyear', 2028, date '2028-01-27'),   -- ⚠️ 중국 기준은 2028-01-26
  ('lunar_newyear', 2029, date '2029-02-13'),
  ('lunar_newyear', 2030, date '2030-02-03'),
  ('lunar_newyear', 2031, date '2031-01-23'),
  ('lunar_newyear', 2032, date '2032-02-11'),
  ('lunar_newyear', 2033, date '2033-01-31'),
  ('lunar_newyear', 2034, date '2034-02-19'),
  ('lunar_newyear', 2035, date '2035-02-08'),
  ('lunar_newyear', 2036, date '2036-01-28'),
  ('lunar_newyear', 2037, date '2037-02-15'),
  ('lunar_newyear', 2038, date '2038-02-04'),
  ('lunar_newyear', 2039, date '2039-01-24'),
  ('lunar_newyear', 2040, date '2040-02-12'),
  ('chuseok',       2026, date '2026-09-25'),
  ('chuseok',       2027, date '2027-09-15'),
  ('chuseok',       2028, date '2028-10-03'),
  ('chuseok',       2029, date '2029-09-22'),
  ('chuseok',       2030, date '2030-09-12'),
  ('chuseok',       2031, date '2031-10-01'),
  ('chuseok',       2032, date '2032-09-19'),
  ('chuseok',       2033, date '2033-09-08'),
  ('chuseok',       2034, date '2034-09-27'),
  ('chuseok',       2035, date '2035-09-16'),
  ('chuseok',       2036, date '2036-10-04'),
  ('chuseok',       2037, date '2037-09-24'),
  ('chuseok',       2038, date '2038-09-13'),
  ('chuseok',       2039, date '2039-10-02'),
  ('chuseok',       2040, date '2040-09-21')
on conflict (holiday_key, year) do update set solar_date = excluded.solar_date;

-- §6.4: 연휴 3일(전날·당일·다음날) 확대는 **이번에 채택하지 않았다** —
-- 같은 카테고리의 다른 8종(special_newyear/special_christmas 등)이 전부 당일 기준이라
-- 설날·추석만 3일로 하면 규칙이 불균질해진다. 넓히기로 하면 solar_date 를
-- start_date/end_date 로 확장해 **데이터만** 고치면 된다(판정식은 그대로).
