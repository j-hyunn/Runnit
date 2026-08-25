-- =============================================================================
-- Runnit :: 34. tier_change_history — "상승"할 때만 기록하도록 정정 + 백필 취소
-- -----------------------------------------------------------------------------
-- 근거: 오케스트레이터 경유 사용자 추가 지시(2026-08-25, 33번 적용 직후) —
--   "recompute_season_tier에서 티어가 **상승**할 때만 이력에 INSERT해야 한다.
--    매 recompute 호출마다 기록하면 안 된다."
--   "season_histories는 마감 시점 최종 티어 스냅샷만 가지고 있어 소급 이력 복원
--    근거로 못 쓴다 — 억지로 역산하지 말고 '이 테이블 생성 이후부터 정상 작동,
--    기존 유저는 소급 불가'라고 솔직히 문서화해라."
--
-- 33번에서 무엇이 문제였나
--   33번은 "매 호출마다 무조건 INSERT 시도 + UNIQUE(user_id, season_id, tier) +
--   ON CONFLICT DO NOTHING"으로 막았다. 이는 "같은 시즌·같은 티어의 반복 기록"은
--   막아주지만, 33-5 백필 단계에서 이미 플래티넘인 기존 유저(a8 등)에게 "지금"을
--   근사 도달 시각으로 강제로 1행씩 만들어 넣었다 — 이건 "상승"이 아니라 "이미
--   그 티어였던 상태의 재확인"이다. 사용자가 명시적으로 원한 건 정반대다:
--   진짜 상승 이벤트만 기록하고, 기존 유저는 근사치조차 만들지 말라는 것.
--
-- 이번에 바꾼 것
--   1) recompute_season_tier: 이력 INSERT를 "v_new_tier > v_prev_tier(엄격한 상승)"
--      가드 안으로 옮겼다. public.tier enum은 선언 순서(bronze<silver<gold<platinum)로
--      비교 연산자가 작동하므로 하드코딩 없이 순수 비교로 "상승"을 판별할 수 있다.
--      - 시즌 경계를 넘어간 첫 recompute에서는 v_prev_tier가 "지난 시�즌의 티어"이고
--        v_new_tier는 새 시즌 시작값(보통 bronze)이라 대개 상승이 아니므로 기록되지
--        않는다 — 다음 recompute부터 새 시즌 기준으로 다시 정상적으로 상승을 감지한다.
--      - 강등 후 재상승 시에는 이미 그 티어 행이 있으면 ON CONFLICT DO NOTHING이
--        그대로 안전망 역할을 한다(레이스 방지 목적으로 유지).
--   2) 33-5 백필 do-block으로 만들어졌던 근사 행을 전부 삭제한다 — "지금"이라는
--      근사 시각은 상승 이벤트가 아니므로 애초에 있으면 안 됐다. 대신 이 사실을
--      명시적으로 문서화한다:
--        **이 테이블 생성(2026-08-25) 이전에 이미 어떤 티어에 도달해 있던 기존
--        유저는, 그 도달이 "이 테이블이 생긴 이후 처음으로 다시 그 티어로 상승"하는
--        사건이 아니므로 이력이 절대 생기지 않는다.** 예를 들어 이미 플래티넘인
--        유저는 이번 시즌 동안 강등(기록 삭제 등) 없이는 다시 "플래티넘으로 상승"할
--        기회 자체가 없어 sevent_tier_early를 이번 시즌엔 받을 수 없다 — 정확한
--        도달 시각을 모르는 상태에서 억지로 근사치를 만드는 것보다 정직한 결과다.
--        다음 시즌부터 티어에 오르는 모든 유저는 정확하게 기록된다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 34-1. 33번 백필로 생성된 근사 행 전량 삭제
-- -----------------------------------------------------------------------------
-- tier_change_history는 33번에서 이번에 막 만든 테이블이고, 지금까지 유일하게
-- 행을 채운 경로가 33-5 백필 do-block이었다(그 외 수동 검증 호출은 이미 존재하는
-- 조합이라 전부 conflict-skip 됐다) — 그러므로 전체 삭제가 안전하다.
delete from public.tier_change_history;

-- -----------------------------------------------------------------------------
-- 34-2. recompute_season_tier 재정의 — "엄격한 상승"일 때만 이력 삽입
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

  perform set_config('runnit.server_write', 'on', true);

  update public.profiles p
     set season_distance_meters = v_dist,
         current_tier           = v_new_tier,
         tier_season_id         = v_season,
         updated_at             = now()
   where p.id = p_user_id;

  perform set_config('runnit.server_write', 'off', true);

  -- ── 4) (34번 정정) 티어 "상승" 이력만 기록 ─────────────────────────────────
  -- v_prev_tier는 바로 위 UPDATE 이전에 읽은 갱신 전 값이다(같은 시즌이면 직전
  -- 상태, 시즌이 갈렸으면 지난 시즌 마지막 값). public.tier enum은 선언 순서
  -- (bronze<silver<gold<platinum)로 비교되므로 하드코딩 없이 "상승" 판별이 된다.
  -- 상승이 아니면(동일 유지, 강등, 시즌 경계를 넘어 낮은 값으로 재시작) 아무것도
  -- 하지 않는다 — 그래서 매 recompute 호출마다 반복 기록되지 않는다.
  -- ON CONFLICT DO NOTHING은 동시 호출 레이스에 대한 안전망으로 유지한다
  -- (상승 판정과 실제 INSERT 사이에 다른 트랜잭션이 끼어들 이론적 여지 대비).
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
  '티어가 실제로 "상승"할 때만 tier_change_history에 최초 도달 시각 기록. 멱등.';

-- -----------------------------------------------------------------------------
-- 34-3. 테이블 코멘트 정정 — 백필 언급 제거, 소급 불가를 명확히
-- -----------------------------------------------------------------------------
comment on table public.tier_change_history is
  '시즌 내 티어 "상승" 이력 — recompute_season_tier가 티어가 실제로 오를 때만 기록(동일 유지/강등/시즌 '
  '경계 재시작 시에는 기록하지 않음). UNIQUE(user_id, season_id, tier) + ON CONFLICT DO NOTHING은 '
  '동시성 안전망. 이 테이블은 2026-08-25(마이그레이션 33/34) 이후 상승분만 담는다 — 그 이전에 이미 '
  '어떤 티어에 도달해 있던 기존 유저는 소급 복원 불가(season_histories는 시즌 마감 스냅샷만 가지고 '
  '있어 도달 "시각"을 역산할 근거가 없다). 근사치도 만들지 않는다 — 이후 실제로 다시 그 티어로 '
  '오르는 순간(예: 다음 시즌, 또는 강등 후 재상승)부터 정확하게 기록된다.';
comment on column public.tier_change_history.reached_at is
  '해당 (user_id, season_id, tier)로 처음 "상승"한 시각. 이후 강등되었다가 같은 티어로 재상승해도 '
  '갱신되지 않는다(최초 상승 시각만 보존).';
