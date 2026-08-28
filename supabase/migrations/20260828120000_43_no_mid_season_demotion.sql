-- =============================================================================
-- Runnit :: 43. 시즌 중 티어 강등 없음 (PRD TI-08 확정)
-- -----------------------------------------------------------------------------
-- 근거: 사용자 확정(2026-08-28).
--   "강등 안함으로 결정."
--
-- 배경
--   `recompute_season_tier`는 `current_tier`를 항상 `tier_for_distance(누적거리)`로
--   덮어써 왔다. 러닝은 사용자가 삭제할 수 없지만(§8.1 확정), 부정 기록
--   판정(`is_flagged`, §8.4)으로 누적 거리가 줄면 티어가 **내려갔다**. 이는
--   PRD TI-08("시즌 중 강등 없음 — 한 번 오른 티어는 시즌 내 유지")과 충돌한다.
--
--   부정 억제는 이미 3중으로 걸려 있다: ① 해당 러닝이 랭킹 집계에서 제외
--   ② `leaderboard_entries`에서 제외 ③ 부정으로 획득한 뱃지는 `user_badges.revoked`
--   플래그. 티어 숫자까지 내리면 오탐(false positive)·이의 제기 케이스에서
--   억울한 강등이 발생하므로, 티어는 시즌 내 단조 증가로 고정한다.
--
-- 이번에 바꾼 것
--   `recompute_season_tier` 3단계에서, **같은 시즌**이면 새 티어를
--   `greatest(새 티어, 직전 티어)`로 바닥을 깐다. 시즌 경계를 넘은 첫 recompute는
--   하드 리셋이어야 하므로(다음 시즌은 bronze부터) 이 보호를 적용하지 않는다.
--   `season_distance_meters`는 실제 누적값을 그대로 저장한다(줄어들 수 있음) —
--   내려가는 것은 통계 숫자뿐이고 티어 등급은 유지된다.
--
-- 소급 적용
--   현재 시즌에 이미 강등된 유저의 "피크 티어"는 복원하지 않는다. tier_change_history
--   는 마이그레이션 34에서 비워졌고 season_histories는 마감 스냅샷만 있어 시즌 중
--   피크를 역산할 근거가 없다. 다음 recompute부터 이 규칙이 적용된다.
-- =============================================================================

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
  v_new_tier    public.tier;
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
  if v_prev_season is distinct from v_season and v_prev_season is not null then
    insert into public.season_histories (
      user_id, season_id, final_tier, distance_meters,
      run_count, moving_seconds, best_weekly_rank, closed_at
    )
    select
      p_user_id,
      v_prev_season,
      v_prev_tier,
      coalesce(v_prev_dist, 0),
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
  v_new_tier := public.tier_for_distance(v_dist);

  -- (43번) 시즌 중 강등 없음 (PRD TI-08). 같은 시즌이면 직전 티어를 바닥으로
  -- 깐다 — 부정 기록이 빠져 누적 거리가 줄어도 티어 등급은 유지된다. 시즌
  -- 경계를 넘은 첫 recompute는 하드 리셋이므로 보호하지 않는다(다음 시즌은
  -- 다시 bronze부터). 신규 프로필(v_prev_season null)도 보호 대상 아님.
  if v_prev_season is not distinct from v_season and v_prev_tier is not null then
    v_new_tier := greatest(v_new_tier, v_prev_tier);
  end if;

  perform set_config('runnit.server_write', 'on', true);

  update public.profiles p
     set season_distance_meters = v_dist,
         current_tier           = v_new_tier,
         tier_season_id         = v_season,
         updated_at             = now()
   where p.id = p_user_id;

  perform set_config('runnit.server_write', 'off', true);

  -- ── 4) 티어 "상승" 이력만 기록 (34번) ─────────────────────────────────────
  -- 3단계에서 greatest로 바닥을 깔았으므로 같은 시즌에서 v_new_tier < v_prev_tier
  -- 는 발생하지 않는다. 아래 조건은 "진짜 상승"에서만 참이 된다.
  if v_new_tier > v_prev_tier then
    insert into public.tier_change_history (user_id, season_id, tier, reached_at)
    values (p_user_id, v_season, v_new_tier, p_at)
    on conflict (user_id, season_id, tier) do nothing;
  end if;
end;
$$;

revoke execute on function public.recompute_season_tier(uuid, timestamptz)
  from public, anon, authenticated;

comment on function public.recompute_season_tier(uuid, timestamptz) is
  '시즌 누적 거리 전체 재계산 + 티어 판정 + 시즌 경계 시 이전 시즌 마감 + '
  '티어가 실제로 "상승"할 때만 tier_change_history 기록. **시즌 중 강등 없음**(43번, '
  'PRD TI-08) — 같은 시즌이면 current_tier는 단조 증가, 누적 거리가 줄어도 등급 유지. 멱등.';
