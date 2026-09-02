-- =============================================================================
-- Runnit :: 58. 과거 시즌 전체 랭킹 스냅샷 (PRD RK-10 / HI-06, ARCHITECTURE §13-4)
-- -----------------------------------------------------------------------------
-- 배경
--   `season_histories` 는 **본인의** 시즌 마감 결과(최종 티어·거리·최고 주간 순위)만
--   담는다. PRD RK-10("시즌 누적 거리 랭킹, 티어 내")과 HI-06 의 "지난 시즌 내가
--   몇 등이었나"를 답하려면 마감 시점의 **티어별 전체 순위**가 필요한데, 그것을
--   보존하는 곳이 없었다. `leaderboard_entries` 는 주간 보드이고
--   `refresh_leaderboard` 가 계속 덮어쓰므로 시즌 스냅샷의 자리가 아니다.
--
-- 왜 지금 만드는가 / 소급 백필이 없는 이유
--   첫 시즌 2026-Q3 는 2026-09-30 종료로 **아직 마감된 시즌이 0개**다. 소급 복원할
--   과거가 없으므로 전진 구축만 한다. 첫 마감(cron `runnit-season-reset-30`,
--   `5 15 30 6,9 *` = 10/1 00:05 KST)에 자동으로 채워진다.
--
-- 적재 시점 — `recompute_season_tier` 의 `season_histories` 마감 지점에 붙인다
--   그 지점이 "지난 시즌이 방금 끝났음"을 아는 유일한 곳이고, `season_histories` 와
--   **같은 트랜잭션·같은 멱등 규약**(on conflict do nothing)을 공유해야 두 기록이
--   어긋나지 않는다.
--
--   ⚠️ 순서 의존이 있고, 그것이 오히려 정확성의 근거다. `recompute_season_tier` 는
--   사용자당 1회 호출이고 그 안에서 `profiles.current_tier` 를 새 시즌 bronze 로
--   리셋한다. 스냅샷은 **가장 먼저 마감되는 사용자의 호출**에서 전체 모집단에 대해
--   한 번 찍히며, 그 시점에 나머지 사용자의 `profiles` 는 아직 지난 시즌 티어를
--   들고 있다 — 즉 "마감 시점 티어"가 그대로 잡힌다. 두 번째 사용자부터는
--   `season_id` 존재 검사로 즉시 빠져나간다(`reset_stale_seasons` 가 N명을 도는
--   동안 전체 재집계가 N번 돌지 않도록).
--
--   그래도 순서에 의존하지 않도록 티어 결정은 3단 폴백을 쓴다:
--     ① `season_histories.final_tier`  — 이미 마감된 사용자의 정본(불변)
--     ② `profiles.current_tier`        — 아직 그 시즌에 머물러 있는 사용자
--     ③ `tier_for_distance(시즌 거리)` — 둘 다 없을 때(티어는 절대평가라 재현 가능)
--   ③ 은 강등 없음 규칙(마이그레이션 43) 때문에 부정 판정으로 거리가 깎인 사용자에
--   대해 실제보다 낮게 나올 수 있으나, ①②가 비는 경로 자체가 정상 운영에는 없다.
--
-- 랭킹 산정 기준 (PRD §8.2 · §8.3 · §8.5)
--   그 시즌 `runs` 의 누적 거리 — `started_at` 기준 귀속, `status='completed'`,
--   `is_flagged=false`, `activity_type <> 'indoor_run'`. 파티션은 티어.
--   타이브레이크는 주간 랭킹과 동일: 거리 desc → 러닝 횟수 asc → 도달 시각 asc →
--   총 이동 시간 asc → user_id asc. `user_id` 폴백이 있으므로 공동 순위가 없다.
-- =============================================================================

create table if not exists public.season_leaderboard_snapshots (
  season_id              text        not null,
  user_id                uuid        not null
                           references public.profiles(id) on delete cascade,
  tier                   public.tier not null,
  rank                   integer     not null,
  season_distance_meters double precision not null,
  run_count              integer     not null default 0,
  moving_seconds         integer     not null default 0,
  reached_at             timestamptz,
  participant_count      integer     not null,
  computed_at            timestamptz not null default now(),
  primary key (season_id, user_id)
);

