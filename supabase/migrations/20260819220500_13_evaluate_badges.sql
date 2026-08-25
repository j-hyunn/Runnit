-- =============================================================================
-- Runnit :: 13. 뱃지 자동 판정(evaluate_badges) + runs 트리거 실행 순서 확정 + 백필
-- -----------------------------------------------------------------------------
-- 근거: _workspace/20260819_210450_badge_rules.md §1.1, §2, §7-B1/B6
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 13-1. evaluate_badges — 미획득 활성 뱃지 전량 재평가
-- -----------------------------------------------------------------------------
-- "이번 러닝으로 뭘 얻었나"가 아니라 "아직 못 받은 게 있나"를 본다(§2.2).
-- 세션형/누적형을 구분하지 않으므로 여러 세션에 걸친 마일스톤을 구조적으로
-- 놓치지 않는다. 대부분의 지표가 profiles 캐시에서 O(1) 로 나오고, 러닝 파생
-- 지표 6종은 부분 인덱스(runs_user_completed_idx)를 타는 단일 스캔으로 한 번에 얻는다.
create or replace function public.evaluate_badges(
  p_user_id       uuid,
  p_source_run_id uuid default null
)
returns integer                 -- 이번 호출에서 새로 지급한 뱃지 수
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b record;

  -- profiles 캐시 (O(1))
  v_run_count      integer;
  v_total_dist     double precision;
  v_total_moving   integer;
  v_longest_streak integer;

  -- runs 파생 (단일 스캔)
  v_max_single_dist double precision;
  v_max_single_elev double precision;
  v_total_elev      double precision;
  v_best_pace_5k    double precision;
  v_best_pace_10k   double precision;
  v_early_count     integer;
  v_night_count     integer;

  -- challenge 파생
  v_challenge_done  integer;

  v_current    double precision;
  v_earned     boolean;
  v_inserted   integer;
  v_awarded    integer := 0;
  v_points_add integer := 0;
  v_src        uuid;
