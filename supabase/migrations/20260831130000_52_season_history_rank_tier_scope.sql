-- =============================================================================
-- Runnit :: 52. season_histories.best_weekly_rank — 티어 스코프로 한정 (HI-06 QA)
-- -----------------------------------------------------------------------------
-- 근거: HI-06 통합 QA(2026-08-31) PLAUSIBLE 지적.
--
-- 배경
--   마이그레이션 43의 `recompute_season_tier`는 시즌 마감 시
--   `season_histories.best_weekly_rank`를 `leaderboard_entries`에서
--   `min(le.rank)`로 구하는데, `tier` 축 필터가 없다. 마이그레이션 23 이후
--   `leaderboard_entries`에는 통합 보드(`tier IS NULL`)와 티어별 보드
--   (`tier = <티어>`)가 **함께** 저장되므로, 두 스코프의 rank가 한 `min()`에
--   섞여 들어간다. 현재는 티어 보드가 통합 보드의 부분집합이라 우연히 값이
--   맞지만, 마감 후 수정 불가한 컬럼이므로 스코프를 명시한다.
--
--   클라이언트가 노출하는 주간 랭킹은 항상 티어 스코프
--   (`supabase_ranking_repository`)이므로, 마감 스냅샷도 티어 스코프가 맞다.
--
-- 이번에 바꾼 것
--   `best_weekly_rank` 서브쿼리에 `and le.tier is not null` 한 줄 추가.
--   함수의 다른 부분(선언부 · 1~4단계 로직 · greatest 강등 방지 ·
--   tier_change_history 기록 조건 · revoke)은 43과 **완전히 동일**하다.
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
           and le.tier is not null   -- (52번) 티어별 보드만 — 통합 보드(tier IS NULL) 제외
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
  'PRD TI-08) — 같은 시즌이면 current_tier는 단조 증가, 누적 거리가 줄어도 등급 유지. '
  'best_weekly_rank는 티어별 보드만 집계(52번). 멱등.';
