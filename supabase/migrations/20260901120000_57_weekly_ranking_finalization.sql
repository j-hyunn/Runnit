-- =============================================================================
-- Runnit :: 57. 주간 랭킹 확정 배치 (TRD §14 #12) + 확정 주 필터 (TRD §14 #23)
-- -----------------------------------------------------------------------------
-- 배경
--   TRD §14 #12: 주간 랭킹 "확정" 배치가 pg_cron 에 없었다. 정본 스케줄은
--   **매주 월요일 KST 00:10 = `10 15 * * 0` UTC** 이고, 지금까지는 5분 주기
--   `refresh_all_leaderboards`(화면 신선도용)와 매시 `runnit-rank-notify` 에만
--   의존했다. 그래서 아래 2건이 미구현으로 딸려 있었다.
--     (a) RK-06 주간 상위권 뱃지가 "주간 확정 직후"가 아니라 **다음 러닝 때** 발급됨
--     (b) NT-06 의 `badge_level:weekly:{week_id}` dedupe 키를 쓰는 발화점이 없음
--
--   TRD §14 #23: `season_weekly_rank_lte` 판정에
--     결함 #1 최소 모집단 게이트  → **이미 해소**(마이그레이션 41: top1 N>=10 /
--                                    top10·top10pct N>=20). 라이브 정의 확인함.
--     결함 #2 "확정된 지난 주" 필터 → **미해소**. 진행 중인 주의 일시적 1위로도
--                                    영구 뱃지가 나갔다. 이 마이그레이션이 닫는다.
--
-- 설계 결정 1 — "확정" 신호를 어디에 둘 것인가
--   두 곳 모두에 둔다. 역할이 다르다.
--   ① `leaderboard_entries.finalized_at`  — **행 단위 확정 도장**.
--      뱃지 판정(`evaluate_badge_condition`)이 술어 한 줄(`finalized_at is not null`)로
--      쓰는 hot path 다. 별도 테이블을 조인하면 이 함수가 뱃지 146종을 도는 루프
--      안에서 매번 조인 비용을 문다. 컬럼은 `refresh_leaderboard` 의 upsert
--      update 목록에 없으므로 이후 재집계가 도장을 지우지 않는다.
--   ② `weekly_ranking_finalizations(period_start, tier_key, ...)` — **주×티어 원장**.
--      "그 주가 확정되었는가"를 참가자 0명인 티어까지 포함해 답할 수 있는 유일한
--      신호이며(0명이면 `leaderboard_entries` 에 행 자체가 없다), 모집단·확정 시각을
--      감사 가능하게 남긴다. 작업 2(시즌 스냅샷)와 클라이언트의 "지난 주 확정 랭킹"
--      질의가 이 테이블을 기준으로 삼는다.
--
-- 설계 결정 2 — 5분 주기 `runnit-leaderboard` 는 그대로 둔다
--   주중 실시간성(홈 화면의 "앞사람까지 0.8km")은 그 배치가 담당한다. 확정 배치는
--   그 위에 얹는 별도 job 이고, 지난 주 구간만 건드린다(`refresh_leaderboard` 의
--   꼬리 DELETE 는 `period_start` 로 한정되므로 서로 침범하지 않는다).
--
-- 설계 결정 3 — NT-06 발화를 확정 시각(00:10 KST)에 하지 않는다
--   §6-N.5 "방해 금지"(배치 계열 KST 08~22)는 새벽 발송을 금지한다. NT-06 이
--   트리거 계열일 때 심야가 허용된 근거는 "사용자가 방금 러닝을 끝낸 순간"인데,
--   월요일 00:10 확정은 그 문맥이 아니다. 그래서
--     - `finalize_weekly_ranking()`  : 재집계 + 확정 도장 + RK-06 뱃지 지급 (00:10 KST)
--     - `notify_weekly_rank_badges()`: NT-06 발행. `_batch_hours_ok` 로 자가 게이트
--   로 나누고, 후자를 **월요일 08:00 KST** 에 한 번 더 돌린다. 확정 배치도 후자를
--   호출하지만 그 시각엔 게이트에 걸려 0 을 반환한다. dedupe 키가 같으므로
--   두 번 호출돼도 알림은 1건이다.
--
-- 멱등성
--   - 재집계: `refresh_leaderboard` 의 upsert (기존 경로)
--   - 확정 도장: `coalesce(finalized_at, now())` — 최초 확정 시각을 덮어쓰지 않는다
--   - 원장: `on conflict (period_start, tier_key) do update` — `finalized_at` 은 보존
--   - 뱃지: `evaluate_badges` → `user_badges on conflict do nothing`
--   - 알림: `enqueue_notification` → `notifications (user_id, dedupe_key)` unique
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 57-1. 확정 도장 컬럼
-- -----------------------------------------------------------------------------
alter table public.leaderboard_entries
  add column if not exists finalized_at timestamptz;

