-- =============================================================================
-- Runnit :: 05. 서버 전용 필드 보호 트리거
-- -----------------------------------------------------------------------------
-- 왜 RLS 만으로 부족한가:
--   RLS 는 "행 단위" 접근 제어다. "이 행은 UPDATE 해도 되지만 total_points 컬럼만은
--   안 된다" 는 표현할 수 없다(컬럼 GRANT 는 PostgREST 사용 시 관리가 번거롭고
--   에러 메시지가 불친절하다).
--
-- 왜 EXCEPTION 이 아니라 "덮어쓰기(무시)" 인가:
--   클라이언트는 freezed 가 만든 toJson() 을 통째로 upsert 한다. AppUser.toJson()
--   에는 total_* 이, RunRecord.toJson() 에는 awarded_points/created_at/updated_at 이
--   **항상 포함**된다. 여기서 예외를 던지면 정상적인 프로필 수정조차 실패한다.
--   따라서 서버 전용 컬럼은 클라이언트 입력을 조용히 무시하고 서버 값으로 되돌린다.
--
-- 추가로 해결하는 문제: Dart 모델의 createdAt/updatedAt 은 nullable 이라
--   toJson() 이 명시적 null 을 보낸다. Postgres 는 **명시적 NULL 입력 시 DEFAULT 를
--   적용하지 않으므로** NOT NULL 위반이 난다. 아래 트리거가 coalesce 로 메꾼다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
create or replace function public.trg_profiles_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := now();

    if not public.is_server_write() then
      new.total_distance_meters := 0;
      new.total_moving_seconds  := 0;
      new.total_run_count       := 0;
      new.total_points          := 0;
      new.level                 := 1;
      new.current_streak_days   := 0;
      new.longest_streak_days   := 0;
      new.last_run_at           := null;
    end if;
    return new;
  end if;

  -- UPDATE
  new.id         := old.id;            -- PK 변조 차단
  new.created_at := old.created_at;
  new.updated_at := now();

  if not public.is_server_write() then
    new.total_distance_meters := old.total_distance_meters;
    new.total_moving_seconds  := old.total_moving_seconds;
    new.total_run_count       := old.total_run_count;
    new.total_points          := old.total_points;
    new.level                 := old.level;
    new.current_streak_days   := old.current_streak_days;
    new.longest_streak_days   := old.longest_streak_days;
    new.last_run_at           := old.last_run_at;
    -- crew_id 는 크루 가입 로직 확정 전까지 클라이언트 변경을 막는다.
    new.crew_id               := old.crew_id;
  end if;

  return new;
end;
$$;

create trigger profiles_guard
before insert or update on public.profiles
for each row execute function public.trg_profiles_guard();

-- -----------------------------------------------------------------------------
-- runs
-- -----------------------------------------------------------------------------
create or replace function public.trg_runs_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_reason text;
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
  else
    new.id         := old.id;          -- PK 변조 차단
    new.user_id    := old.user_id;     -- 소유권 이전 차단
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();

  -- 파생값 정규화: 페이스는 항상 movingSeconds 를 분모로 서버가 재계산한다.
  -- (클라이언트 값을 신뢰하지 않되, 불일치를 이유로 플래그하지는 않는다 —
  --  단순 반올림 차이로 정상 기록이 랭킹에서 빠지는 것을 막기 위함.)
  if new.distance_meters > 0 and new.moving_seconds > 0 then
    new.avg_pace_sec_per_km := new.moving_seconds / (new.distance_meters / 1000.0);
  else
    new.avg_pace_sec_per_km := null;
  end if;

  -- 서버 재검증
  v_reason := public.validate_run(
    new.distance_meters, new.elapsed_seconds, new.moving_seconds,
    new.max_speed_mps, new.elevation_gain_meters
  );
  new.is_flagged  := (v_reason is not null);
  new.flag_reason := v_reason;

  -- 포인트는 클라이언트 입력을 무시하고 항상 서버가 산정한다.
  new.awarded_points := public.compute_awarded_points(
    new.status, new.is_flagged, new.distance_meters
  );

  return new;
end;
$$;

create trigger runs_guard
before insert or update on public.runs
for each row execute function public.trg_runs_guard();

-- -----------------------------------------------------------------------------
-- user_badges — earned_at 은 서버 시각으로만 확정, 클라이언트는 is_seen 만 변경 가능
-- -----------------------------------------------------------------------------
create or replace function public.trg_user_badges_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if not public.is_server_write() then
      new.earned_at := now();
    end if;
    return new;
  end if;

  -- UPDATE: 서버 경로가 아니면 is_seen 외 모든 컬럼을 되돌린다.
  if not public.is_server_write() then
    new.id            := old.id;
    new.user_id       := old.user_id;
    new.badge_id      := old.badge_id;
    new.earned_at     := old.earned_at;
    new.source_run_id := old.source_run_id;
  end if;
  return new;
end;
$$;

create trigger user_badges_guard
before insert or update on public.user_badges
for each row execute function public.trg_user_badges_guard();

-- -----------------------------------------------------------------------------
-- challenge_participations — 진척도/완주/순위는 서버 전용
-- -----------------------------------------------------------------------------
create or replace function public.trg_challenge_participations_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if not public.is_server_write() then
      new.joined_at      := now();
      new.progress_value := 0;
      new.completed_at   := null;
      new.rank           := null;
    end if;
    return new;
  end if;

  if not public.is_server_write() then
    new.id             := old.id;
    new.challenge_id   := old.challenge_id;
    new.user_id        := old.user_id;
    new.joined_at      := old.joined_at;
    new.progress_value := old.progress_value;
    new.completed_at   := old.completed_at;
    new.rank           := old.rank;
  end if;
  return new;
end;
$$;

create trigger challenge_participations_guard
before insert or update on public.challenge_participations
for each row execute function public.trg_challenge_participations_guard();

-- participant_count 캐시 유지
create or replace function public.trg_challenge_participant_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    update public.challenges c
    set participant_count = c.participant_count + 1
    where c.id = new.challenge_id;
    return new;
  else
    update public.challenges c
    set participant_count = greatest(0, c.participant_count - 1)
    where c.id = old.challenge_id;
    return old;
  end if;
end;
$$;

create trigger challenge_participant_count
after insert or delete on public.challenge_participations
for each row execute function public.trg_challenge_participant_count();