comment on table public.season_leaderboard_snapshots is
  '시즌 마감 시점의 티어별 시즌 누적 거리 랭킹 영구 스냅샷(마이그레이션 58, PRD RK-10 / HI-06). '
  '쓰기는 `snapshot_season_leaderboard()` 뿐이고 그 함수는 `recompute_season_tier` 의 '
  '시즌 마감 지점에서만 호출된다 — `season_histories` 와 같은 트랜잭션·같은 멱등 규약. '
  '한 번 적재된 행은 갱신하지 않는다(on conflict do nothing): 마감 결과는 사후 편집으로 '
  '흔들리면 안 되는 확정 기록이다.';
comment on column public.season_leaderboard_snapshots.tier is
  '마감 시점 티어. `season_histories.final_tier` → `profiles.current_tier` → '
  '`tier_for_distance()` 3단 폴백으로 결정한다.';
comment on column public.season_leaderboard_snapshots.rank is
  '티어 내 순위. PRD §8.2 타이브레이크 + user_id 폴백이라 공동 순위가 없다.';
comment on column public.season_leaderboard_snapshots.participant_count is
  '같은 시즌·같은 티어의 모집단. PRD RK-04 의 "상위 N%" 표기에 필요하다.';
comment on column public.season_leaderboard_snapshots.reached_at is
  '그 시즌 마지막 집계 대상 러닝의 started_at (누적 거리가 최종값에 도달한 시점) — '
  'PRD §8.2 ② 타이브레이크 근거. `leaderboard_entries.reached_at` 과 같은 정의.';

create index if not exists idx_season_snapshots_season_tier_rank
  on public.season_leaderboard_snapshots (season_id, tier, rank);
create index if not exists idx_season_snapshots_user
  on public.season_leaderboard_snapshots (user_id, season_id desc);

alter table public.season_leaderboard_snapshots enable row level security;

-- 공개 범위는 `season_histories_select_visible` 와 동일하게 맞춘다:
--   authenticated 에게 타인 행도 공개, anon 은 차단, 무효 시즌(is_voided)은 본인만.
drop policy if exists season_snapshots_select_visible
  on public.season_leaderboard_snapshots;
create policy season_snapshots_select_visible
  on public.season_leaderboard_snapshots
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or not exists (
      select 1 from public.season_histories sh
      where sh.user_id   = season_leaderboard_snapshots.user_id
        and sh.season_id = season_leaderboard_snapshots.season_id
        and sh.is_voided
    )
  );
-- INSERT/UPDATE/DELETE 정책 없음 = SECURITY DEFINER 배치만 쓴다.

-- -----------------------------------------------------------------------------
-- 58-2. 스냅샷 적재 함수
-- -----------------------------------------------------------------------------
create or replace function public.snapshot_season_leaderboard(p_season_id text)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_end   timestamptz;
  v_count integer := 0;
