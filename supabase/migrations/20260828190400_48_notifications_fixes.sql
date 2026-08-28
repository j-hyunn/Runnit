-- =============================================================================
-- Runnit :: 48. 알림 구현 결함 2건 수정 (45·46 후속)
-- -----------------------------------------------------------------------------
-- 두 건 모두 라이브 데이터로 스모크 테스트를 돌려 잡았다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 48-1. trg_level_up_notify — profiles 의 PK 는 `id` 다 (`user_id` 아님)
-- -----------------------------------------------------------------------------
-- 45번은 `new.user_id` 를 참조했다. plpgsql 은 트리거 함수 본문의 필드 참조를
-- **실행 시점에** 해석하므로 CREATE 는 통과하고, 러닝 없이 레벨이 오르는 경로
-- (러닝 삭제·뱃지 revoked·tier_change_history INSERT)가 처음 실행될 때에야
-- `record "new" has no field "user_id"` 로 터진다. 그리고 그 예외는 **러닝 저장·삭제
-- 트랜잭션 전체를 롤백시킨다** — 알림 하나 때문에 기록 조작이 실패하는, 이 파일이
-- 가장 피하려던 실패 양상이다.
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

  -- 러닝 유래면 runs_04 가 뱃지와 묶어 1건으로 보낸다(§5.2).
  if public._notify_ctx('runnit.notify_run_id') is not null then
    perform set_config('runnit.notify_level', new.level::text, true);
    return null;
  end if;

  v_next_xp := (public.xp_level_thresholds())[new.level + 1];

  perform public.enqueue_notification(
    new.id,                                   -- ← 48번 수정: profiles PK 는 id
    'badge_level',
    'Lv.' || new.level || ' 달성',
    case
      when v_next_xp is null then '누적 ' || new.total_xp || 'XP · 만렙에 도달했어요.'
      else '누적 ' || new.total_xp || 'XP · 다음 레벨까지 '
           || greatest(v_next_xp - new.total_xp, 0) || 'XP'
    end,
    '/profile/badges',
    jsonb_build_object('level', new.level, 'badge_count', 0),
    'badge_level:level:' || new.level
  );
  return null;
end;
$$;

revoke execute on function public.trg_level_up_notify() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 48-2. NT-05 변형 B — 모집단이 작으면 "상위 %"를 쓰지 않는다
-- -----------------------------------------------------------------------------
-- 46번은 미러닝자에게 `top_pct(1, participant_count + 1)` 을 보여줬다. 이번 주 그
-- 티어에서 아무도 안 뛰었으면 participant_count = 0 이므로 **"5km면 상위 100%예요"**
-- 가 나간다. 문자열은 문법적으로 맞지만 의미는 정반대로 읽힌다 — 격려하려던 문구가
-- 꼴찌 통보가 된다.
--
-- 상위 % 는 모집단이 있어야 의미가 있다. 5명 미만이면 백분율을 버리고 중립 문구를
-- 쓴다. 이 규칙은 PRD §5.4.1("티어 인원 불균형은 해소하지 않고 표기로 완화")의
-- 연장선이다 — 표본이 없으면 표기하지 않는 것이 완화다.
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
             r.user_id, 'weekend_push', v_title, v_body, '/ranking',
             jsonb_build_object('rank', r.rank, 'participant_count', v_pc,
               'gap_m', round(v_gap), 'tier', r.tier::text, 'week_id', v_week, 'variant', 'A'),
             'weekend_push:' || v_week || ':' || v_slot) is not null
        then v_sent := v_sent + 1; end if;
      end if;
    elsif v_slot = 'sun' then
      -- 1위 방어 심리는 마감 임박에서만 작동한다. 토요일 오전의 "1.2km 차"는 여유로 읽힌다.
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
             r.user_id, 'weekend_push', v_title, v_body, '/ranking',
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

      -- (48번) 모집단 5명 미만이면 백분율을 쓰지 않는다. participant_count = 0 일 때
      -- top_pct 는 100 을 돌려주고, "5km면 상위 100%예요"는 격려가 아니라 꼴찌 통보다.
      if v_pc >= 5 then
        select public.top_pct(
                 (select count(*)::integer + 1 from public.leaderboard_entries le
                   where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
                     and le.tier = r.tier and le.period_start = v_start and le.score > 5000),
                 v_pc + 1) into v_proj;
      else
        v_proj := null;
      end if;

      -- 미러닝자에게 현재 순위(사실상 꼴찌)를 보여주면 안 된다. 도달 가능한 위치를 보여준다.
      v_title := '이번 주 기록이 아직 없어요';
      v_body := public.tier_ko(r.tier) || ' 랭킹 마감까지 오늘 하루.'
                || case when v_proj is null then ' 5km면 이번 주 기록이 남아요.'
                        else ' 5km면 상위 ' || v_proj || '%예요.' end;

      if public.enqueue_notification(
           r.user_id, 'weekend_push', v_title, v_body, '/ranking',
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
