-- =============================================================================
-- Runnit :: 50. 알림 딥링크 route 정정 (QA C-3)
-- -----------------------------------------------------------------------------
-- 정본: `_workspace/20260828_205500_qa_notifications.md` C-3,
--       flutter-ui-designer 확정(2026-08-28) — `docs/ARCHITECTURE.md` §5.6.1,
--       `lib/core/notifications/notification_deep_link.dart`
--
-- 45~48이 발행하던 route 3종이 **이 앱에 존재한 적이 없다.** 2026-08-21 4탭 개편에서
-- 랭킹 독립 탭은 홈으로, 뱃지 독립 탭은 활동 화면의 하위 탭으로 흡수됐는데, 알림
-- 구현이 개편 이전의 화면 구성을 가정하고 route를 지어냈다.
--
-- | 발행처 | 잘못된 값 | 확정값 |
-- |---|---|---|
-- | NT-03 변형 C, NT-04, NT-05 | `/ranking` | `/home` |
-- | NT-06 러닝 유래 | `/runs/{run_id}` | `/history/run/{run_id}` |
-- | NT-06 레벨 단독 | `/profile/badges` | `/history?tab=badges` |
--
-- 가장 나쁜 것은 `/profile/badges`였다. 클라이언트 화이트리스트가 접두 매칭이라
-- `/profile/`에 걸려 **통과**한 뒤 go_router에서 `no routes for location`으로 터졌다 —
-- 화이트리스트가 막으려던 바로 그 실패를 화이트리스트가 통과시켰다. 도달 경로는
-- 러닝 없는 레벨업(뱃지 verified/revoked 변경, `tier_change_history` INSERT)이라 실재한다.
--
-- ⚠️ 클라이언트가 옛 route 3종을 변환해 착지시키는 표를 갖고 있지만(과거 행 호환),
--    그것은 **이미 쌓인 데이터용이지 서버가 기대도 되는 안전망이 아니다.** 서버가
--    발행하는 값은 라우터에 실제로 등록된 경로여야 한다.
--
-- ⚠️ **route를 새로 쓰거나 바꿀 때는 `notification_deep_link.dart`의 목적지 표와
--    `docs/ARCHITECTURE.md` §5.6.1을 함께 고칠 것.** 이 결함이 문서 검토에서
--    잡히지 않은 원인이 "종류 → route → 실제 라우터 경로" 3열 표가 어디에도 없었다는
--    것이다(QA D-2).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 50-1. NT-06 레벨 단독 — `/profile/badges` -> `/history?tab=badges`
-- -----------------------------------------------------------------------------
create or replace function public.trg_level_up_notify()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_next_xp integer;
begin
  if new.level is null or old.level is null or new.level <= old.level then
    return null;
  end if;

  if public._notify_ctx('runnit.notify_run_id') is not null then
    perform set_config('runnit.notify_level', new.level::text, true);
    return null;
  end if;

  v_next_xp := (public.xp_level_thresholds())[new.level + 1];

  perform public.enqueue_notification(
    new.id,
    'badge_level',
    'Lv.' || new.level || ' 달성',
    case
      when v_next_xp is null then '누적 ' || new.total_xp || 'XP · 만렙에 도달했어요.'
      else '누적 ' || new.total_xp || 'XP · 다음 레벨까지 '
           || greatest(v_next_xp - new.total_xp, 0) || 'XP'
    end,
    -- 뱃지 갤러리는 독립 화면이 아니라 활동 화면의 하위 탭이다. 쿼리까지 정확히
    -- 보내야 뱃지 탭으로 열린다(`/history`만 보내면 기록 탭 — 크래시는 아니다).
    '/history?tab=badges',
    jsonb_build_object('level', new.level, 'badge_count', 0),
    'badge_level:level:' || new.level
  );
  return null;
end;
$$;

revoke execute on function public.trg_level_up_notify() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 50-2. NT-06 러닝 유래 — `/runs/{id}` -> `/history/run/{id}` (NT-02는 `/home` 유지)
-- -----------------------------------------------------------------------------
create or replace function public.trg_runs_notifications()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_season text; v_tier public.tier; v_next public.tier;
  v_dist double precision; v_total_xp integer;
  v_remaining double precision; v_threshold integer;
  v_level integer; v_badge_cnt integer := 0;
  v_rep_id uuid; v_rep_name text; v_rep_desc text;
  v_title text; v_body text; v_next_xp integer;
