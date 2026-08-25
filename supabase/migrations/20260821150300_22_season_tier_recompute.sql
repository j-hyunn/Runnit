-- =============================================================================
-- Runnit :: 22. 시즌 거리 재계산 + 티어 판정 + 시즌 리셋(멱등)
-- -----------------------------------------------------------------------------
-- 근거: architect 문서 §3, §7-4, §7-5 / PRD §8.1, §8.3, §8.5, TI-03
--
-- 핵심 설계
--   1) **전체 재계산**. 델타 갱신이 아니라 현재 시즌 구간의 러닝을 매번 다시 합산한다.
--      recompute_profile_stats 와 같은 이유 — 기록 삭제/플래그 해제 경로마다 부호를
--      맞추는 것은 오류가 잦다. §8.1 "기록 삭제 시 기준선 미달이면 티어 하향"이
--      이 방식으로 자동 충족된다.
--   2) **시즌 리셋을 별도 이벤트로 두지 않는다.** tier_season_id 가 현재 시즌과
--      다르면 (a) 이전 시즌을 season_histories 로 마감하고 (b) 새 시즌 구간으로
--      다시 집계할 뿐이다. 새 시즌 시작 직후에는 합계가 0 이므로 자연히 브론즈가 된다.
--      -> 어느 경로로 몇 번 호출해도 결과가 같다(멱등).
--   3) 집계 필터가 recompute_profile_stats 와 **다르다**:
--      activity_type <> 'indoor_run' 이 여기에만 붙는다(§8.3).
--      ⚠️ recompute_profile_stats 에는 이 필터를 넣으면 안 된다 —
--         §8.3 은 누적 통계·히스토리에 트레드밀을 **반영하라**고 명시한다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 22-1. 사용자 1명의 시즌 거리·티어 재계산 (필요 시 이전 시즌 마감 포함)
-- -----------------------------------------------------------------------------
create or replace function public.recompute_season_tier(
  p_user_id uuid,
  p_at      timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_season      text        := public.season_id_at(p_at);
  v_start       timestamptz := public.season_start(v_season);
  v_end         timestamptz := public.season_end(v_season);
  v_prev_season text;
  v_prev_tier   public.tier;
  v_prev_dist   double precision;
  v_dist        double precision := 0;
begin
  -- 동시에 두 러닝이 업로드돼도 마감/리셋이 한 번만 일어나도록 행 잠금.
  select p.tier_season_id, p.current_tier, p.season_distance_meters
    into v_prev_season, v_prev_tier, v_prev_dist
    from public.profiles p
   where p.id = p_user_id
     for update;

  if not found then
    return;   -- 프로필이 없으면(삭제 cascade 중) 조용히 종료
  end if;

  -- ── 1) 시즌 경계를 넘었으면 이전 시즌 확정 마감 (§8.1) ─────────────────────
  -- UNIQUE (user_id, season_id) + ON CONFLICT DO NOTHING = 중복 마감 불가.
  if v_prev_season is distinct from v_season and v_prev_season is not null then
    insert into public.season_histories (
      user_id, season_id, final_tier, distance_meters,
      run_count, moving_seconds, best_weekly_rank, closed_at
    )
    select
      p_user_id,
      v_prev_season,
      v_prev_tier,                        -- 마감 시점 확정 티어(소급 변경 금지)
      coalesce(v_prev_dist, 0),           -- profiles.season_distance_meters 스냅샷
      coalesce(agg.run_count, 0),
      coalesce(agg.moving_seconds, 0),
      (
        select min(le.rank)
          from public.leaderboard_entries le
         where le.user_id      = p_user_id
           and le.period       = 'weekly'
           and le.metric       = 'distance'
           and le.scope        = 'global'
           and le.period_start >= public.season_start(v_prev_season)
           and le.period_start <  public.season_end(v_prev_season)
      ),
      now()
    from (
      select count(*)::integer                        as run_count,
             coalesce(sum(r.moving_seconds), 0)::integer as moving_seconds
        from public.runs r
       where r.user_id       = p_user_id
         and r.status        = 'completed'
         and r.is_flagged    = false
         and r.activity_type <> 'indoor_run'
         and r.started_at   >= public.season_start(v_prev_season)
         and r.started_at   <  public.season_end(v_prev_season)
    ) agg
    on conflict (user_id, season_id) do nothing;
  end if;

  -- ── 2) 현재 시즌 거리 재계산 (§8.3 실외만 / §8.5 시작 시각 귀속) ──────────
  select coalesce(sum(r.distance_meters), 0)
    into v_dist
    from public.runs r
   where r.user_id       = p_user_id
     and r.status        = 'completed'
     and r.is_flagged    = false
     and r.activity_type <> 'indoor_run'
     and r.started_at   >= v_start
     and r.started_at   <  v_end;

  -- ── 3) 티어 판정 + 시즌 포인터 갱신 ───────────────────────────────────────
  perform set_config('runnit.server_write', 'on', true);

  update public.profiles p
     set season_distance_meters = v_dist,
         current_tier           = public.tier_for_distance(v_dist),
         tier_season_id         = v_season,
         updated_at             = now()
   where p.id = p_user_id;

  perform set_config('runnit.server_write', 'off', true);
