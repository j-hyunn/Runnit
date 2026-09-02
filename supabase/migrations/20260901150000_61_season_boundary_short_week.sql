-- =============================================================================
-- Runnit :: 61. 시즌 말 단축 주간 (PRD §8.5 미구현 스펙 구현 / TRD §14 #30·C-2 해소)
-- -----------------------------------------------------------------------------
-- PRD §8.5 정본: "시즌 종료일이 주 중간이면 해당 주간 랭킹은 **단축 운영**."
-- 이 문장은 스펙에 있었으나 구현된 적이 없다 — `leaderboard_period_bounds('weekly')`
-- 는 언제나 완전한 월~일 주를 돌려줬다. 그 미구현이 만든 실제 결함이 QA C-2 다.
--
-- C-2 (닫으려는 것)
--   시즌 경계는 분기 1일, 주 경계는 월요일이라 **거의 매 시즌 마지막 주가 두 시즌에
--   걸친다.** 걸친 주의 확정은 다음 월요일에 도는데, 그 시점의
--   `evaluate_badge_condition` 은 `season_id_at(now())`(= 새 시즌)로 판정하므로
--   `le.period_start >= v_season_start` 를 통과하지 못한다 → 그 주의 1위·탑텐·상위10%
--   가 **구시즌 뱃지도 신시즌 뱃지도 못 받는다.**
--
-- 실제 첫 사례 (스모크 대상): 2026-Q3 종료
--   2026-09-30 은 **수요일**이고 Q3 는 2026-10-01 00:00 KST 에 끝난다.
--   그 주는 2026-09-28(월) ~ 2026-10-05(월) 이므로 다음과 같이 갈린다.
--     Q3 조각: 09-28 00:00 ~ 10-01 00:00 KST (월~수, 3일)
--     Q4 조각: 10-01 00:00 ~ 10-05 00:00 KST (목~일, 4일)
--
-- =============================================================================
-- 설계 1 — 단축 주를 "새 개념"으로 만들지 않는다: 주를 시즌으로 **자른다**
-- =============================================================================
-- `leaderboard_period_bounds('weekly', anchor)` 가 달력 주를 **앵커가 속한 시즌으로
-- 클램프**한다:  [max(주시작, 시즌시작), min(주끝, 시즌끝))
--
-- 이 한 줄짜리 규칙이 아래를 전부 자동으로 만든다.
--   · 주는 분기 경계를 최대 1번만 넘으므로 조각은 항상 2개 이하다.
--   · 조각마다 `period_start` 가 다르므로 `leaderboard_entries` 의 유니크 키
--     `(scope, crew_key, tier_key, period, metric, period_start, user_id)` 가 그대로
--     두 조각을 **별개 기간**으로 다룬다 — 스키마 변경이 필요 없다.
--   · `season_id_at(period_start)` 가 조각의 시즌을 유일하게 결정한다(클램프 덕에
--     조각은 절대 시즌을 걸치지 않는다).
--   · `recompute_season_tier` 의 `best_weekly_rank` 서브쿼리
--     (`period_start >= season_start(prev) and < season_end(prev)`)가 손대지 않아도
--     Q3 조각만 세고 Q4 조각은 뺀다.
--   · 러닝 귀속은 `started_at` 기준 그대로다(§8.5 경계 걸침) — `refresh_leaderboard`
--     가 `started_at >= v_start and < v_end` 로 거르므로 자동으로 맞는다.
--   · §8.6(주중 승급 시 주간 거리 그대로 이관)도 그대로다 — 이관은 `tier` 파티션
--     문제이고 기간 경계와 무관하다.
--
-- ⚠️ `weekly` 만 클램프한다. `daily`·`monthly` 는 분기에 완전히 포개지므로 클램프가
--    무의미하고, `all_time`(1970~9999)은 클램프하면 **망가진다**.
--
-- =============================================================================
-- 설계 2 — 두 조각의 주 키가 같으면 dedupe 가 삼킨다
-- =============================================================================
-- 두 조각은 같은 ISO 주(예: 둘 다 `2026-W40`)라 `week_id_at()` 이 같은 값을 준다.
-- 그러면 NT-04 `rank_change:{week}:…` / NT-06 `badge_level:weekly:{week}` dedupe 키가
-- 충돌해 **둘째 조각의 알림이 조용히 사라진다.**
--
-- 그래서 `week_id_at()` 자체를 시즌 인식형으로 바꾼다 — 달력 주가 시즌을 걸칠 때만
-- `@{season_id}` 를 덧붙인다(`2026-W40@2026-Q3` / `2026-W40@2026-Q4`).
--   · 걸치지 않는 주는 **출력이 한 글자도 안 바뀐다** → 기존 dedupe 키·이력과 호환.
--   · 소비자(NT-04/05/06·확정 원장)가 전부 이 함수를 쓰므로 한 곳만 고치면 된다.
--   · 걸친 주는 2026-09-28 이 처음이라 과거 데이터와 충돌할 여지도 없다.
--
-- =============================================================================
-- 설계 3 — C-2 의 진짜 원인은 "판정 시점의 시즌"을 쓴 것
-- =============================================================================
-- 클램프만으로는 부족하다. `evaluate_badge_condition` 은 `v_season := season_id_at(now())`
-- 로 **판정을 실행하는 순간의 시즌**을 본다. 10/5 에 Q3 조각을 확정하면 v_season 은
-- Q4 라 Q3 조각이 걸러진다.
--
-- 정답은 "확정 대상 주의 시즌"이 아니라 그보다 정확한 **"판정 중인 뱃지 인스턴스의
-- 시즌"** 이다. 시즌 뱃지는 `srank_gold_top1@2026-Q3` 처럼 인스턴스마다
-- `badges.season_id` 를 들고 있는데, 디스패치가 `(user_id, condition_type, condition)`
-- 만 넘겨서 그 정보가 판정 함수에 도달하지 못하고 있었다.
--
-- 🔴 이것은 C-2 보다 넓은 잠재 결함이었다: 미획득으로 남은 **과거 시즌 인스턴스가
--    현재 시즌 데이터로 재판정**된다. `evaluate_badges` 는 미획득 뱃지를 매 러닝마다
--    다시 도므로, Q4 의 성적으로 **Q3 뱃지가 발급될 수 있었다.** `season_*` 조건
--    전체(주간 랭킹·티어 달성·시즌 첫 러닝 등)가 대상이다.
--
-- 전달 방법은 시그니처 확장이 아니라 **세션 GUC** 를 쓴다:
--   · 4번째 인자를 default 로 추가하면 3인자 호출이 모호해져 기존 호출부가 깨지고,
--     DROP 후 재생성하려면 24KB 함수 본문을 통째로 다시 실어야 한다.
--   · GUC 는 이 프로젝트의 기존 관용이다(`runnit.server_write`, `runnit.badge_eval`,
--     `runnit.notify_level`, `_notify_ctx`). 판정 함수는 한 줄만 바뀐다.
--
-- =============================================================================
-- 설계 4 — 확정 배치는 "직전 1개"가 아니라 "안 끝낸 것 전부"를 확정한다
-- =============================================================================
-- 클램프를 넣으면 월요일 배치의 "직전 기간"이 **신시즌 조각**이 된다.
--   10/5(월) 00:10 실행 → 현재 기간 [10/5, 10/12) → 직전 = [10/1, 10/5) = Q4 조각.
-- 즉 **Q3 조각은 어떤 월요일 실행의 "직전 기간"도 되지 못해 영영 확정되지 않는다.**
-- 따라서 "다음 월요일 일괄 확정" 최소 구현은 이 설계에서 성립하지 않는다.
--
-- 대신 `finalize_weekly_ranking` 이 **끝났는데 아직 확정 안 된 모든 주간 기간**을
-- 확정한다(KST 자정 앵커로 하루씩 되짚는다 — 조각의 최소 길이가 1일이라 누락 없다).
--   · 이미 확정된 기간은 **건너뛴다**(재집계하지 않는다). 재집계하면 그 시점의 티어로
--     과거 순위가 다시 쓰여 확정의 의미가 사라진다 — QA L-1 이 과거 주로 번지는 것도
--     이걸로 막힌다.
--   · 되짚는 폭은 **14일**. 자기치유(크론 1~2회 누락)와 단축 조각(최대 6일 전)을
--     모두 덮으면서, 그보다 길게 잡으면 **한 번도 집계된 적 없는 오래된 주의 보드를
--     오늘의 티어로 합성**해 버린다 — 없는 것보다 나쁜 기록이라 의도적으로 자른다.
--
-- 확정 시점 (PRD 미명시 → 결정과 근거)
--   PRD §8.5 는 단축 운영을 요구하지만 **확정 순간은 규정하지 않는다.** 구시즌 조각을
--   다음 월요일까지 미루면 사용자는 시즌이 끝난 뒤 나흘간 "지난 시즌 마지막 주 결과"를
--   못 본다. 그래서 `reset_stale_seasons()`(분기 첫날 00:05 KST)가 **시즌 리셋 루프보다
--   먼저** 확정 배치를 부른다. 그러면 구시즌 조각이 시즌 마감과 같은 순간에 확정되고,
--   RK-06 뱃지도 그때 나간다. 월요일 배치의 되짚기는 그 안전망이다.
--   ⚠️ 순서가 중요하다 — 리셋 루프가 `profiles.current_tier` 를 신시즌 bronze 로
--   내리기 **전에** 확정해야 티어 파티션이 구시즌 값으로 잡힌다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 61-1. 주 키 — 시즌을 걸치는 주에만 `@{season}` 접미사
-- -----------------------------------------------------------------------------
create or replace function public.week_id_at(p_at timestamptz default now())
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select to_char(w.local_at, 'IYYY-"W"IW')
      || case
           when public.season_id_at(w.wk_first) = public.season_id_at(w.wk_last) then ''
           else '@' || public.season_id_at(p_at)
         end
  from (
    select
      (p_at at time zone 'Asia/Seoul') as local_at,
      (date_trunc('week', p_at at time zone 'Asia/Seoul'))
        at time zone 'Asia/Seoul'      as wk_first,
      (date_trunc('week', p_at at time zone 'Asia/Seoul')
         + interval '7 days' - interval '1 microsecond')
        at time zone 'Asia/Seoul'      as wk_last
  ) w;
$$;

comment on function public.week_id_at(timestamptz) is
  'KST ISO 주 키 `YYYY-Www`. 달력 주가 **시즌(분기) 경계를 걸치면** `@{season_id}` 를 '
  '덧붙여 두 단축 조각을 구분한다(`2026-W40@2026-Q3` / `2026-W40@2026-Q4`, 마이그레이션 61). '
  '걸치지 않는 주는 출력이 종전과 동일하므로 기존 dedupe 키·이력과 호환된다. '
  '이 구분이 없으면 NT-04/NT-06 의 dedupe 키가 충돌해 둘째 조각의 알림이 사라진다.';

-- -----------------------------------------------------------------------------
-- 61-2. 주간 기간을 시즌으로 클램프 (PRD §8.5 단축 운영)
-- -----------------------------------------------------------------------------
create or replace function public.leaderboard_period_bounds(
  p_period public.ranking_period,
  p_anchor timestamptz default now()
)
returns table(period_start timestamptz, period_end timestamptz)
language sql
immutable
set search_path = public, pg_temp
as $$
  select
    case p_period
      when 'weekly' then greatest(b.raw_start, b.season_s)
      else               b.raw_start
    end,
    case p_period
      when 'weekly' then least(b.raw_end, b.season_e)
      else               b.raw_end
    end
  from (
    select
      case p_period
        when 'daily'    then (date_trunc('day',   p_anchor at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul'
        when 'weekly'   then (date_trunc('week',  p_anchor at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul'
        when 'monthly'  then (date_trunc('month', p_anchor at time zone 'Asia/Seoul')) at time zone 'Asia/Seoul'
        when 'all_time' then timestamptz '1970-01-01T00:00:00Z'
      end as raw_start,
      case p_period
        when 'daily'    then (date_trunc('day',   p_anchor at time zone 'Asia/Seoul') + interval '1 day')   at time zone 'Asia/Seoul'
        when 'weekly'   then (date_trunc('week',  p_anchor at time zone 'Asia/Seoul') + interval '1 week')  at time zone 'Asia/Seoul'
        when 'monthly'  then (date_trunc('month', p_anchor at time zone 'Asia/Seoul') + interval '1 month') at time zone 'Asia/Seoul'
        when 'all_time' then timestamptz '9999-12-31T23:59:59Z'
      end as raw_end,
      public.season_start(public.season_id_at(p_anchor)) as season_s,
      public.season_end  (public.season_id_at(p_anchor)) as season_e
  ) b;
$$;

comment on function public.leaderboard_period_bounds(public.ranking_period, timestamptz) is
  '랭킹 기간 경계(KST). **`weekly` 만 앵커가 속한 시즌으로 클램프**한다 — PRD §8.5 '
  '"시즌 종료일이 주 중간이면 해당 주간 랭킹은 단축 운영"의 구현(마이그레이션 61). '
  '주는 분기 경계를 최대 1번 넘으므로 조각은 2개 이하이고, 조각마다 `period_start` 가 '
  '달라 `leaderboard_entries` 가 스키마 변경 없이 별개 기간으로 다룬다. '
  '`daily`/`monthly` 는 분기에 포개져 클램프가 무의미하고, `all_time` 은 클램프하면 망가진다.';

-- -----------------------------------------------------------------------------
-- 61-3. 뱃지 판정의 시즌을 "지금"이 아니라 "뱃지 인스턴스의 시즌"으로
-- -----------------------------------------------------------------------------
-- 24KB 디스패치 함수의 선언부 한 줄만 바꾼다(57-5 와 같은 앵커 치환 방식).
do $patch$
declare
  v_src    text;
  v_anchor text := E'  v_season       text := public.season_id_at(now());';
  v_repl   text := E'  -- (61번) 판정 시즌은 "지금"이 아니라 **판정 중인 뱃지 인스턴스의 시즌**이다.\n'
                || E'  -- `evaluate_badges` 가 badges.season_id 를 이 GUC 로 넘긴다(_notify_ctx 와 같은 관용).\n'
                || E'  -- 이것 없이는 (a) 시즌 말 걸친 주의 RK-06 이 영영 지급되지 않고(QA C-2),\n'
                || E'  -- (b) 미획득으로 남은 과거 시즌 인스턴스가 현재 시즌 데이터로 재판정된다.\n'
                || E'  v_season       text := coalesce(\n'
                || E'                           nullif(current_setting(''runnit.badge_season'', true), ''''),\n'
                || E'                           public.season_id_at(now()));';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'evaluate_badge_condition';

  if v_src is null then
    raise exception '61-3: evaluate_badge_condition 이 없다';
  end if;

  if position('runnit.badge_season' in v_src) > 0 then
    raise notice '61-3: 이미 적용됨 — 건너뜀';
    return;
  end if;

  if position(v_anchor in v_src) = 0 then
    raise exception '61-3: v_season 선언 앵커를 찾지 못했다 — 함수 본문이 바뀌었다면 이 패치를 수정할 것';
  end if;

  execute replace(v_src, v_anchor, v_repl);
end;
$patch$;

revoke execute on function public.evaluate_badge_condition(uuid, text, jsonb)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 61-4. `evaluate_badges` 가 뱃지마다 시즌 컨텍스트를 실어 준다
-- -----------------------------------------------------------------------------
create or replace function public.evaluate_badges(
  p_user_id       uuid,
  p_source_run_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_badge     record;
  v_awarded   integer := 0;
  v_pass_cnt  integer;
  v_pass      integer;
begin
  if p_user_id is null then
    return 0;
  end if;

  perform set_config('runnit.server_write', 'on', true);
  perform set_config('runnit.badge_eval',   'on', true);

  for v_pass in 1..3 loop
    v_pass_cnt := 0;

    for v_badge in
      select b.id, b.condition_type, b.condition, b.season_id
      from public.badges b
      where (b.scope = 'permanent' or (b.scope = 'seasonal' and b.season_id is not null))
        and not exists (
          select 1 from public.user_badges ub
          where ub.user_id = p_user_id and ub.badge_id = b.id
        )
    loop
      -- (61번) 이 뱃지가 어느 시즌의 인스턴스인지를 판정 함수에 넘긴다.
      -- permanent 뱃지는 '' 이고 판정 함수가 season_id_at(now()) 로 폴백한다(미사용).
      perform set_config('runnit.badge_season', coalesce(v_badge.season_id, ''), true);

      if public.evaluate_badge_condition(p_user_id, v_badge.condition_type, v_badge.condition) then
        insert into public.user_badges (user_id, badge_id, earned_at, source_run_id, is_seen, verified, revoked)
        values (p_user_id, v_badge.id, now(), p_source_run_id, false, true, false)
        on conflict (user_id, badge_id) do nothing;

        if found then
          v_pass_cnt := v_pass_cnt + 1;
        end if;
      end if;
    end loop;

    v_awarded := v_awarded + v_pass_cnt;
    exit when v_pass_cnt = 0;

    perform public.recompute_profile_stats(p_user_id);
  end loop;

  perform set_config('runnit.badge_season', '',    true);
  perform set_config('runnit.badge_eval',   'off', true);
  perform set_config('runnit.server_write', 'off', true);

  return v_awarded;
end;
$$;

comment on function public.evaluate_badges(uuid, uuid) is
  '미획득 뱃지 전량 재평가(마이그레이션 27/61). **뱃지마다 `runnit.badge_season` GUC 에 '
  '`badges.season_id` 를 실어** 판정 함수가 "지금"이 아니라 **그 인스턴스의 시즌**을 '
  '보게 한다(61번) — 이것 없이는 시즌 말 걸친 주의 RK-06 이 영영 지급되지 않고(QA C-2), '
  '미획득으로 남은 과거 시즌 인스턴스가 현재 시즌 데이터로 재판정된다.';

revoke execute on function public.evaluate_badges(uuid, uuid)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 61-5. 확정 배치 — 끝났는데 아직 확정 안 된 주간 기간을 전부 확정
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
  v_lookback_days constant integer := 14;
  v_day        timestamp;
  v_anchor     timestamptz;
  v_start      timestamptz;
  v_end        timestamptz;
  v_week       text;
  v_tier       public.tier;
  v_marked     integer;
  v_total      integer := 0;
  v_awarded    integer := 0;
  v_notified   integer := 0;
  v_uid        uuid;
  v_seen       timestamptz[] := '{}';
  v_weeks      jsonb := '[]'::jsonb;
begin
  for v_day in
    select generate_series(
             date_trunc('day', (p_at at time zone 'Asia/Seoul')) - (v_lookback_days || ' days')::interval,
             date_trunc('day', (p_at at time zone 'Asia/Seoul')),
             interval '1 day')
  loop
    v_anchor := v_day at time zone 'Asia/Seoul';

    select b.period_start, b.period_end into v_start, v_end
      from public.leaderboard_period_bounds('weekly', v_anchor) b;

    continue when v_end > p_at;                 -- 아직 안 끝난 기간
    continue when v_start = any(v_seen);        -- 같은 실행에서 이미 처리
    v_seen := v_seen || v_start;

    -- 이미 확정된 기간은 재집계하지 않는다 — 재집계하면 그 시점의 티어로 과거 순위가
    -- 다시 쓰여 "확정"의 의미가 사라진다.
    continue when exists (
      select 1 from public.weekly_ranking_finalizations f
       where f.period_start = v_start
    );

    v_week := public.week_id_at(v_start);

    -- (a) 최종 재집계 — 티어별 파티션 + 통합 보드
    perform public.refresh_leaderboard('weekly', 'distance', 'global', null, v_anchor, null);
    foreach v_tier in array enum_range(null::public.tier) loop
      perform public.refresh_leaderboard('weekly', 'distance', 'global', null, v_anchor, v_tier);
    end loop;

    -- (b) 확정 도장
    update public.leaderboard_entries le
       set finalized_at = coalesce(le.finalized_at, now())
     where le.period       = 'weekly'
       and le.metric       = 'distance'
       and le.scope        = 'global'
       and le.period_start = v_start;
    get diagnostics v_marked = row_count;
    v_total := v_total + v_marked;

    -- 원장: 참가자 0명 티어도 행을 남긴다
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

    -- (c) RK-06 — 최소 모집단 게이트를 넘는 후보만 재평가
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

    v_weeks := v_weeks || jsonb_build_object(
      'week_id',        v_week,
      'period_start',   v_start,
      'period_end',     v_end,
      'season_id',      public.season_id_at(v_start),
      'shortened',      (v_end - v_start) < interval '7 days',
      'entries_marked', v_marked);
  end loop;

  -- (d) NT-06 — `_batch_hours_ok` 로 자가 게이트(00:10 KST 실행에서는 무음)
  v_notified := public.notify_weekly_rank_badges(p_at);

  return jsonb_build_object(
    'weeks_finalized', jsonb_array_length(v_weeks),
    'finalized',       v_weeks,
    'entries_marked',  v_total,
    'badges_awarded',  v_awarded,
    'notifications',   v_notified
  );
end;
$$;

comment on function public.finalize_weekly_ranking(timestamptz) is
  '주간 랭킹 확정 배치(TRD §14 #12, 마이그레이션 57/61). 매주 월요일 KST 00:10 '
  '(`10 15 * * 0` UTC) + 시즌 롤오버(`reset_stale_seasons`)에서 호출된다. '
  '**끝났는데 아직 확정되지 않은 모든 주간 기간**(14일 되짚기)을 티어별 최종 재집계 → '
  '`finalized_at` 도장 + 원장 적재 → RK-06 지급 → NT-06 순으로 처리한다. '
  '이미 확정된 기간은 건너뛴다 — 재집계하면 그 시점의 티어로 과거 순위가 다시 쓰인다. '
  '되짚기가 "직전 1개"가 아닌 이유: 61번의 시즌 클램프 이후 월요일의 직전 기간은 '
  '**신시즌 조각**이라 구시즌 단축 조각이 영영 확정되지 않는다.';

revoke execute on function public.finalize_weekly_ranking(timestamptz)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 61-6. NT-06 — 최근 확정된 주 각각에 대해, 그 주의 **시즌** 뱃지로 귀속
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
  v_n integer := 0;
  w   record;
  r   record;
begin
  -- §6-N.5 방해 금지: 배치 계열은 KST 08~22 에만 발송한다.
  if not public._batch_hours_ok(p_at) then
    return 0;
  end if;

  -- 최근 7일 안에 확정된 주 전부. 시즌 경계에서는 구시즌 조각과 신시즌 조각이 서로
  -- 다른 날 확정될 수 있으므로 "가장 최근 1개"만 보면 한쪽이 통째로 누락된다.
  for w in
    select f.period_start,
           f.week_id,
           min(f.finalized_at)                 as finalized_at,
           public.season_id_at(f.period_start) as season_id
      from public.weekly_ranking_finalizations f
     where f.finalized_at > p_at - interval '7 days'
     group by f.period_start, f.week_id
     order by f.period_start
  loop
    for r in
      select ub.user_id,
             count(*)::integer as cnt,
             (array_agg(b.name        order by public._badge_grade_rank(b.badge_grade) desc, b.id))[1] as rep_name,
             (array_agg(b.description order by public._badge_grade_rank(b.badge_grade) desc, b.id))[1] as rep_desc
        from public.user_badges ub
        join public.badges b on b.id = ub.badge_id
       where b.category   = 'season_weekly_rank'
         and b.season_id  = w.season_id     -- 그 주가 속한 시즌의 인스턴스만
         and ub.revoked   = false
         and ub.earned_at >= w.finalized_at - interval '1 minute'
       group by ub.user_id
    loop
      if public.enqueue_notification(
           r.user_id,
           'badge_level',
           case when r.cnt = 1 then r.rep_name || ' 획득!'
                else '주간 랭킹 뱃지 ' || r.cnt || '개 획득' end,
           case when r.cnt = 1 then coalesce(r.rep_desc, r.rep_name)
                else r.rep_name || ' 외 ' || (r.cnt - 1) || '개' end,
           '/history?tab=badges',
           jsonb_build_object('badge_count', r.cnt, 'week_id', w.week_id, 'level', null),
           'badge_level:weekly:' || w.week_id
         ) is not null
      then
        v_n := v_n + 1;
      end if;
    end loop;
  end loop;

  return v_n;
end;
$$;

comment on function public.notify_weekly_rank_badges(timestamptz) is
  'NT-06 주간 랭킹 유래 뱃지 알림(TRD §14 #12-(b), 마이그레이션 57/61). dedupe 키 '
  '`badge_level:weekly:{week_id}` — 단축 조각은 `week_id_at()` 이 `@{season}` 을 붙여 '
  '구분한다. **최근 7일 안에 확정된 주 전부**를 돌며 각 주의 시즌 인스턴스 뱃지만 귀속한다 '
  '(시즌 경계에서 두 조각이 다른 날 확정되므로 "가장 최근 1개"만 보면 한쪽이 누락된다). '
  '`_batch_hours_ok` 로 자가 게이트하므로 00:10 KST 확정 배치가 불러도 발송되지 않는다.';

revoke execute on function public.notify_weekly_rank_badges(timestamptz)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 61-7. 시즌 롤오버가 구시즌 단축 조각을 먼저 확정한다
-- -----------------------------------------------------------------------------
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
  perform public.ensure_season_badge_instances(v_season);

  -- (61번) 구시즌의 마지막 단축 조각을 **리셋 루프보다 먼저** 확정한다.
  -- 순서가 중요하다: 아래 루프가 profiles.current_tier 를 신시즌 bronze 로 내리기
  -- 전에 확정해야 티어 파티션이 구시즌 값으로 잡힌다. 또한 이 시점에 RK-06 을
  -- 지급해야 사용자가 시즌 종료와 같은 순간에 결과를 본다(PRD §8.5 는 확정 순간을
  -- 규정하지 않는다 — 근거는 이 마이그레이션 헤더 "확정 시점").
  perform public.finalize_weekly_ranking(p_at);

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

comment on function public.reset_stale_seasons(timestamptz) is
  '시즌 롤오버 배치(마이그레이션 22/61). pg_cron `runnit-season-reset-30/31` 이 분기 '
  '첫날 00:05 KST 에 부른다. ① 신시즌 뱃지 인스턴스 생성 ② **구시즌 단축 조각 확정** '
  '(61번 — 리셋 루프보다 먼저여야 티어 파티션이 구시즌 값으로 잡힌다) ③ 스테일 시즌 '
  '사용자별 `recompute_season_tier`(= season_histories 마감 + 시즌 랭킹 스냅샷).';

revoke execute on function public.reset_stale_seasons(timestamptz)
  from public, anon, authenticated;