begin
  if p_user_id is null then
    return 0;
  end if;

  select p.total_run_count, p.total_distance_meters, p.total_moving_seconds, p.longest_streak_days
  into v_run_count, v_total_dist, v_total_moving, v_longest_streak
  from public.profiles p
  where p.id = p_user_id;

  if not found then
    return 0;   -- 프로필이 없으면 판정할 대상도 없다
  end if;

  -- source_run_id 는 nullable FK 다. 삭제된 러닝 id 가 넘어오면 FK 위반이므로
  -- 실재하는 행일 때만 사용한다(AFTER DELETE 트리거 경로 방어).
  v_src := null;
  if p_source_run_id is not null then
    select r.id into v_src from public.runs r where r.id = p_source_run_id;
  end if;

  -- 집계 대상은 랭킹·프로필 통계와 동일 기준(§1.1): completed AND NOT flagged.
  -- 이 술어는 runs_user_completed_idx 부분 인덱스가 커버한다.
  select
    max(r.distance_meters),
    max(r.elevation_gain_meters),
    coalesce(sum(coalesce(r.elevation_gain_meters, 0)), 0),
    -- 5km 이상 러닝 중 **최소** 평균 페이스. 해당 러닝이 없으면 NULL 이 되고,
    -- 아래 비교에서 IS NOT NULL 검사에 걸려 미획득으로 확정된다.
    min(case when r.distance_meters >= 5000  and r.moving_seconds > 0
             then r.moving_seconds / (r.distance_meters / 1000.0) end),
    min(case when r.distance_meters >= 10000 and r.moving_seconds > 0
             then r.moving_seconds / (r.distance_meters / 1000.0) end),
    -- KST 05:00~06:59 시작
    (count(*) filter (
      where extract(hour from (r.started_at at time zone 'Asia/Seoul')) in (5, 6)
    ))::integer,
    -- KST 21:00~03:59 시작
    (count(*) filter (
      where extract(hour from (r.started_at at time zone 'Asia/Seoul')) in (21, 22, 23, 0, 1, 2, 3)
    ))::integer
  into v_max_single_dist, v_max_single_elev, v_total_elev,
       v_best_pace_5k, v_best_pace_10k, v_early_count, v_night_count
  from public.runs r
  where r.user_id = p_user_id
    and r.status = 'completed'
    and r.is_flagged = false;

  select count(*)::integer
  into v_challenge_done
  from public.challenge_participations cp
  where cp.user_id = p_user_id
    and cp.completed_at is not null;

  for b in
    select bg.id, bg.criteria_type, bg.threshold, bg.points
    from public.badges bg
    where bg.is_active = true
      and not exists (
        select 1 from public.user_badges ub
        where ub.user_id = p_user_id and ub.badge_id = bg.id
      )
    order by bg.sort_order, bg.id
  loop
    v_current := case b.criteria_type
      when 'run_count'                   then v_run_count::double precision
      when 'single_run_distance_m'       then v_max_single_dist
      when 'total_distance_m'            then v_total_dist
      when 'total_moving_seconds'        then v_total_moving::double precision
      when 'streak_days'                 then v_longest_streak::double precision
      when 'pace_sec_per_km_below_5k'    then v_best_pace_5k
      when 'pace_sec_per_km_below_10k'   then v_best_pace_10k
      when 'single_run_elevation_gain_m' then v_max_single_elev
      when 'total_elevation_gain_m'      then v_total_elev
      when 'early_run_count'             then v_early_count::double precision
      when 'night_run_count'             then v_night_count::double precision
      when 'challenge_completed_count'   then v_challenge_done::double precision
      else null
    end;

    -- ⚠️ 비교 방향 분기 (§1.1). 페이스 지표만 "작을수록 좋음"이다.
    --    IS NOT NULL 을 명시하지 않으면 3값 논리 때문에 판정이 어그러진다.
    --    (해당 거리 러닝이 없어 v_current 가 NULL 인 사용자는 미획득이어야 한다.)
    if b.criteria_type like 'pace_sec_per_km_below%' then
      v_earned := (v_current is not null and v_current <= b.threshold);
    else
      v_earned := (v_current is not null and v_current >= b.threshold);
    end if;

    if v_earned then
      perform set_config('runnit.server_write', 'on', true);

      insert into public.user_badges (user_id, badge_id, earned_at, source_run_id, is_seen)
      values (p_user_id, b.id, now(), v_src, false)
      on conflict (user_id, badge_id) do nothing;   -- 재업로드/동시 업로드 중복 방어
      get diagnostics v_inserted = row_count;

      if v_inserted > 0 then
        v_awarded    := v_awarded + 1;
        v_points_add := v_points_add + b.points;
      end if;
    end if;
  end loop;

  if v_points_add > 0 then
    perform set_config('runnit.server_write', 'on', true);
    update public.profiles p
    set total_points = p.total_points + v_points_add,
        level        = public.compute_level(p.total_points + v_points_add),
        updated_at   = now()
    where p.id = p_user_id;
  end if;

  perform set_config('runnit.server_write', 'off', true);

  return v_awarded;
end;
$$;

revoke execute on function public.evaluate_badges(uuid, uuid) from public, anon, authenticated;

comment on function public.evaluate_badges(uuid, uuid) is
  '뱃지 자동 판정(정본). badge_rules §2.2: 미획득 활성 뱃지 전량 재평가. '
  '클라이언트가 user_badges 에 INSERT 할 경로는 존재하지 않는다(RLS INSERT 정책 없음).';

-- -----------------------------------------------------------------------------
-- 13-2. runs AFTER 트리거 3종 — **실행 순서 강제**
-- -----------------------------------------------------------------------------
-- Postgres 는 같은 이벤트의 트리거를 **이름 알파벳순**으로 실행한다.
-- 순서가 뒤집히면 evaluate_badges 가 갱신 전 profiles 캐시와
-- challenge_participations.completed_at 을 읽어 마일스톤이 한 세션씩 밀린다
-- (규칙서 §2.1 / §7-B1). 그래서 이름에 01_/02_/03_ 접두 번호를 박아 순서를 고정한다.
--
--   runs_01_recompute_stats     -> profiles 캐시(total_*, longest_streak_days, level)
--   runs_02_challenge_progress  -> 참가 챌린지 진척 + 완주 확정(+ 보상 포인트/뱃지)
--   runs_03_evaluate_badges     -> 위 두 결과를 읽어 미획득 뱃지 전량 재평가
--
-- 이 이름들은 공통 접두사 'runs_0N_' 를 공유하므로 콜레이션과 무관하게
-- 숫자 자리에서 순서가 결정된다.

