-- =============================================================================
-- Runnit :: 60. 시즌 스냅샷 무효 판정을 컬럼으로 (TRD §14 #32 해소 — 옵션 B)
-- -----------------------------------------------------------------------------
-- 배경
--   59 는 C-1(무효 시즌 스냅샷이 전원에게 공개되던 RLS 반전)을 SECURITY DEFINER
--   헬퍼 `_season_history_voided()` 로 고쳤다. 정확했지만 대가가 있었다 — RLS
--   정책식은 **호출자 권한**으로 평가되므로 헬퍼에 `grant execute to authenticated`
--   가 필수이고, `public` 스키마 함수는 PostgREST 가 `/rest/v1/rpc/...` 로 자동
--   노출한다. 결과적으로 uuid 를 아는 사용자가 임의 `(user_id, season_id)` 의 무효
--   여부를 boolean 으로 조회할 수 있었다 — 좁지만 **부정 판정 플래그의 노출**이고,
--   하필 `season_histories` 의 RLS 가 감추려던 바로 그 사실이다(advisor 신규 WARN 1건).
--
-- 결정 (사용자 승인, 옵션 B): **교차 테이블 참조 자체를 없앤다.**
--   무효 여부를 스냅샷 행에 **복사해 두고**, 정책을 `season_histories_select_visible`
--   와 **같은 형태의 순수 컬럼 술어**로 되돌린다. 그러면
--     - 정책 평가에 함수가 필요 없다 → 헬퍼 DROP → RPC 노출 소멸 → advisor 원복
--     - 두 테이블의 정책이 **같은 모양**이 되어, 59 가 지적한 "형태가 달라서 생긴
--       반전"이라는 함정 자체가 사라진다(다시 서브쿼리를 쓸 유인이 없다)
--
-- 대가와 그 처리 — 복제본은 원본과 어긋날 수 있다
--   `season_histories.is_voided` 는 **마감 이후에** 세워질 수 있다(부정 판정·이의
--   제기, PRD §8.1/§8.4). 그런데 이 프로젝트에는 그 플래그를 세우는 **코드 경로가
--   없다** — 검색 결과 `is_voided` 는 읽기(뱃지 조건 2곳·RLS)만 있고 쓰기는 순수
--   수동 SQL 이다. 즉 "무효 판정 시 스냅샷도 같이 갱신하라"를 주석으로만 남기면
--   반드시 잊힌다.
--
--   그래서 **단일 진입점**을 만든다: `set_season_history_voided()` 가 두 테이블을
--   한 트랜잭션에서 함께 갱신한다. 운영은 이 함수만 부르면 되고, 컬럼 코멘트가
--   그 사실을 가리킨다. (직접 UPDATE 를 막지는 않는다 — 막으려면 트리거가 필요한데,
--   쓰기 경로가 수동 SQL 하나뿐인 현 시점에 그 복잡도는 과하다.)
--
-- ⚠️ 여전히 열린 논점 (TRD §14 #31, 이번 범위 아님)
--   무효 사용자를 **숨기기만 하면** 그 티어의 `rank`·`participant_count` 에 구멍이
--   남는다(3위가 무효면 1·2·4위로 보인다). 재랭크 여부는 RK-10 UI 라운드에서 확정.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 60-1. 컬럼 추가 + 기존 행 동기화
-- -----------------------------------------------------------------------------
alter table public.season_leaderboard_snapshots
  add column if not exists is_voided boolean not null default false;

comment on column public.season_leaderboard_snapshots.is_voided is
  '적재 시점의 `season_histories.is_voided` 복사본(마이그레이션 60). SELECT 정책이 '
  '이 컬럼만 보므로 `season_histories` 를 참조할 필요가 없다 — 59 의 SECURITY DEFINER '
  '헬퍼(와 그 RPC 노출)를 없애기 위한 비정규화다. '
  '⚠️ **마감 이후 무효 판정을 내릴 때는 `season_histories` 만 고치면 안 된다.** '
  '`set_season_history_voided(user_id, season_id, voided)` 를 쓰면 두 테이블이 함께 '
  '갱신된다. 직접 UPDATE 하면 스냅샷이 계속 공개된 채로 남는다.';

-- 현 시점 스냅샷은 0행이지만(첫 적재는 2026-09-30 시즌 마감), 재실행·다른 환경에서
-- 이미 행이 있을 수 있으므로 원본과 맞춘다.
update public.season_leaderboard_snapshots s
   set is_voided = true
  from public.season_histories sh
 where sh.user_id   = s.user_id
   and sh.season_id = s.season_id
   and sh.is_voided
   and s.is_voided = false;

-- -----------------------------------------------------------------------------
-- 60-2. 정책 교체 — `season_histories_select_visible` 와 같은 형태
-- -----------------------------------------------------------------------------
drop policy if exists season_snapshots_select_visible
  on public.season_leaderboard_snapshots;

create policy season_snapshots_select_visible
  on public.season_leaderboard_snapshots
  for select to authenticated
  using (is_voided = false or user_id = (select auth.uid()));

-- 59 의 헬퍼 제거 — 정책이 더 이상 부르지 않으므로 RPC 노출도 사라진다.
drop function if exists public._season_history_voided(uuid, text);

comment on table public.season_leaderboard_snapshots is
  '시즌 마감 시점의 티어별 시즌 누적 거리 랭킹 영구 스냅샷(마이그레이션 58, PRD RK-10 / HI-06). '
  '쓰기는 `snapshot_season_leaderboard()` 뿐이고 그 함수는 `recompute_season_tier` 의 '
  '시즌 마감 지점에서만 호출된다 — `season_histories` 와 같은 트랜잭션·같은 멱등 규약. '
  '한 번 적재된 행은 갱신하지 않는다(on conflict do nothing). '
  '공개 범위·정책 형태 모두 `season_histories` 와 동일하다 — 무효 여부를 `is_voided` '
  '컬럼으로 들고 있어 교차 테이블 참조가 없다(마이그레이션 60). '
  '⚠️ 이 정책을 `season_histories` 서브쿼리로 되돌리면 차단이 조용히 반전된다 '
  '(RLS 정책식 안의 서브쿼리는 참조 테이블의 RLS 를 그대로 받는다 — 58 의 실제 버그, QA C-1).';

-- -----------------------------------------------------------------------------
-- 60-3. 적재 시점에 무효 여부를 복사
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
      ) as tier,
      -- (60번) 적재 시점의 무효 여부를 복사. 마감 직후에는 보통 false 이고,
      -- 사후 무효 판정은 `set_season_history_voided()` 가 두 테이블을 함께 고친다.
      coalesce(
        (select sh.is_voided from public.season_histories sh
          where sh.user_id = b.user_id and sh.season_id = p_season_id),
        false
      ) as is_voided
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
      )::integer                                     as rnk,
      (count(*) over (partition by t.tier))::integer as pc
    from tiered t
  )
  insert into public.season_leaderboard_snapshots (
    season_id, user_id, tier, rank, season_distance_meters,
    run_count, moving_seconds, reached_at, participant_count, is_voided, computed_at
  )
  select
    p_season_id, k.user_id, k.tier, k.rnk, k.dist_m,
    k.run_cnt, k.moving_s, k.reached_at, k.pc, k.is_voided, now()
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
  'tier_for_distance 3단 폴백. `is_voided` 는 적재 시점 값을 복사한다(마이그레이션 60).';