begin
  select p.tier_season_id, p.current_tier, p.season_distance_meters, p.total_xp, p.level
    into v_season, v_tier, v_dist, v_total_xp, v_level
    from public.profiles p where p.id = new.user_id;

  v_next := public.next_tier(v_tier);

  if v_season is not null
     and v_next is not null
     and coalesce(new.is_flagged, false) = false
     and new.status = 'completed'
     and new.activity_type <> 'indoor_run'
     and public.season_end(v_season) - now() > interval '24 hours'
  then
    v_threshold := public.tier_proximity_threshold_m(v_next);
    v_remaining := public.tier_threshold_m(v_next) - coalesce(v_dist, 0);
    if v_remaining > 0 and v_remaining <= v_threshold then
      perform public.enqueue_notification(
        new.user_id, 'tier_proximity',
        public.tier_ko(v_next) || '까지 ' || public.fmt_km(v_remaining) || 'km',
        '이번 시즌 ' || public.fmt_km(v_dist) || 'km를 달렸어요. 한 번만 더 나가면 '
          || public.tier_ko(v_next) || '예요.',
        '/home',
        jsonb_build_object('tier', v_next::text, 'remaining_m', round(v_remaining),
                           'season_id', v_season),
        'tier_proximity:' || v_season || ':' || v_next::text);
    end if;
  end if;

  -- 티어 승급 뱃지(category='season_tier')는 세지 않는다 — NT-01 이 같은 사건을 이미 알렸다.
  select count(*)::integer into v_badge_cnt
    from public.user_badges ub join public.badges b on b.id = ub.badge_id
   where ub.source_run_id = new.id and ub.user_id = new.user_id
     and ub.revoked = false and b.category <> 'season_tier';

  if v_badge_cnt > 0 then
    select ub.id, b.name, b.description into v_rep_id, v_rep_name, v_rep_desc
      from public.user_badges ub join public.badges b on b.id = ub.badge_id
     where ub.source_run_id = new.id and ub.user_id = new.user_id
       and ub.revoked = false and b.category <> 'season_tier'
     order by case b.badge_grade when 'diamond' then 5 when 'platinum' then 4
                                 when 'gold' then 3 when 'silver' then 2
                                 when 'bronze' then 1 else 0 end desc, b.id asc
     limit 1;
  end if;

  v_level := public._notify_ctx('runnit.notify_level')::integer;

  if v_badge_cnt > 0 or v_level is not null then
    v_next_xp := case when v_level is null then null
                      else (public.xp_level_thresholds())[v_level + 1] end;
    v_title := case
      when v_level is not null and v_badge_cnt > 0
        then 'Lv.' || v_level || ' 달성 · 뱃지 ' || v_badge_cnt || '개 획득'
      when v_level is not null then 'Lv.' || v_level || ' 달성'
      when v_badge_cnt = 1 then v_rep_name || ' 획득!'
      else '뱃지 ' || v_badge_cnt || '개를 획득했어요' end;
    v_body := case
      when v_badge_cnt = 1 then coalesce(v_rep_desc, v_rep_name)
      when v_badge_cnt >= 2 then v_rep_name || ' 외 ' || (v_badge_cnt - 1) || '개'
      when v_next_xp is null then '누적 ' || v_total_xp || 'XP · 만렙에 도달했어요.'
      else '누적 ' || v_total_xp || 'XP · 다음 레벨까지 '
           || greatest(v_next_xp - v_total_xp, 0) || 'XP' end;

    perform public.enqueue_notification(
      new.user_id, 'badge_level', v_title, v_body,
      -- 러닝 상세는 활동 화면의 하위 라우트다. run_id 는 UUID 라 세그먼트 하나다.
      '/history/run/' || new.id::text,
      jsonb_build_object('user_badge_id', v_rep_id, 'badge_count', v_badge_cnt,
                         'level', v_level, 'run_id', new.id),
      'badge_level:run:' || new.id::text);
  end if;

  perform set_config('runnit.notify_level',  '', true);
  perform set_config('runnit.notify_run_id', '', true);
  return null;