comment on column public.leaderboard_entries.finalized_at is
  '주간 랭킹 확정 시각(마이그레이션 57). null = 아직 진행 중이거나 확정 대상이 아닌 '
  '기간. `finalize_weekly_ranking()` 만 값을 쓰며 최초 확정 시각을 덮어쓰지 않는다. '
  '`season_weekly_rank_lte` 뱃지 판정의 "확정된 지난 주" 필터가 이 컬럼을 본다 '
  '(TRD §14 #23 결함 #2). `refresh_leaderboard` 의 upsert update 목록에 없으므로 '
  '주중 5분 재집계가 이 도장을 지우지 않는다.';

-- 확정 주 조회(뱃지 판정·클라이언트 "지난 주 랭킹")를 위한 부분 인덱스.
create index if not exists idx_leaderboard_entries_finalized
  on public.leaderboard_entries (period, metric, scope, period_start, tier)
  where finalized_at is not null;

-- -----------------------------------------------------------------------------
-- 57-2. 주×티어 확정 원장
-- -----------------------------------------------------------------------------
create table if not exists public.weekly_ranking_finalizations (
  period_start      timestamptz not null,
  tier_key          text        not null,   -- tier::text 또는 '_all'(통합 보드)
  tier              public.tier,            -- null = 통합 보드
  week_id           text        not null,   -- KST ISO 주 키 `YYYY-Www` (week_id_at)
  participant_count integer     not null default 0,
  finalized_at      timestamptz not null default now(),
  recomputed_at     timestamptz not null default now(),
  primary key (period_start, tier_key)
);

comment on table public.weekly_ranking_finalizations is
  '주간 랭킹 확정 원장(마이그레이션 57, TRD §14 #12). 한 행 = (주, 티어) 하나의 확정 '
  '사실. `leaderboard_entries.finalized_at` 이 행 단위 도장이라면 이 테이블은 **주 단위 '
  '신호**다 — 참가자 0명인 티어는 leaderboard_entries 에 행이 없으므로 "그 주가 '
  '확정되었는가"를 답할 수 있는 곳이 여기뿐이다. 쓰기는 `finalize_weekly_ranking()` 만.';
comment on column public.weekly_ranking_finalizations.finalized_at is
  '최초 확정 시각. 배치 재실행에도 바뀌지 않는다(재실행은 recomputed_at 만 갱신).';
comment on column public.weekly_ranking_finalizations.recomputed_at is
  '마지막 재집계 시각. finalized_at 과 다르면 확정 후 재계산이 있었다는 뜻.';

create index if not exists idx_weekly_ranking_finalizations_week
  on public.weekly_ranking_finalizations (week_id);

alter table public.weekly_ranking_finalizations enable row level security;

-- 개인정보가 없는 집계 사실이라 leaderboard_entries 와 같은 공개 범위를 준다.
drop policy if exists weekly_ranking_finalizations_select_all
  on public.weekly_ranking_finalizations;
create policy weekly_ranking_finalizations_select_all
  on public.weekly_ranking_finalizations
  for select to authenticated, anon
  using (true);
-- INSERT/UPDATE/DELETE 정책 없음 = SECURITY DEFINER 배치만 쓴다.

-- 뱃지 등급 정렬 헬퍼(위 array_agg 에서 사용). 45/50 이 인라인 case 로 쓰던 순서와 동일.
create or replace function public._badge_grade_rank(p_grade text)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select case p_grade
    when 'diamond'  then 5
    when 'platinum' then 4
    when 'gold'     then 3
    when 'silver'   then 2
    when 'bronze'   then 1
    else 0
  end;
$$;

