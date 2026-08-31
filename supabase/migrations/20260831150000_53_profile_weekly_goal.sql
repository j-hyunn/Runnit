-- =============================================================================
-- Runnit :: 53. AC-02 — profiles.weekly_goal_km (주간 목표 거리)
-- -----------------------------------------------------------------------------
-- 배경(PRD §5.8 AC-02 / 2026-08-31 사용자 확정):
--   프로필 편집에서 사용자가 직접 바꾸는 항목은 네 가지다 —
--     display_name · avatar_url · weight_kg(기존) · weekly_goal_km(신설).
--   username(고유 핸들)은 편집 불가로 고정한다.
--
-- 타입을 numeric 이 아니라 double precision 으로 잡은 이유:
--   TRD 초기 DDL 블록(폐기됨)에는 `weekly_goal_km numeric` 으로 적혀 있으나,
--   실제 스키마의 신체/거리 계열 사용자 입력 컬럼은 전부 double precision 이다
--   (height_cm / weight_kg / total_distance_meters). Dart 는 double 하나로 받는데
--   PostgREST 는 numeric 을 JSON number 로 내려주면서 정밀도 표현이 달라질 수 있어,
--   같은 화면에서 함께 편집되는 weight_kg 와 타입을 맞추는 편이 안전하다.
--
-- 단위: **km**. 컬럼명이 단위를 갖고 있고(_km), 프로젝트의 다른 거리 컬럼이 m 인 것과
--   다르다. 주간 목표는 사용자가 "주 30km" 처럼 km 로 입력·인지하는 값이고,
--   달성률 계산 시 클라이언트가 총 거리(m)를 1000 으로 나눠 비교한다.
--   서버는 이 값으로 아무 판정도 하지 않는다(랭킹·티어·뱃지와 무관한 순수 표시용).
--
-- CHECK 상한 500:
--   주간 500km 는 엘리트 러너의 주간 주행거리(보통 160~200km)를 크게 웃도는 값이라
--   정상 입력을 막지 않으면서 오타(3000)·단위 착각(30000m 를 km 칸에 입력)만 걸러낸다.
--   0 이하는 목표로서 의미가 없으므로 "미설정"은 NULL 로 표현한다(0 이 아니라).
--
-- 가드 트리거는 손대지 않는다:
--   05/19/39 의 trg_profiles_guard 는 **화이트리스트가 아니라 블랙리스트**다 —
--   서버 전용 컬럼(total_* / level / current_tier / streak_* ...)을 old 값으로
--   되돌릴 뿐, 열거되지 않은 컬럼은 그대로 통과한다. 따라서 weekly_goal_km 은
--   추가만으로 사용자 편집이 열린다. (weight_kg 도 같은 이유로 편집 가능하다.)
--   ⚠️ 역으로, 앞으로 추가되는 컬럼은 **기본이 "사용자 편집 가능"** 이다.
--      서버 전용 컬럼을 만들 때는 반드시 이 가드에 등록해야 한다.
-- =============================================================================

alter table public.profiles
  add column if not exists weekly_goal_km double precision;

alter table public.profiles
  drop constraint if exists profiles_weekly_goal_range;

alter table public.profiles
  add constraint profiles_weekly_goal_range
  check (weekly_goal_km is null or (weekly_goal_km > 0 and weekly_goal_km <= 500));

comment on column public.profiles.weekly_goal_km is
  'AC-02 주간 목표 거리(km). 사용자 편집 가능, NULL = 미설정. 표시 전용이며 랭킹/티어/뱃지 판정에 쓰이지 않는다.';