end;
$$;

revoke execute on function public.trg_runs_notifications() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 50-3. NT-03 변형 C — `/ranking` -> `/home` (A는 `/home`, B는 `/profile` 유지)
-- -----------------------------------------------------------------------------
create or replace function public.notify_season_ending(p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_season text := public.season_id_at(p_at);
  v_start timestamptz := public.season_start(v_season);
  v_end timestamptz := public.season_end(v_season);
  v_days integer; v_reach integer; v_sent integer := 0; r record;
  v_next public.tier; v_rem double precision; v_var text;
  v_title text; v_body text; v_route text;
begin
  if not public._batch_hours_ok(p_at) then return 0; end if;
  v_days := ((v_end - interval '1 second') at time zone 'Asia/Seoul')::date
            - (p_at at time zone 'Asia/Seoul')::date;
  if v_days not in (14, 3) then return 0; end if;
  v_reach := case v_days when 14 then 40000 else 10000 end;

  for r in
    select p.id, p.current_tier, coalesce(p.season_distance_meters, 0) as dist,
           exists (select 1 from public.runs a
                    where a.user_id = p.id and a.status = 'completed' and a.is_flagged = false
                      and a.started_at >= p_at - interval '14 days') as is_active
      from public.profiles p
     where exists (select 1 from public.runs s
                    where s.user_id = p.id and s.status = 'completed' and s.is_flagged = false
                      and s.started_at >= v_start and s.started_at < v_end)
  loop
    v_next := public.next_tier(r.current_tier);
    v_rem := case when v_next is null then null else public.tier_threshold_m(v_next) - r.dist end;
    v_var := case when v_next is null then 'C'
                  when v_rem > 0 and v_rem <= v_reach then 'A' else 'B' end;
    if v_days = 3 and v_var = 'B' and not r.is_active then continue; end if;

    if v_var = 'A' then
      v_title := '시즌 종료 D-' || v_days || ' · ' || public.tier_ko(v_next)
                 || '까지 ' || public.fmt_km(v_rem) || 'km';
      v_body := v_days || '일 안에 ' || public.fmt_km(v_rem) || 'km면 이번 시즌을 '
                || public.tier_ko(v_next) || '로 마감해요.';
      v_route := '/home';
    elsif v_var = 'B' then
      v_title := '시즌 종료 D-' || v_days;
      v_body := public.season_label(v_season) || ' 시즌을 ' || public.fmt_km(r.dist)
                || 'km · ' || public.tier_ko(r.current_tier) || '로 달려왔어요. 남은 '
                || v_days || '일 기록이 이번 시즌 뱃지에 남습니다.';
      v_route := '/profile';
    else
      v_title := '시즌 종료 D-' || v_days || ' · ' || public.season_label(v_season) || ' 플래티넘 확정';
      v_body := public.fmt_km(r.dist) || 'km. 남은 ' || v_days || '일은 주간 랭킹에서 마무리해요.';
      -- 주간 랭킹은 독립 라우트가 아니라 홈 화면 안(티어 카드 아래)에 있다.
      v_route := '/home';
    end if;

    if public.enqueue_notification(
         r.id, 'season_ending', v_title, v_body, v_route,
         jsonb_build_object('season_id', v_season, 'days_left', v_days,
           'tier', coalesce(v_next, r.current_tier)::text,
           'remaining_m', case when v_rem is null then null else round(v_rem) end,
           'season_distance_m', round(r.dist), 'variant', v_var),
         'season_ending:' || v_season || ':d' || v_days) is not null
    then v_sent := v_sent + 1; end if;
  end loop;
  return v_sent;
end;
$$;

revoke execute on function public.notify_season_ending(timestamptz) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 50-4. NT-04 순위 변동 — `/ranking` -> `/home`
-- -----------------------------------------------------------------------------
-- 본문은 46-2와 동일하고 route 인자 하나만 바뀐다. `create or replace` 는 부분
-- 교체가 안 되므로 전문을 다시 쓴다.
create or replace function public.notify_rank_changes(p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz; v_week text; v_sent integer := 0; r record;
  v_pc integer; v_band integer; v_dir text; v_n integer; v_total integer; v_cap integer;
  v_gap double precision; v_gapb double precision; v_name text;
  v_title text; v_body text;
begin
  if not public._batch_hours_ok(p_at) then return 0; end if;
  select b.period_start into v_start from public.leaderboard_period_bounds('weekly', p_at) b;
  if p_at - v_start < interval '24 hours' then return 0; end if;
  v_week := public.week_id_at(v_start);

  for r in
    select le.user_id, le.rank, le.notified_rank, le.notified_at, le.score,
           le.participant_count, le.tier, le.period_start
      from public.leaderboard_entries le
     where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
       and le.tier is not null and le.period_start = v_start
     order by le.tier, le.rank
  loop
    v_pc := coalesce(r.participant_count, 0);
    if v_pc < 10 then continue; end if;

    if r.notified_rank is null then
      update public.leaderboard_entries le set notified_rank = r.rank, notified_at = p_at
       where le.user_id = r.user_id and le.period = 'weekly' and le.metric = 'distance'
         and le.scope = 'global' and le.tier = r.tier and le.period_start = v_start;
      continue;
    end if;
    if r.notified_at is not null and r.notified_at > p_at - interval '6 hours' then continue; end if;

    v_band := greatest(30, ceil(v_pc * 0.3)::integer);
    if r.rank > v_band and r.notified_rank > v_band then continue; end if;

    v_dir := null;
    if r.rank - r.notified_rank >= 3 then
      v_dir := 'down';
    elsif r.notified_rank - r.rank >= 5
       or (r.rank <= 10 and r.notified_rank > 10)
       or (r.rank <= 3 and r.notified_rank > 3)
       or (r.rank = 1 and r.notified_rank > 1) then
      v_dir := 'up';
    end if;

    if v_dir is not null then
      select count(*)::integer into v_total from public.notifications n
       where n.user_id = r.user_id and n.type = 'rank_change'
         and n.dedupe_key like 'rank_change:' || v_week || ':%';
      select count(*)::integer into v_n from public.notifications n
       where n.user_id = r.user_id and n.type = 'rank_change'
         and n.dedupe_key like 'rank_change:' || v_week || ':' || v_dir || ':%';

      -- CASE 식을 IF 조건에 인라인으로 쓰지 말 것(첫 THEN 토큰까지로 끊어 읽는다).
      v_cap := case v_dir when 'down' then 3 else 2 end;

      if v_total < 4 and v_n < v_cap then
        select le.score - r.score into v_gap from public.leaderboard_entries le
         where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
           and le.tier = r.tier and le.period_start = v_start and le.rank = r.rank - 1;
        select r.score - le.score into v_gapb from public.leaderboard_entries le
         where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
           and le.tier = r.tier and le.period_start = v_start and le.rank = r.rank + 1;

        if v_dir = 'down' then
          select le.display_name into v_name from public.leaderboard_entries le
           where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
             and le.tier = r.tier and le.period_start = v_start
             and le.rank < r.rank and le.notified_rank is not null
             and le.notified_rank > r.notified_rank
           order by le.rank desc limit 1;
          if v_name is null or length(trim(v_name)) = 0 then
            v_title := '순위가 ' || r.notified_rank || '위 → ' || r.rank || '위로 내려갔어요';
          else
            v_title := v_name || '님에게 추월당했어요';
          end if;
          v_body := public.tier_ko(r.tier) || ' ' || r.rank || '위'
                    || case when v_gap is null then ''
                            else ' · 앞사람까지 ' || public.fmt_km(v_gap) || 'km' end;
        else
          v_title := case when r.rank = 1 then public.tier_ko(r.tier) || ' 1위예요'
                          else r.rank || '위로 올라섰어요' end;
          v_body := public.tier_ko(r.tier) || ' ' || r.rank || '위(상위 '
                    || public.top_pct(r.rank, v_pc) || '%)'
                    || case when v_gapb is null then ''
                            else ' · 뒷사람과 ' || public.fmt_km(v_gapb) || 'km 차' end;
        end if;

        if public.enqueue_notification(
             r.user_id, 'rank_change', v_title, v_body,
             '/home',   -- 주간 랭킹은 홈 화면 안에 있다(독립 라우트 없음)
             jsonb_build_object('direction', v_dir, 'rank', r.rank,
               'previous_rank', r.notified_rank,
               'gap_m', round(coalesce(case when v_dir = 'down' then v_gap else v_gapb end, 0)),
               'participant_count', v_pc, 'tier', r.tier::text, 'week_id', v_week),
             'rank_change:' || v_week || ':' || v_dir || ':' || (v_n + 1)) is not null
        then v_sent := v_sent + 1; end if;
      end if;
    end if;

    -- 기준선 갱신은 발송 여부와 분리한다. 건너뛴 경우에도 갱신해야 조용해진다.
    update public.leaderboard_entries le set notified_rank = r.rank, notified_at = p_at
     where le.user_id = r.user_id and le.period = 'weekly' and le.metric = 'distance'
       and le.scope = 'global' and le.tier = r.tier and le.period_start = v_start;
  end loop;
  return v_sent;
end;
$$;

revoke execute on function public.notify_rank_changes(timestamptz) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 50-5. NT-05 주말 유도 — `/ranking` -> `/home` (48-2의 모집단 게이트 유지)
-- -----------------------------------------------------------------------------
create or replace function public.notify_weekend_push(p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz; v_week text; v_slot text; v_dow integer; v_sent integer := 0;
  r record; v_gap double precision; v_gapb double precision; v_name text;
  v_title text; v_body text; v_pc integer; v_proj integer;
begin
  if not public._batch_hours_ok(p_at) then return 0; end if;
  v_dow := extract(isodow from (p_at at time zone 'Asia/Seoul'))::integer;
  v_slot := case v_dow when 6 then 'sat' when 7 then 'sun' else null end;
  if v_slot is null then return 0; end if;

  select b.period_start into v_start from public.leaderboard_period_bounds('weekly', p_at) b;
  v_week := public.week_id_at(v_start);

  -- A(추격) · C(방어)
  for r in
    select le.user_id, le.rank, le.score, le.participant_count, le.tier
      from public.leaderboard_entries le
     where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
       and le.tier is not null and le.period_start = v_start
       and exists (select 1 from public.runs a
                    where a.user_id = le.user_id and a.status = 'completed'
                      and a.is_flagged = false and a.started_at >= p_at - interval '28 days')
  loop
    v_pc := coalesce(r.participant_count, 0);
    if r.rank > 1 then
      select le.score - r.score into v_gap from public.leaderboard_entries le
       where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
         and le.tier = r.tier and le.period_start = v_start and le.rank = r.rank - 1;
      -- 격차 5km 초과는 주말 하루로 뒤집을 수 없다. 추격 신호가 아니라 포기 신호다.
      if v_gap is not null and v_gap <= 5000 then
        v_title := '앞사람까지 ' || public.fmt_km(v_gap) || 'km';
        v_body := public.tier_ko(r.tier) || ' ' || r.rank || '위(상위 '
                  || public.top_pct(r.rank, v_pc) || '%) · 오늘 '
                  || public.fmt_km(v_gap) || 'km면 한 칸 올라가요.';
        if public.enqueue_notification(
             r.user_id, 'weekend_push', v_title, v_body, '/home',
             jsonb_build_object('rank', r.rank, 'participant_count', v_pc,
               'gap_m', round(v_gap), 'tier', r.tier::text, 'week_id', v_week, 'variant', 'A'),
             'weekend_push:' || v_week || ':' || v_slot) is not null
        then v_sent := v_sent + 1; end if;
      end if;
    elsif v_slot = 'sun' then
      select r.score - le.score, le.display_name into v_gapb, v_name
        from public.leaderboard_entries le
       where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
         and le.tier = r.tier and le.period_start = v_start and le.rank = 2;
      if v_gapb is not null and v_gapb <= 5000 then
        v_title := public.tier_ko(r.tier) || ' 1위, 마감까지 ' || public.fmt_km(v_gapb) || 'km 차';
        v_body := case when v_name is null or length(trim(v_name)) = 0
                       then '2위가 ' || public.fmt_km(v_gapb) || 'km 뒤에 있어요.'
                       else '2위 ' || v_name || '님이 ' || public.fmt_km(v_gapb) || 'km 뒤에 있어요.' end;
        if public.enqueue_notification(
             r.user_id, 'weekend_push', v_title, v_body, '/home',
             jsonb_build_object('rank', 1, 'participant_count', v_pc,
               'gap_m', round(v_gapb), 'tier', r.tier::text, 'week_id', v_week, 'variant', 'C'),
             'weekend_push:' || v_week || ':' || v_slot) is not null
        then v_sent := v_sent + 1; end if;
      end if;
    end if;
  end loop;

  -- B(미러닝) — 일요일만
  if v_slot = 'sun' then
    for r in
      select p.id as user_id, p.current_tier as tier
        from public.profiles p
       where not exists (select 1 from public.leaderboard_entries le
                          where le.period = 'weekly' and le.metric = 'distance'
                            and le.scope = 'global' and le.tier is not null
                            and le.period_start = v_start and le.user_id = p.id)
         and exists (select 1 from public.runs a
                      where a.user_id = p.id and a.status = 'completed'
                        and a.is_flagged = false and a.started_at >= p_at - interval '28 days')
    loop
      select count(*)::integer into v_pc from public.leaderboard_entries le
       where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
         and le.tier = r.tier and le.period_start = v_start;

      -- 모집단 5명 미만이면 백분율을 쓰지 않는다(48-2). participant_count = 0 이면
      -- top_pct 가 100 을 돌려주고 "5km면 상위 100%"는 격려가 아니라 꼴찌 통보다.
      if v_pc >= 5 then
        select public.top_pct(
                 (select count(*)::integer + 1 from public.leaderboard_entries le
                   where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
                     and le.tier = r.tier and le.period_start = v_start and le.score > 5000),
                 v_pc + 1) into v_proj;
      else
        v_proj := null;
      end if;

      v_title := '이번 주 기록이 아직 없어요';
      v_body := public.tier_ko(r.tier) || ' 랭킹 마감까지 오늘 하루.'
                || case when v_proj is null then ' 5km면 이번 주 기록이 남아요.'
                        else ' 5km면 상위 ' || v_proj || '%예요.' end;

      if public.enqueue_notification(
           r.user_id, 'weekend_push', v_title, v_body, '/home',
           jsonb_build_object('rank', null, 'participant_count', v_pc, 'remaining_m', 5000,
             'tier', r.tier::text, 'week_id', v_week, 'variant', 'B'),
           'weekend_push:' || v_week || ':' || v_slot) is not null
      then v_sent := v_sent + 1; end if;
    end loop;
  end if;
  return v_sent;
end;
$$;

revoke execute on function public.notify_weekend_push(timestamptz) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 50-6. 이미 쌓인 알림 행의 route 백필
-- -----------------------------------------------------------------------------
-- 클라이언트가 옛 경로 3종을 변환해 착지시키지만, 그 변환표는 과거 데이터용 임시
-- 장치다. 서버가 남긴 잘못된 값을 서버가 치운다 — 표를 영구 장치로 만들지 않기 위해서다.
do $$
declare
  v_prev text;
begin
  v_prev := public._server_write_enter();

  update public.notifications n
     set payload = jsonb_set(n.payload, '{route}', '"/home"'::jsonb)
   where n.payload ->> 'route' = '/ranking';

  update public.notifications n
     set payload = jsonb_set(n.payload, '{route}', '"/history?tab=badges"'::jsonb)
   where n.payload ->> 'route' = '/profile/badges';

  update public.notifications n
     set payload = jsonb_set(n.payload, '{route}',
                             to_jsonb('/history/run/' || substring(n.payload ->> 'route' from 7)))
   where n.payload ->> 'route' like '/runs/%';

  perform public._server_write_exit(v_prev);
end;
$$;