create or replace function public.trg_runs_challenge_progress()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recompute_challenge_progress(old.user_id, null);
    return old;
  end if;

  perform public.recompute_challenge_progress(new.user_id, new.id);
  if tg_op = 'UPDATE' and old.user_id is distinct from new.user_id then
    perform public.recompute_challenge_progress(old.user_id, null);
  end if;
  return new;
end;
$$;

create or replace function public.trg_runs_evaluate_badges()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    -- 기록이 사라져도 이미 지급된 뱃지는 회수하지 않는다(§2.5). 다만 다른 사용자
    -- 상태에는 영향이 없으므로 재평가만 돌린다(새로 지급될 수는 없고 no-op 에 가깝다).
    perform public.evaluate_badges(old.user_id, null);
    return old;
  end if;

  perform public.evaluate_badges(new.user_id, new.id);
  if tg_op = 'UPDATE' and old.user_id is distinct from new.user_id then
    perform public.evaluate_badges(old.user_id, null);
  end if;
  return new;
end;
$$;

drop trigger if exists runs_recompute_stats on public.runs;

create trigger runs_01_recompute_stats
after insert or update or delete on public.runs
for each row execute function public.trg_runs_recompute_stats();

create trigger runs_02_challenge_progress
after insert or update or delete on public.runs
for each row execute function public.trg_runs_challenge_progress();

create trigger runs_03_evaluate_badges
after insert or update or delete on public.runs
for each row execute function public.trg_runs_evaluate_badges();

-- 신규 챌린지 참가 시 과거 기록 즉시 반영 (12 파일에서 정의한 함수)
drop trigger if exists challenge_participations_recompute on public.challenge_participations;
create trigger challenge_participations_recompute
after insert on public.challenge_participations
for each row execute function public.trg_participation_recompute();

-- -----------------------------------------------------------------------------
-- 13-3. 백필 — 기존 데이터에 확정 규칙을 소급 적용 (규칙서 §7-B6)
-- -----------------------------------------------------------------------------
-- 순서: (1) 러닝 포인트 재산정 -> (2) 프로필 캐시 -> (3) 챌린지 -> (4) 뱃지.
-- (1) 은 러닝 건수만큼 AFTER 트리거가 연쇄 발화하는 것을 피하려고 트리거를 잠시
--     끄고 awarded_points 를 직접 계산해 넣는다. 끈 사이에는 BEFORE 가드도
--     돌지 않으므로 compute_awarded_points 를 명시적으로 호출한다.
-- 대량 데이터가 이미 쌓인 환경이라면 이 DO 블록을 마이그레이션에서 떼어내
-- 점검 시간대에 배치로 돌릴 것.
do $$
declare
  v record;
begin
  alter table public.runs disable trigger user;

  update public.runs r
  set awarded_points = public.compute_awarded_points(
        r.status, r.is_flagged, r.distance_meters, r.moving_seconds, r.elevation_gain_meters
      );

  alter table public.runs enable trigger user;

  for v in select p.id from public.profiles p loop
    perform public.recompute_profile_stats(v.id);
    perform public.recompute_challenge_progress(v.id, null);
    perform public.evaluate_badges(v.id, null);
    -- 뱃지/챌린지 포인트가 가산됐으므로 캐시를 한 번 더 맞춰 확정한다.
    perform public.recompute_profile_stats(v.id);
  end loop;
end;
$$;

-- 리더보드도 새 포인트/동점 규칙으로 다시 계산해 둔다.
select public.refresh_all_leaderboards();