revoke execute on function public._badge_grade_rank(text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 57-3. NT-06 주간 랭킹 뱃지 알림 (dedupe `badge_level:weekly:{week_id}`)
-- -----------------------------------------------------------------------------
create or replace function public.notify_weekly_rank_badges(
  p_at timestamptz default now()
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_week  text;
  v_fin   timestamptz;
  v_n     integer := 0;
  r       record;
begin
  -- §6-N.5 방해 금지: 배치 계열은 KST 08~22 에만 발송한다. 확정 배치(00:10 KST)가
  -- 이 함수를 부르면 여기서 조용히 0 을 반환하고, 08:00 KST job 이 실제로 보낸다.
  if not public._batch_hours_ok(p_at) then
    return 0;
  end if;

  -- 가장 최근 확정된 주. 7일이 지난 확정 건은 재발행하지 않는다(배치가 오래 멈춰
  -- 있다가 돌아왔을 때 철 지난 알림이 나가는 것을 막는다).
  select f.period_start, f.week_id, min(f.finalized_at)
    into v_start, v_week, v_fin
    from public.weekly_ranking_finalizations f
   where f.finalized_at > p_at - interval '7 days'
   group by f.period_start, f.week_id
   order by f.period_start desc
   limit 1;

  if v_start is null then
    return 0;
  end if;

  for r in
    select ub.user_id,
           count(*)::integer as cnt,
           (array_agg(b.name        order by public._badge_grade_rank(b.badge_grade) desc, b.id))[1] as rep_name,
           (array_agg(b.description order by public._badge_grade_rank(b.badge_grade) desc, b.id))[1] as rep_desc
      from public.user_badges ub
      join public.badges b on b.id = ub.badge_id
     where b.category   = 'season_weekly_rank'
       and ub.revoked   = false
       and ub.earned_at >= v_fin - interval '1 minute'
     group by ub.user_id
  loop
    if public.enqueue_notification(
         r.user_id,
         'badge_level',
         case when r.cnt = 1 then r.rep_name || ' 획득!'
              else '주간 랭킹 뱃지 ' || r.cnt || '개 획득' end,
         case when r.cnt = 1 then coalesce(r.rep_desc, r.rep_name)
              else r.rep_name || ' 외 ' || (r.cnt - 1) || '개' end,
         -- §6-N.7: 뱃지 갤러리는 활동 화면의 하위 탭. 쿼리까지 정확히 보내야 한다.
         '/history?tab=badges',
         jsonb_build_object('badge_count', r.cnt, 'week_id', v_week, 'level', null),
         'badge_level:weekly:' || v_week
       ) is not null
    then
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end;
$$;

comment on function public.notify_weekly_rank_badges(timestamptz) is
  'NT-06 주간 랭킹 유래 뱃지 알림(TRD §14 #12-(b)). dedupe 키 '
  '`badge_level:weekly:{week_id}` — 한 주에 사용자당 1건. `_batch_hours_ok` 로 '
  '자가 게이트하므로 00:10 KST 확정 배치가 불러도 발송되지 않는다.';

revoke execute on function public.notify_weekly_rank_badges(timestamptz)
  from public, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 57-4. 주간 랭킹 확정 배치
-- -----------------------------------------------------------------------------
create or replace function public.finalize_weekly_ranking(
  p_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cur_start   timestamptz;
  v_prev_anchor timestamptz;
  v_start       timestamptz;
  v_end         timestamptz;
  v_week        text;
  v_tier        public.tier;
  v_marked      integer := 0;
  v_awarded     integer := 0;
  v_notified    integer := 0;
  v_uid         uuid;
begin
  -- "방금 끝난 주" = p_at 이 속한 주의 직전 주. p_at 을 그대로 1주 빼면 배치가
  -- 주 중간에 수동 실행될 때 엉뚱한 주를 잡으므로, 현재 주 시작 직전 시각을 앵커로
  -- 삼는다(월요일 00:10 정시 실행이든 수요일 수동 실행이든 같은 주를 가리킨다).
  select b.period_start into v_cur_start
    from public.leaderboard_period_bounds('weekly', p_at) b;

  v_prev_anchor := v_cur_start - interval '1 hour';

  select b.period_start, b.period_end into v_start, v_end
    from public.leaderboard_period_bounds('weekly', v_prev_anchor) b;

  v_week := public.week_id_at(v_prev_anchor);

  -- (a) 최종 재집계 — 티어별 파티션 + 통합 보드.
  --     정렬·타이브레이크(PRD §8.2 3단계 + user_id 폴백)는 `refresh_leaderboard` 의
  --     기존 로직을 그대로 재사용한다. 확정 시점에 규칙이 갈라지면 주중에 보던 순위와
  --     확정 순위가 달라진다.
  perform public.refresh_leaderboard('weekly', 'distance', 'global', null, v_prev_anchor, null);
  foreach v_tier in array enum_range(null::public.tier) loop
    perform public.refresh_leaderboard('weekly', 'distance', 'global', null, v_prev_anchor, v_tier);
  end loop;

  -- (b) 확정 도장. 최초 확정 시각은 덮어쓰지 않는다.
  update public.leaderboard_entries le
     set finalized_at = coalesce(le.finalized_at, now())
   where le.period       = 'weekly'
     and le.metric       = 'distance'
     and le.scope        = 'global'
     and le.period_start = v_start;
  get diagnostics v_marked = row_count;

  -- 원장: 참가자 0명 티어도 행을 남긴다("확정했고 아무도 없었다" ≠ "확정 안 함").
  insert into public.weekly_ranking_finalizations as f
    (period_start, tier_key, tier, week_id, participant_count, finalized_at, recomputed_at)
  select
    v_start,
    coalesce(t.tier::text, '_all'),
    t.tier,
    v_week,
    coalesce((
      select max(coalesce(le.participant_count, 0))
        from public.leaderboard_entries le
       where le.period       = 'weekly'
         and le.metric       = 'distance'
         and le.scope        = 'global'
         and le.period_start = v_start
         and le.tier is not distinct from t.tier
    ), 0),
    now(),
    now()
  from (
    select unnest(enum_range(null::public.tier)) as tier
    union all
    select null::public.tier
  ) t
  on conflict (period_start, tier_key) do update
     set participant_count = excluded.participant_count,
         recomputed_at     = now();

  -- (c) RK-06 주간 상위권 뱃지 — 확정 직후 지급.
  --     후보를 §41 의 최소 모집단 게이트로 미리 좁힌 뒤 `evaluate_badges` 를 부른다.
  --     실제 판정 정본은 여전히 `evaluate_badge_condition` 이며(이 마이그레이션이
  --     거기에 `finalized_at is not null` 필터를 더한다), 여기서는 "누구를 재평가할
  --     가치가 있는가"만 고른다. 전원 재평가해도 결과는 같지만 비용이 다르다.
  for v_uid in
    select distinct le.user_id
      from public.leaderboard_entries le
     where le.period       = 'weekly'
       and le.metric       = 'distance'
       and le.scope        = 'global'
       and le.period_start = v_start
       and le.tier is not null
       and le.finalized_at is not null
       and (
            (coalesce(le.participant_count, 0) >= 10 and le.rank = 1)
         or (coalesce(le.participant_count, 0) >= 20 and le.rank <= 10)
         or (coalesce(le.participant_count, 0) >= 20
             and le.rank <= ceil(le.participant_count * 0.10))
       )
  loop
    v_awarded := v_awarded + public.evaluate_badges(v_uid, null);
  end loop;

  -- (d) NT-06. 00:10 KST 실행에서는 `_batch_hours_ok` 에 걸려 0 을 반환하고,
  --     같은 날 08:00 KST job 이 실제로 발행한다.
  v_notified := public.notify_weekly_rank_badges(p_at);

  return jsonb_build_object(
    'week_id',        v_week,
    'period_start',   v_start,
    'period_end',     v_end,
    'entries_marked', v_marked,
    'badges_awarded', v_awarded,
    'notifications',  v_notified
  );
end;
$$;

comment on function public.finalize_weekly_ranking(timestamptz) is
  '주간 랭킹 확정 배치(TRD §14 #12). 매주 월요일 KST 00:10(`10 15 * * 0` UTC). '
  '방금 끝난 주를 (a) 티어별 최종 재집계 (b) finalized_at 도장 + 원장 적재 '
  '(c) RK-06 주간 상위권 뱃지 지급 (d) NT-06 알림(시간대 게이트) 순으로 처리한다. '
  '전 단계가 멱등이라 재실행해도 중복 지급이 없다. 5분 주기 refresh_all_leaderboards '
  '(주중 신선도)는 그대로 두고 그 위에 얹는다.';

revoke execute on function public.finalize_weekly_ranking(timestamptz)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 57-5. TRD §14 #23 결함 #2 — `season_weekly_rank_lte` 에 "확정된 주" 필터
-- -----------------------------------------------------------------------------
-- `evaluate_badge_condition` 은 800줄 디스패치 함수라 전문을 다시 싣지 않는다.
-- 라이브 정의를 읽어 해당 분기 한 곳에만 술어를 끼워 넣고, 앵커가 없으면 실패시킨다
-- (마이그레이션 42 가 이 함수의 직전 정본이며 앵커 텍스트는 41 에서 왔다).
do $patch$
declare
  v_src    text;
  v_anchor text := E'          and le.period_start <  v_season_end\n          and (\n            (v_bucket = ''top1''';
  v_repl   text := E'          and le.period_start <  v_season_end\n'
                || E'          -- (57번, TRD §14 #23 결함 #2) 확정된 지난 주만 판정 대상.\n'
                || E'          -- 진행 중인 주의 일시적 1위로 영구 뱃지가 나가던 경로를 닫는다.\n'
                || E'          and le.finalized_at is not null\n'
                || E'          and (\n            (v_bucket = ''top1''';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'evaluate_badge_condition';

  if v_src is null then
    raise exception '57-5: evaluate_badge_condition 이 없다';
  end if;

  if position(v_anchor in v_src) = 0 then
    raise exception
      '57-5: season_weekly_rank_lte 앵커를 찾지 못했다 — 함수 본문이 바뀌었다면 이 패치를 수정할 것';
  end if;

  if position(E'and le.finalized_at is not null' in v_src) > 0 then
    raise notice '57-5: 이미 적용됨 — 건너뜀';
    return;
  end if;

  execute replace(v_src, v_anchor, v_repl);
end;
$patch$;

revoke execute on function public.evaluate_badge_condition(uuid, text, jsonb)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 57-6. 소급 백필 — 지금까지 존재한 모든 주를 "확정"으로 도장
-- -----------------------------------------------------------------------------
-- 57-5 의 필터는 `finalized_at is null` 인 과거 주를 전부 판정 대상에서 빼 버린다.
-- 이미 종료된 주까지 미확정으로 남기면 정상적으로 받았어야 할 뱃지가 영원히 막힌다.
-- **진행 중인 주는 제외**한다.
--
-- 이 백필로 인한 **추가 지급은 없다**(멱등 테스트로 확인). 다만 "아무도 이 뱃지를
-- 받은 적 없다"는 것은 **사실이 아니다**(QA C-3): 라이브에 `season_weekly_rank`
-- 뱃지 3건이 이미 있다 — user `…00a8`, 2026-08-25 부여, 플래티넘 위클리킹/탑텐/
-- 라이징. 셋 다 `participant_count = 1` 보드에서 나간 **마이그레이션 41(최소 모집단
-- 게이트) 이전의 레거시 지급**이다. 57 이 만든 문제가 아니고 57 이후로는 같은 지급이
-- 불가능하다(게이트 + 확정 주 필터). 이 3건의 회수 여부는 gamification-designer
-- 판단 사항이라 여기서 데이터를 건드리지 않는다.
do $backfill$
declare
  v_cur_start timestamptz;
  v_row       record;
begin
  select b.period_start into v_cur_start
    from public.leaderboard_period_bounds('weekly', now()) b;

  update public.leaderboard_entries le
     set finalized_at = coalesce(le.finalized_at, le.period_end)
   where le.period       = 'weekly'
     and le.metric       = 'distance'
     and le.scope        = 'global'
     and le.period_start < v_cur_start;

  for v_row in
    select le.period_start, le.period_end, le.tier,
           max(coalesce(le.participant_count, 0)) as pc
      from public.leaderboard_entries le
     where le.period       = 'weekly'
       and le.metric       = 'distance'
       and le.scope        = 'global'
       and le.period_start < v_cur_start
     group by le.period_start, le.period_end, le.tier
  loop
    insert into public.weekly_ranking_finalizations
      (period_start, tier_key, tier, week_id, participant_count, finalized_at, recomputed_at)
    values (v_row.period_start, coalesce(v_row.tier::text, '_all'), v_row.tier,
            public.week_id_at(v_row.period_start), v_row.pc,
            v_row.period_end, now())
    on conflict (period_start, tier_key) do nothing;
  end loop;
end;
$backfill$;

-- -----------------------------------------------------------------------------
-- 57-7. pg_cron
-- -----------------------------------------------------------------------------
-- 확정: 매주 월요일 KST 00:10 = 일요일 15:10 UTC (정본 TRD §2.2 / §14 #12)
select cron.unschedule('runnit-weekly-finalize')
 where exists (select 1 from cron.job where jobname = 'runnit-weekly-finalize');
select cron.schedule('runnit-weekly-finalize', '10 15 * * 0',
  $cron$ select public.finalize_weekly_ranking(); $cron$);

-- NT-06 발행: 매주 월요일 KST 08:00 = 일요일 23:00 UTC.
-- 확정 배치도 같은 함수를 부르지만 그 시각엔 방해 금지 게이트에 걸린다(§6-N.5).
select cron.unschedule('runnit-weekly-rank-badge-notify')
 where exists (select 1 from cron.job where jobname = 'runnit-weekly-rank-badge-notify');
select cron.schedule('runnit-weekly-rank-badge-notify', '0 23 * * 0',
  $cron$ select public.notify_weekly_rank_badges(); $cron$);