begin
  if p_season_id is null then
    return 0;
  end if;

  v_start := public.season_start(p_season_id);  -- 형식 검증도 여기서 걸린다
  v_end   := public.season_end(p_season_id);

  with base as (
    select
      r.user_id,
      sum(r.distance_meters)                      as dist_m,
      count(*)::integer                           as run_cnt,
      coalesce(sum(r.moving_seconds), 0)::integer as moving_s,
      max(r.started_at)                           as reached_at
    from public.runs r
    where r.status        = 'completed'
      and r.is_flagged    = false
      and r.activity_type <> 'indoor_run'
      and r.started_at   >= v_start
      and r.started_at   <  v_end
    group by r.user_id
  ),
  tiered as (
    select
      b.*,
      coalesce(
        (select sh.final_tier from public.season_histories sh
          where sh.user_id = b.user_id and sh.season_id = p_season_id),
        (select p.current_tier from public.profiles p
          where p.id = b.user_id and p.tier_season_id = p_season_id),
        public.tier_for_distance(b.dist_m)
      ) as tier
    from base b
    where b.dist_m > 0
      and exists (select 1 from public.profiles p where p.id = b.user_id)
  ),
  ranked as (
    select
      t.*,
      rank() over (
        partition by t.tier
        order by t.dist_m     desc,
                 t.run_cnt    asc,
                 t.reached_at asc,
                 t.moving_s   asc,
                 t.user_id    asc
      )::integer                              as rnk,
      (count(*) over (partition by t.tier))::integer as pc
    from tiered t
  )
  insert into public.season_leaderboard_snapshots (
    season_id, user_id, tier, rank, season_distance_meters,
    run_count, moving_seconds, reached_at, participant_count, computed_at
  )
  select
    p_season_id, k.user_id, k.tier, k.rnk, k.dist_m,
    k.run_cnt, k.moving_s, k.reached_at, k.pc, now()
  from ranked k
  on conflict (season_id, user_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.snapshot_season_leaderboard(text) is
  '한 시즌의 티어별 시즌 누적 거리 랭킹을 `season_leaderboard_snapshots` 에 영구 적재. '
  '`recompute_season_tier` 의 시즌 마감 지점에서만 호출되며 on conflict do nothing 이라 '
  '재실행해도 기존 행을 흔들지 않는다. 티어는 season_histories → profiles → '
  'tier_for_distance 3단 폴백.';

revoke execute on function public.snapshot_season_leaderboard(text)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 58-3. `recompute_season_tier` 에 스냅샷 적재를 연결
-- -----------------------------------------------------------------------------
-- 22/43/52 의 본문을 그대로 두고 `season_histories` insert 직후에 4줄을 더한다.
-- 존재 검사(`not exists ... where season_id = v_prev_season`)로 `reset_stale_seasons`
-- 가 N명을 도는 동안 전체 재집계가 N번 돌지 않게 한다 — PK 선두 컬럼 인덱스 조회라
-- 비용은 사실상 0이다.
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
  select p.tier_season_id, p.current_tier, p.season_distance_meters
    into v_prev_season, v_prev_tier, v_prev_dist
    from public.profiles p
   where p.id = p_user_id
     for update;

  if not found then
    return;
  end if;

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

    -- (58번) 시즌 전체 랭킹 스냅샷 — season_histories 와 같은 트랜잭션.
    -- 가장 먼저 마감되는 사용자의 호출에서 전체 모집단에 대해 한 번만 찍는다.
    if not exists (
      select 1 from public.season_leaderboard_snapshots s
       where s.season_id = v_prev_season
    ) then
      perform public.snapshot_season_leaderboard(v_prev_season);
    end if;
  end if;

  select coalesce(sum(r.distance_meters), 0)
    into v_dist
    from public.runs r
   where r.user_id       = p_user_id
     and r.status        = 'completed'
     and r.is_flagged    = false
     and r.activity_type <> 'indoor_run'
     and r.started_at   >= v_start
     and r.started_at   <  v_end;

  v_new_tier := public.tier_for_distance(v_dist);

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

  if v_new_tier > v_prev_tier then
    insert into public.tier_change_history (user_id, season_id, tier, reached_at)
    values (p_user_id, v_season, v_new_tier, p_at)
    on conflict (user_id, season_id, tier) do nothing;
  end if;
end;
$$;

comment on function public.recompute_season_tier(uuid, timestamptz) is
  '시즌 누적 거리 재계산 + 티어 확정(PRD TI-03, 마이그레이션 22/43/52/58). 시즌 경계를 '
  '넘으면 지난 시즌을 `season_histories` 에 마감하고(멱등) **같은 트랜잭션에서** '
  '`season_leaderboard_snapshots` 에 티어별 전체 랭킹을 한 번 찍는다(58번, PRD RK-10). '
  '같은 시즌 안에서는 강등하지 않는다(43번).';

revoke execute on function public.recompute_season_tier(uuid, timestamptz)
  from public, anon, authenticated;