end;
$$;

revoke execute on function public.recompute_season_tier(uuid, timestamptz)
  from public, anon, authenticated;

comment on function public.recompute_season_tier(uuid, timestamptz) is
  '시즌 누적 거리 전체 재계산 + 티어 판정 + 시즌 경계 시 이전 시즌 마감. 멱등.';

-- -----------------------------------------------------------------------------
-- 22-2. runs 트리거 경로에 태운다 — TI-03 "기록 저장 즉시 판정, 배치 대기 없음"
-- -----------------------------------------------------------------------------
create or replace function public.trg_runs_recompute_stats()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recompute_profile_stats(old.user_id);
    perform public.recompute_season_tier(old.user_id);
    return old;
  end if;

  perform public.recompute_profile_stats(new.user_id);
  perform public.recompute_season_tier(new.user_id);

  if tg_op = 'UPDATE' and old.user_id is distinct from new.user_id then
    perform public.recompute_profile_stats(old.user_id);
    perform public.recompute_season_tier(old.user_id);
  end if;
  return new;
end;
$$;

revoke execute on function public.trg_runs_recompute_stats() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 22-3. 시즌 일괄 리셋 — cron 진입점 (분기 첫날 00:05 KST)
-- -----------------------------------------------------------------------------
-- 이미 현재 시즌인 프로필은 건너뛴다 -> 몇 번을 돌려도 안전.
create or replace function public.reset_stale_seasons(
  p_at timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_season text := public.season_id_at(p_at);
  v_id     uuid;
  v_count  integer := 0;
begin
  for v_id in
    select p.id from public.profiles p
     where p.tier_season_id is distinct from v_season
  loop
    perform public.recompute_season_tier(v_id, p_at);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke execute on function public.reset_stale_seasons(timestamptz)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 22-4. 읽기 경로 지연 복구 — 클라이언트가 프로필을 읽기 전에 호출하는 RPC
-- -----------------------------------------------------------------------------
-- 배치(cron)에만 의존하지 않는다. 배치가 실패/지연돼도 다음 프로필 조회에서
-- 스스로 복구되어야 한다(architect §3). 본인 행만 건드리므로 authenticated 에 개방한다 —
-- 입력을 받지 않고 auth.uid() 로만 동작하며, 내부 계산은 전부 서버 데이터에서 나온다.
-- 이미 현재 시즌이면 아무 것도 하지 않고 즉시 반환한다(멱등 + 저비용).
create or replace function public.sync_my_season()
returns public.tier
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_season text := public.season_id_at(now());
  v_tier   public.tier;
  v_stale  boolean;
begin
  if v_uid is null then
    raise exception '인증이 필요하다' using errcode = '28000';
  end if;

  select (p.tier_season_id is distinct from v_season), p.current_tier
    into v_stale, v_tier
    from public.profiles p
   where p.id = v_uid;

  if not found then
    return null;
  end if;

  if v_stale then
    perform public.recompute_season_tier(v_uid, now());
    select p.current_tier into v_tier from public.profiles p where p.id = v_uid;
  end if;

  return v_tier;
end;
$$;

revoke execute on function public.sync_my_season() from public, anon;
grant  execute on function public.sync_my_season() to authenticated;

comment on function public.sync_my_season() is
  '읽기 경로 지연 복구: 본인 프로필의 시즌이 지났으면 마감+리셋 후 현재 티어를 반환. 멱등.';

-- -----------------------------------------------------------------------------
-- 22-5. cron — 분기 첫날 00:05 KST = 직전 분기 마지막 날 15:05 UTC
-- -----------------------------------------------------------------------------
--   Q1 시작(1/1 00:05 KST) -> 12/31 15:05 UTC
--   Q2 시작(4/1 00:05 KST) ->  3/31 15:05 UTC
--   Q3 시작(7/1 00:05 KST) ->  6/30 15:05 UTC
--   Q4 시작(10/1 00:05 KST) -> 9/30 15:05 UTC
-- 31일 달(3,12월)과 30일 달(6,9월)로 나뉘어 두 개의 잡이 된다.
select cron.schedule(
  'runnit-season-reset-31',
  '5 15 31 3,12 *',
  $cron$ select public.reset_stale_seasons(); $cron$
);

select cron.schedule(
  'runnit-season-reset-30',
  '5 15 30 6,9 *',
  $cron$ select public.reset_stale_seasons(); $cron$
);

-- -----------------------------------------------------------------------------
-- 22-6. 기존 프로필 백필 — tier_season_id 가 전부 NULL 이므로 한 번 돌려 채운다.
-- -----------------------------------------------------------------------------
-- NULL 상태에서는 마감(1단계)을 건너뛰고 현재 시즌 집계만 하므로 유령 시즌 기록이
-- 생기지 않는다.
select public.reset_stale_seasons();
