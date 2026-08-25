-- =============================================================================
-- Runnit :: 20. 시즌 경계 SQL 함수 (PRD §8.5)
-- -----------------------------------------------------------------------------
-- Dart `lib/models/season.dart` 의 `Season` 과 **동일 규약**이어야 한다.
-- 어긋나면 홈 진행률 바(클라이언트 계산)와 서버 티어 판정이 갈라진다.
--
--   시즌 id     : "{연도}-Q{1..4}"  — KST 벽시계 기준
--   시즌 시작   : 분기 첫날 00:00 KST   (2026-Q3 -> 2026-06-30T15:00Z)
--   시즌 종료   : 다음 시즌 시작, **배타적**. 반열림 [start, end)
--   러닝 귀속   : 러닝 **시작 시각**(started_at) 기준
--
-- KST(Asia/Seoul)는 1988년 이후 서머타임이 없어 UTC+9 고정이다.
-- `timestamp/timestamptz AT TIME ZONE '<상수>'` 는 Postgres 에서 IMMUTABLE 이므로
-- 아래 함수들을 immutable 로 선언해도 안전하다(기존 leaderboard_period_bounds 와 동일).
--
-- seasons 테이블을 만들지 않은 이유는 architect 문서 §2 참조 —
-- 역년 분기는 달력에서 결정론적으로 유도되고, 운영자가 조정할 절차가 없다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- season_id_at(ts) -> '2026-Q3'   (Dart: Season.idAt / Season.idForRun)
-- -----------------------------------------------------------------------------
create or replace function public.season_id_at(p_at timestamptz default now())
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select to_char(p_at at time zone 'Asia/Seoul', 'YYYY"-Q"Q');
$$;

comment on function public.season_id_at(timestamptz) is
  'KST 기준 분기 시즌 id. Dart Season.idAt 과 동일. 러닝 귀속은 started_at 을 넣는다(§8.5).';

-- -----------------------------------------------------------------------------
-- season_start(id) -> timestamptz  (Dart: Season.startOf)
-- -----------------------------------------------------------------------------
-- 잘못된 형식은 예외를 던진다(Dart 가 FormatException 을 던지는 것과 동일한 계약).
create or replace function public.season_start(p_season_id text)
returns timestamptz
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_year    integer;
  v_quarter integer;
begin
  if p_season_id is null or p_season_id !~ '^\d{4}-Q[1-4]$' then
    raise exception '잘못된 seasonId 형식 (기대: 2026-Q3): %', p_season_id
      using errcode = '22000';
  end if;

  v_year    := substring(p_season_id from 1 for 4)::integer;
  v_quarter := substring(p_season_id from 7 for 1)::integer;

  -- KST 벽시계 "분기 첫날 00:00" 을 UTC 로 환산.
  return (make_timestamp(v_year, (v_quarter - 1) * 3 + 1, 1, 0, 0, 0)
          at time zone 'Asia/Seoul');
end;
$$;

-- -----------------------------------------------------------------------------
-- season_next_id / season_previous_id  (Dart: Season.nextId / previousId)
-- -----------------------------------------------------------------------------
create or replace function public.season_next_id(p_season_id text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_year    integer;
  v_quarter integer;
begin
  if p_season_id is null or p_season_id !~ '^\d{4}-Q[1-4]$' then
    raise exception '잘못된 seasonId 형식 (기대: 2026-Q3): %', p_season_id
      using errcode = '22000';
  end if;
  v_year    := substring(p_season_id from 1 for 4)::integer;
  v_quarter := substring(p_season_id from 7 for 1)::integer;

  if v_quarter = 4 then
    return (v_year + 1)::text || '-Q1';
  end if;
  return v_year::text || '-Q' || (v_quarter + 1)::text;
end;
$$;

create or replace function public.season_previous_id(p_season_id text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_year    integer;
  v_quarter integer;
begin
  if p_season_id is null or p_season_id !~ '^\d{4}-Q[1-4]$' then
    raise exception '잘못된 seasonId 형식 (기대: 2026-Q3): %', p_season_id
      using errcode = '22000';
  end if;
  v_year    := substring(p_season_id from 1 for 4)::integer;
  v_quarter := substring(p_season_id from 7 for 1)::integer;

  if v_quarter = 1 then
    return (v_year - 1)::text || '-Q4';
  end if;
  return v_year::text || '-Q' || (v_quarter - 1)::text;
end;
$$;

-- -----------------------------------------------------------------------------
-- season_end(id) -> timestamptz (배타적)  (Dart: Season.endOf)
-- -----------------------------------------------------------------------------
create or replace function public.season_end(p_season_id text)
returns timestamptz
language sql
immutable
set search_path = public, pg_temp
as $$
  select public.season_start(public.season_next_id(p_season_id));
$$;

-- -----------------------------------------------------------------------------
-- 권한: 시즌 경계는 순수 달력 계산이라 클라이언트가 호출해도 무해하지만,
-- 클라이언트는 Dart Season 유틸을 쓰는 것이 계약(네트워크 왕복 제거)이므로
-- RPC 노출을 회수한다. 서버 함수 내부 호출에는 영향이 없다.
-- -----------------------------------------------------------------------------
revoke execute on function public.season_id_at(timestamptz)   from public, anon, authenticated;
revoke execute on function public.season_start(text)          from public, anon, authenticated;
revoke execute on function public.season_end(text)            from public, anon, authenticated;
revoke execute on function public.season_next_id(text)        from public, anon, authenticated;
revoke execute on function public.season_previous_id(text)    from public, anon, authenticated;
