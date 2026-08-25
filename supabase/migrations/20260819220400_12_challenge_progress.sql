-- =============================================================================
-- Runnit :: 12. 챌린지 진척 재계산 + 완료 확정 + status 전이 배치
-- -----------------------------------------------------------------------------
-- 근거: _workspace/20260819_210450_badge_rules.md §6
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 12-1. challenge status 전이 배치 (pg_cron 진입점)
-- -----------------------------------------------------------------------------
-- §6.3 의 "ended/archived 는 재계산하지 않는다" 필터가 성립하려면 status 가
-- 실제로 전이돼야 한다. ended 로 넘기는 시점에 **end_at + 24h 유예**를 둔다:
-- 종료 직전 러닝을 오프라인으로 기록하고 뒤늦게 업로드한 사용자를 구제하면서도,
-- 하루가 지난 뒤 결과가 뒤집히는 일은 막는다(규칙서 §6.3 완화책).
create or replace function public.transition_challenge_statuses(
  p_anchor timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer := 0;
  v_i integer;
begin
  update public.challenges c
  set status = 'active'
  where c.status = 'upcoming'
    and p_anchor >= c.start_at
    and p_anchor <  c.end_at;
  get diagnostics v_i = row_count;
  v_n := v_n + v_i;

  update public.challenges c
  set status = 'ended'
  where c.status in ('upcoming', 'active')
    and p_anchor >= c.end_at + interval '24 hours';   -- 지연 업로드 유예
  get diagnostics v_i = row_count;
  v_n := v_n + v_i;

  return v_n;
end;
$$;

revoke execute on function public.transition_challenge_statuses(timestamptz)
  from public, anon, authenticated;

comment on function public.transition_challenge_statuses(timestamptz) is
  'upcoming->active->ended 자동 전이. ended 전이는 end_at + 24h 유예(badge_rules §6.3). '
  'pg_cron 에 리더보드 갱신과 함께 등록할 것: '
  'select cron.schedule(''runnit-challenge-status'', ''*/10 * * * *'', $$ select public.transition_challenge_statuses(); $$);';

-- -----------------------------------------------------------------------------
-- 12-2. 챌린지 진척 재계산 — 규칙서 §6.1 / §6.2 / §6.4
-- -----------------------------------------------------------------------------
-- 집계 대상 러닝: status='completed' AND is_flagged=false
--                 AND started_at ∈ [c.start_at, c.end_at)   (반열림 구간)
-- joined_at 은 **필터에 넣지 않는다** (§6.2) — 챌린지 중반 참가자도 그동안의
-- 러닝이 즉시 반영되어야 참가 장벽이 사라진다.
create or replace function public.recompute_challenge_progress(
  p_user_id uuid,
  p_run_id  uuid default null
)
returns integer                 -- 갱신한 참가 행 수
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  cp           record;
  v_started_at timestamptz;
  v_has_run    boolean := false;
  v_progress   double precision := 0;
  v_updated    integer := 0;
  v_inserted   integer := 0;
  v_badge_pts  integer := 0;
begin
  if p_user_id is null then
    return 0;
  end if;

  -- 대상 챌린지를 좁히기 위해 이 러닝의 started_at 을 얻는다(§6.3).
  -- 러닝이 이미 삭제됐거나(DELETE 트리거) p_run_id 가 NULL 이면 좁히지 않고
  -- 해당 사용자의 진행 중 챌린지를 전부 재계산한다 — 안전한 상위집합.
  if p_run_id is not null then
    select r.started_at into v_started_at from public.runs r where r.id = p_run_id;
    v_has_run := found;
  end if;

  perform set_config('runnit.server_write', 'on', true);

  for cp in
    select part.id            as part_id,
           part.completed_at  as completed_at,
           c.id               as challenge_id,
           c.type             as ctype,
           c.target_value     as target_value,
           c.start_at         as start_at,
           c.end_at           as end_at,
           c.reward_points    as reward_points,
           c.reward_badge_id  as reward_badge_id
    from public.challenge_participations part
    join public.challenges c on c.id = part.challenge_id
    where part.user_id = p_user_id
      and c.status in ('upcoming', 'active')   -- ended/archived 는 재계산 금지(§6.3)
      and (not v_has_run
           or (v_started_at >= c.start_at and v_started_at < c.end_at))
  loop
    if cp.ctype = 'streak_days' then
      -- 챌린지 기간 내에서 독립 계산한다. profiles.current_streak_days 를 쓰면
      -- 기간 밖 러닝까지 포함되어 틀린다(§6.1).
      with d as (
        select distinct (r.started_at at time zone 'Asia/Seoul')::date as run_date
        from public.runs r
        where r.user_id = p_user_id
          and r.status = 'completed'
          and r.is_flagged = false
          and r.started_at >= cp.start_at
          and r.started_at <  cp.end_at
      ),
      g as (
        select run_date,
               run_date - (row_number() over (order by run_date))::integer as grp
        from d
      )
      select coalesce(max(s.cnt), 0)
      into v_progress
      from (select count(*) as cnt from g group by g.grp) s;
    else
      select case cp.ctype
               when 'distance_total'      then coalesce(sum(r.distance_meters), 0)
               when 'run_count'           then count(*)::double precision
               when 'single_run_distance' then coalesce(max(r.distance_meters), 0)
               when 'elevation_total'     then coalesce(sum(coalesce(r.elevation_gain_meters, 0)), 0)
               else 0
             end
      into v_progress
      from public.runs r
      where r.user_id = p_user_id
        and r.status = 'completed'
        and r.is_flagged = false
        and r.started_at >= cp.start_at
        and r.started_at <  cp.end_at;
    end if;

    v_progress := greatest(coalesce(v_progress, 0), 0);   -- progress_value >= 0 제약

    update public.challenge_participations
    set progress_value = v_progress
    where id = cp.part_id;

    v_updated := v_updated + 1;

    -- 완료 확정. **되돌리지 않는다** — completed_at 이 한 번 서면 이후 진척이
    -- 목표 아래로 내려가도(기록 삭제, 사후 플래그) NULL 로 복원하지 않는다(§6.4).
    if cp.completed_at is null and v_progress >= cp.target_value then
      update public.challenge_participations
      set completed_at = now()
      where id = cp.part_id;

      if cp.reward_points > 0 then
        update public.profiles
        set total_points = total_points + cp.reward_points
        where id = p_user_id;
      end if;

      if cp.reward_badge_id is not null then
        insert into public.user_badges (user_id, badge_id, earned_at, source_run_id, is_seen)
        values (p_user_id, cp.reward_badge_id, now(),
                case when v_has_run then p_run_id else null end, false)
        on conflict (user_id, badge_id) do nothing;
        get diagnostics v_inserted = row_count;

        -- ⚠️ 규칙서 §6.4 의사코드에는 없는 가산이다(판단 지점).
        --    recompute_profile_stats 가 total_points 를
        --    "러닝 + 획득 뱃지 + 완주 챌린지" 로 재계산하므로(10 파일 §3-4),
        --    여기서 보상 뱃지 포인트를 더하지 않으면 다음 러닝 업로드 때
        --    포인트가 뒤늦게 튀어오르는 불일치가 생긴다.
        if v_inserted > 0 then
          select b.points into v_badge_pts from public.badges b where b.id = cp.reward_badge_id;
          update public.profiles
          set total_points = total_points + coalesce(v_badge_pts, 0)
          where id = p_user_id;
        end if;
      end if;

      update public.profiles
      set level = public.compute_level(total_points)
      where id = p_user_id;
    end if;
  end loop;

  perform set_config('runnit.server_write', 'off', true);

  return v_updated;
end;
$$;

revoke execute on function public.recompute_challenge_progress(uuid, uuid)
  from public, anon, authenticated;

comment on function public.recompute_challenge_progress(uuid, uuid) is
  '챌린지 진척 재계산 + 완료 확정(badge_rules §6). joined_at 필터 없음(§6.2). '
  'upcoming/active 챌린지만 대상(§6.3). completed_at 은 되돌리지 않는다(§6.4).';

-- -----------------------------------------------------------------------------
-- 12-3. 신규 참가 시 1회 재계산 (§6.3 마지막 줄)
-- -----------------------------------------------------------------------------
-- 이게 없으면 §6.2 의 "참가 즉시 과거 기록 반영"이 성립하지 않는다.
-- 재귀 위험 없음: 이 트리거는 INSERT 에만 걸리고, 함수는 UPDATE 만 수행한다.
create or replace function public.trg_participation_recompute()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.recompute_challenge_progress(new.user_id, null);
  -- 참가와 동시에 완주 처리될 수 있으므로 challenge_completed_count 뱃지도 재평가.
  perform public.evaluate_badges(new.user_id, null);
  return new;
end;
$$;

-- evaluate_badges 는 13 파일에서 정의된다. plpgsql 은 본문을 실행 시점에
-- 해석하므로 정의 순서는 문제되지 않지만, 트리거 생성은 13 파일 마지막에서
-- 나머지 트리거들과 함께 한다(순서 의존성을 한 곳에 모으기 위함).
