-- =============================================================================
-- Runnit :: 66. 무효 시즌 사용자를 스냅샷 랭킹에서 **빼고 다시 매긴다** (TRD §14 #31)
-- -----------------------------------------------------------------------------
-- 문제 (QA C-1 부수 논점, 2026-09-01)
--   58 이 `season_leaderboard_snapshots` 를 만들고, 59→60 이 무효 사용자를 **RLS 로
--   숨기는** 데까지 왔다. 그런데 숨기기만 하면 남는 사람들의 화면이 이렇게 된다:
--     · 3위가 무효 → 나머지에게는 **1·2·4위**로 보인다(4위 자리가 비어 있지도 않다)
--     · `participant_count` 는 무효 사용자를 **계속 센다** → "50명 중 4위"인데
--       실제 유효 참가자는 49명
--   즉 숨김은 "보이지 않게" 했을 뿐 **랭킹을 고치지 않았다**. PRD §8.1/§8.4 의
--   무효 처리는 "그 사람의 기록을 랭킹에서 제외한다"이지 "그 사람만 안 보인다"가
--   아니다. 소비 UI 가 아직 없어 실피해는 없지만, RK-10 화면이 붙는 순간 드러난다.
--
-- 접근 방식 선택 — **저장된 rank 를 다시 계산한다**(읽기 시점 뷰가 아니라)
--   후보 A. 소비 뷰에서 window 로 재랭크: `rank() over (...)` 를 조회 때마다.
--     → **채택하지 않았다.** 뷰는 기반 테이블의 RLS 를 그대로 받는다(58 의 C-1 이
--        정확히 그 함정이었다). 무효 행은 **본인에게만** 보이므로, 같은 뷰가
--        본인에게는 N행, 남에게는 N-1행을 주고 **사람마다 다른 등수**를 계산한다.
--        "내 화면의 4위가 남의 화면에서는 3위"가 되는, 59 가 겨우 닫은 부류의 버그다.
--   후보 B. 적재/무효 판정 시점에 rank·participant_count 를 **유효 행만으로 다시
--        매겨 저장**한다. 정책은 60 이 만든 순수 컬럼 술어 그대로 두고, 숨김은
--        숨김 역할만 한다.
--     → **채택.** 등수는 누가 보든 하나여야 하는 값이라 저장이 맞고, 재랭크에
--        필요한 정렬 키(거리·횟수·도달시각·이동시간·user_id)가 **전부 스냅샷 행
--        안에 있어** `runs` 를 다시 훑지 않고 테이블 안에서 닫힌다.
--
-- 무효 행 자신의 rank 는? → **null 로 비운다** (컬럼 not null 해제)
--   무효 사용자는 자기 행을 여전히 볼 수 있다(60 정책). 그 행에 옛 등수를 남겨 두면
--   "무효인데 12위"라는 모순된 화면이 되고, 0 이나 -1 같은 보초값은 언젠가 정렬에
--   섞인다. null 은 "이 시즌 순위가 없다"를 타입으로 말하는 유일한 방법이고,
--   클라이언트가 반드시 분기하게 만든다. CHECK 제약이 `is_voided ⇔ rank is null`
--   을 강제하므로 두 컬럼이 어긋날 수 없다.
--   `participant_count` 는 무효 행에도 **유효 참가자 수**를 넣는다 — "N명 중" 문구의
--   N 은 누구에게나 같아야 하고, 무효 사용자 화면에서도 그 시즌 규모는 사실이다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 66-1. rank 를 nullable 로 + 정합 CHECK
-- -----------------------------------------------------------------------------
alter table public.season_leaderboard_snapshots
  alter column rank drop not null;

-- 기존 무효 행이 있으면 먼저 비운다(현 시점 0행이지만 재실행·타 환경 대비).
update public.season_leaderboard_snapshots
   set rank = null
 where is_voided and rank is not null;

alter table public.season_leaderboard_snapshots
  drop constraint if exists season_snapshots_rank_voided_ck;

alter table public.season_leaderboard_snapshots
  add constraint season_snapshots_rank_voided_ck
  check ((is_voided and rank is null) or (not is_voided and rank is not null));

comment on column public.season_leaderboard_snapshots.rank is
  '해당 시즌·티어 안에서의 최종 순위(1부터). **무효 행(`is_voided`)은 null** — '
  '무효 사용자는 랭킹 계산에서 빠지므로 순위가 존재하지 않는다(마이그레이션 66, TRD §14 #31). '
  '유효 행의 순위는 무효 사용자를 제외하고 다시 매겨져 **1..N 이 끊기지 않는다** — '
  '3위가 무효가 되면 옛 4위가 3위가 된다. '
  '⚠️ 이 값을 직접 UPDATE 하지 마라. `_rerank_season_snapshot()` 이 유일한 산출 경로다.';

comment on column public.season_leaderboard_snapshots.participant_count is
  '해당 시즌·티어의 **유효 참가자 수**(무효 사용자 제외, 마이그레이션 66). '
  '무효 행에도 같은 값이 들어간다 — "N명 중" 의 N 은 누가 보든 같아야 한다.';

-- -----------------------------------------------------------------------------
-- 66-2. 재랭크 — 스냅샷 테이블 안에서 닫힌다
-- -----------------------------------------------------------------------------
-- 정렬 키는 58 의 적재 정렬과 **동일**해야 한다:
--   거리 desc → 러닝 횟수 asc → 도달 시각 asc → 이동 시간 asc → user_id asc
-- (user_id 까지 가면 전순서라 rank 와 row_number 가 일치한다.)
create or replace function public._rerank_season_snapshot(p_season_id text)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n integer := 0;
begin
  if p_season_id is null then
    return 0;
  end if;

  with valid_ranked as (
    select
      s.season_id,
      s.user_id,
      s.tier,
      -- 무효 행을 건너뛰며 세는 누적 카운트 = 유효 행들 사이에서의 1-based 위치.
      -- `rank() over` 를 그대로 쓰면 무효 행이 자리를 차지해 구멍이 남는다.
      case
        when s.is_voided then null
        else sum(case when s.is_voided then 0 else 1 end) over (
               partition by s.season_id, s.tier
               order by s.season_distance_meters desc,
                        s.run_count              asc,
                        s.reached_at             asc,
                        s.moving_seconds         asc,
                        s.user_id                asc
               rows between unbounded preceding and current row
             )::integer
      end as new_rank,
      (count(*) filter (where not s.is_voided) over (
         partition by s.season_id, s.tier
       ))::integer as new_pc
    from public.season_leaderboard_snapshots s
    where s.season_id = p_season_id
  )
  update public.season_leaderboard_snapshots t
     set rank              = v.new_rank,
         participant_count = v.new_pc
    from valid_ranked v
   where t.season_id = v.season_id
     and t.user_id   = v.user_id
     and (t.rank is distinct from v.new_rank
          or t.participant_count is distinct from v.new_pc);

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function public._rerank_season_snapshot(text) is
  '한 시즌의 스냅샷 순위를 **무효 사용자를 빼고** 다시 매긴다(마이그레이션 66, TRD §14 #31). '
  '유효 행은 티어별 1..N 연속, 무효 행은 rank null. `participant_count` 는 티어별 유효 참가자 수. '
  '`runs` 를 다시 읽지 않는다 — 정렬 키가 전부 스냅샷 행 안에 있어 테이블 안에서 닫힌다. '
  '멱등이며, 바뀐 행이 없으면 0 을 돌려준다. 반환값은 갱신된 행 수. '
  '호출 지점은 `snapshot_season_leaderboard()`(적재 직후)와 '
  '`set_season_history_voided()`(사후 무효/해제) 두 곳뿐이다.';

revoke execute on function public._rerank_season_snapshot(text)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 66-3. 적재 시점부터 무효를 빼고 매긴다
-- -----------------------------------------------------------------------------
-- 60 의 함수를 그대로 두고 뒤에서 `_rerank_season_snapshot` 을 부르는 방법도 있지만,
-- 그러면 "틀린 rank 로 한 번 넣고 곧바로 고치는" 왕복이 남는다. 처음부터 맞게 넣고,
-- 재랭크는 **사후 무효 판정 때만** 도는 게 맞다. (재실행 시 on conflict do nothing 이라
-- 기존 행은 흔들리지 않으므로, 부분 적재 뒤 상태를 위해 마지막에 재랭크도 한 번 부른다.)
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
      -- (66번) 무효 사용자는 순위를 갖지 않고, 유효 사용자의 순위를 밀지도 않는다.
      case
        when t.is_voided then null
        else sum(case when t.is_voided then 0 else 1 end) over (
               partition by t.tier
               order by t.dist_m     desc,
                        t.run_cnt    asc,
                        t.reached_at asc,
                        t.moving_s   asc,
                        t.user_id    asc
               rows between unbounded preceding and current row
             )::integer
      end                                                             as rnk,
      (count(*) filter (where not t.is_voided) over (partition by t.tier))::integer as pc
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

  -- 부분 적재(이전 실행이 중간에 끊겨 일부 행만 있는 경우) 뒤에도 저장된 순위가
  -- 전체와 정합하도록 마지막에 한 번 맞춘다. 새로 넣은 값이 이미 맞으면 0행 갱신.
  if v_count > 0 then
    perform public._rerank_season_snapshot(p_season_id);
  end if;

  return v_count;
end;
$$;

comment on function public.snapshot_season_leaderboard(text) is
  '한 시즌의 티어별 시즌 누적 거리 랭킹을 `season_leaderboard_snapshots` 에 영구 적재. '
  '`recompute_season_tier` 의 시즌 마감 지점에서만 호출되며 on conflict do nothing 이라 '
  '재실행해도 기존 행을 흔들지 않는다. 티어는 season_histories → profiles → '
  'tier_for_distance 3단 폴백. `is_voided` 는 적재 시점 값을 복사한다(마이그레이션 60). '
  '**무효 사용자는 순위 계산에서 제외**되어 유효 행의 rank 가 1..N 연속이고 '
  'participant_count 도 무효를 세지 않는다(마이그레이션 66, TRD §14 #31).';

revoke execute on function public.snapshot_season_leaderboard(text)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 66-4. 사후 무효 판정 — 두 테이블 갱신 + 재랭크까지 한 트랜잭션
-- -----------------------------------------------------------------------------
-- 60 이 만든 "무효 처리 단일 진입점" 계약을 그대로 이어받되, 이제 순위 재계산까지
-- 이 함수 안에서 끝난다. 무효화와 재랭크가 갈라지면 그 사이의 조회가 구멍 뚫린
-- 순위를 보게 되고, 그 창이 얼마나 짧든 "누가 보느냐에 따라 다른 등수"가 된다.
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
  v_n       integer := 0;
  v_touched integer := 0;
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
  -- CHECK(is_voided ⇔ rank is null) 때문에 무효로 바꿀 때는 rank 도 같은 UPDATE 에서
  -- 비워야 한다. 유효로 되돌릴 때는 임시로 0 을 넣지 않고 곧바로 재랭크가 채운다 —
  -- 그래서 이 UPDATE 는 무효화 방향에서만 rank 를 건드리고, 복구 방향은 66-2 가 맡는다.
  if p_voided then
    update public.season_leaderboard_snapshots s
       set is_voided = true,
           rank      = null
     where s.user_id   = p_user_id
       and s.season_id = p_season_id
       and s.is_voided is distinct from true;
  else
    -- 복구: is_voided 만 내리면 CHECK 위반(rank null 인데 유효)이므로,
    -- 재랭크가 채울 자리표시자를 같은 문장에서 넣는다(바로 뒤 재랭크가 확정한다).
    update public.season_leaderboard_snapshots s
       set is_voided = false,
           rank      = 1
     where s.user_id   = p_user_id
       and s.season_id = p_season_id
       and s.is_voided is distinct from false;
  end if;
  get diagnostics v_touched = row_count;

  -- 한 사람의 무효 여부가 바뀌면 **그 티어 전원의 순위**가 밀린다. 시즌 단위로 다시 매긴다.
  if v_touched > 0 then
    perform public._rerank_season_snapshot(p_season_id);
  end if;

  return v_n;
end;
$$;

comment on function public.set_season_history_voided(uuid, text, boolean) is
  '시즌 마감 결과의 무효 처리(PRD §8.1/§8.4) **단일 진입점**. `season_histories` 와 '
  '`season_leaderboard_snapshots` 의 `is_voided` 를 한 트랜잭션에서 함께 갱신하고, '
  '이어서 `_rerank_season_snapshot()` 으로 그 시즌의 순위를 다시 매긴다 — '
  '한 사람이 빠지면 그 티어 전원의 등수가 밀리기 때문이다(마이그레이션 66, TRD §14 #31). '
  '`p_voided = false` 로 부르면 무효를 해제하고 순위에 복귀시킨다. '
  '반환값은 갱신된 `season_histories` 행 수. '
  '⚠️ 운영에서 `season_histories` 를 직접 UPDATE 하면 스냅샷이 공개된 채, 순위는 '
  '구멍이 뚫린 채 남는다.';

revoke execute on function public.set_season_history_voided(uuid, text, boolean)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 66-5. 기존 행 정합
-- -----------------------------------------------------------------------------
-- 현 시점 0행이지만, 다른 환경에서 이미 적재된 스냅샷이 있으면 옛 규칙(무효 포함
-- 랭킹)으로 매겨져 있다. 시즌별로 한 번씩 다시 매긴다.
do $$
declare
  s record;
begin
  for s in select distinct season_id from public.season_leaderboard_snapshots loop
    perform public._rerank_season_snapshot(s.season_id);
  end loop;
end $$;