revoke execute on function public.snapshot_season_leaderboard(text)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 60-4. 무효 판정 단일 진입점 — 두 테이블을 함께 갱신
-- -----------------------------------------------------------------------------
create or replace function public.set_season_history_voided(
  p_user_id   uuid,
  p_season_id text,
  p_voided    boolean default true
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer := 0;
begin
  if p_user_id is null or p_season_id is null then
    return 0;
  end if;

  update public.season_histories sh
     set is_voided = p_voided
   where sh.user_id   = p_user_id
     and sh.season_id = p_season_id
     and sh.is_voided is distinct from p_voided;
  get diagnostics v_n = row_count;

  -- 스냅샷 행이 없을 수도 있다(그 시즌에 유효 러닝이 0이면 애초에 적재되지 않는다).
  update public.season_leaderboard_snapshots s
     set is_voided = p_voided
   where s.user_id   = p_user_id
     and s.season_id = p_season_id
     and s.is_voided is distinct from p_voided;

  return v_n;
end;
$$;

comment on function public.set_season_history_voided(uuid, text, boolean) is
  '시즌 마감 결과의 무효 처리(PRD §8.1/§8.4) **단일 진입점**. `season_histories` 와 '
  '`season_leaderboard_snapshots` 의 `is_voided` 를 한 트랜잭션에서 함께 갱신한다 — '
  '60번이 스냅샷에 무효 여부를 비정규화하면서 두 곳이 갈라질 수 있게 됐고, 이 함수가 '
  '그 유일한 정합 경로다. 반환값은 갱신된 `season_histories` 행 수. '
  '⚠️ 운영에서 `season_histories` 를 직접 UPDATE 하면 스냅샷이 계속 공개된 채 남는다.';

revoke execute on function public.set_season_history_voided(uuid, text, boolean)
  from public, anon, authenticated;
