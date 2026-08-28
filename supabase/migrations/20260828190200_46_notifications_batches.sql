-- =============================================================================
-- Runnit :: 46. 알림 배치 계열 — NT-03 시즌 D-day / NT-04 순위 변동 / NT-05 주말 유도
-- -----------------------------------------------------------------------------
-- 정본: _workspace/20260828_181500_gamification_notification-rules.md §2 · §3 · §4 · §7.4
--
-- 이 셋은 사용자의 행동과 무관한 시각에 발화하므로 **KST 08:00~22:00** 으로 제한한다
-- (트리거 계열은 방금 러닝을 끝낸 순간이라 심야 예외 — 45번 헤더 참조).
--
-- 이 파일을 지배하는 원칙 두 개
--   ① 도달 불가능한 목표는 동기를 죽인다. "250km까지 92km 남았어요"는 격려가 아니라
--      포기 통보다. 모든 임계치는 "한 번의 러닝, 늦어도 한 주 안에 뒤집을 수 있는
--      범위"이고, 범위를 벗어나면 **아예 보내지 않는다.**
--   ② 알림 한 건의 예산은 유한하다. 사용자가 알림을 끄는 순간 이 앱의 이중 경쟁
--      루프(PRD §4.2)는 존재하지 않게 된다. 상한은 count 쿼리가 아니라
--      **dedupe_key unique 제약**으로 강제한다 — 애플리케이션 레벨 체크는 pg_cron
--      재실행 경합에서 새어 나간다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 46-0. 배치 계열 공통 시간대 게이트
-- -----------------------------------------------------------------------------
create or replace function public._batch_hours_ok(p_at timestamptz)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select extract(hour from (p_at at time zone 'Asia/Seoul'))::integer between 8 and 21;
$$;

revoke execute on function public._batch_hours_ok(timestamptz) from public, anon, authenticated;

-- =============================================================================
-- 46-1. NT-03 시즌 종료 D-14 / D-3
-- =============================================================================
-- D-14 와 D-3 은 목적이 다르다. D-14 는 광범위한 재참여, D-3 은 막판 승급 유도다.
-- 같은 필터를 쓰면 D-3 에 "92km 남았어요"가 나가 원칙 ①을 정면으로 위반한다.
--
-- 승급 가능권(NT03_REACHABLE_M) = 남은 일수 × 페르소나 주간 거리(15~30km)의 중앙값
--   D-14 (2주) -> 40,000m      D-3 (러닝 1~2회) -> 10,000m
--
-- 발송 매트릭스
--   D-14 : 시즌 러닝 ≥1건 전원. 승급권 -> A / 그 외 -> B / 플래티넘 -> C
--   D-3  : 승급권 -> A / 승급권 아님 & 활동중 -> B / 승급권 아님 & 휴면 -> **발송 안 함**
--          플래티넘 -> C
--   시즌 러닝 0건(미참여) : 두 D-day 모두 발송 안 함
--
-- 🔵 D-3 에서 휴면·비승급권을 제외한 유일한 이유: 이들에게 D-3 은 아무 행동도 유발하지
--    못하는 순수 소음이다. D-14 에서 이미 한 번 불렀고 반응하지 않았다. 두 번째 알림이
--    데려오지 못할 사용자에게 두 번째 알림을 보내는 비용은 "알림 끄기"다.
create or replace function public.notify_season_ending(p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_season text        := public.season_id_at(p_at);
  v_start  timestamptz := public.season_start(v_season);
  v_end    timestamptz := public.season_end(v_season);
  v_days   integer;
  v_reach  integer;
  v_sent   integer := 0;
  r        record;
  v_next   public.tier;
  v_rem    double precision;
  v_var    text;
  v_title  text;
  v_body   text;
  v_route  text;
begin
  if not public._batch_hours_ok(p_at) then
    return 0;
  end if;

  -- 시즌 종료는 배타적 경계라 마지막 날은 end - 1s 가 속한 날짜다.
  v_days := ((v_end - interval '1 second') at time zone 'Asia/Seoul')::date
            - (p_at at time zone 'Asia/Seoul')::date;

  if v_days not in (14, 3) then
    return 0;
  end if;

  v_reach := case v_days when 14 then 40000 else 10000 end;

  for r in
    select p.id,
           p.current_tier,
           coalesce(p.season_distance_meters, 0) as dist,
           exists (
             select 1 from public.runs a
              where a.user_id = p.id and a.status = 'completed' and a.is_flagged = false
                and a.started_at >= p_at - interval '14 days'
           ) as is_active
      from public.profiles p
     where exists (
             select 1 from public.runs s
              where s.user_id = p.id and s.status = 'completed' and s.is_flagged = false
                and s.started_at >= v_start and s.started_at < v_end
           )
  loop
    v_next := public.next_tier(r.current_tier);
    v_rem  := case when v_next is null then null
                   else public.tier_threshold_m(v_next) - r.dist end;

    v_var := case
      when v_next is null                          then 'C'   -- 플래티넘 도달자
      when v_rem > 0 and v_rem <= v_reach          then 'A'   -- 승급 가능권
      else                                              'B'
    end;

    -- D-3 휴면·비승급권 제외
    if v_days = 3 and v_var = 'B' and not r.is_active then
      continue;
    end if;

    if v_var = 'A' then
      v_title := '시즌 종료 D-' || v_days || ' · ' || public.tier_ko(v_next)
                 || '까지 ' || public.fmt_km(v_rem) || 'km';
      v_body  := v_days || '일 안에 ' || public.fmt_km(v_rem) || 'km면 이번 시즌을 '
                 || public.tier_ko(v_next) || '로 마감해요.';
      v_route := '/home';
    elsif v_var = 'B' then
      -- 승급 잔여 거리를 **넣지 않는다.** "92km 남았다"는 이 사용자에게 실패 통지다.
      -- 대신 이미 쌓은 것(누적 거리·현재 티어·영구히 남는 뱃지 GM-07)을 보여준다.
      v_title := '시즌 종료 D-' || v_days;
      v_body  := public.season_label(v_season) || ' 시즌을 ' || public.fmt_km(r.dist)
                 || 'km · ' || public.tier_ko(r.current_tier) || '로 달려왔어요. 남은 '
                 || v_days || '일 기록이 이번 시즌 뱃지에 남습니다.';
      v_route := '/profile';
    else
      -- PRD §5.3.2 가 인정한 한계("상위 러너는 시즌 후반 목표가 사라진다")를
      -- 주간 랭킹으로 넘겨주는 지점이다.
      v_title := '시즌 종료 D-' || v_days || ' · ' || public.season_label(v_season)
                 || ' 플래티넘 확정';
      v_body  := public.fmt_km(r.dist) || 'km. 남은 ' || v_days
                 || '일은 주간 랭킹에서 마무리해요.';
      v_route := '/ranking';
    end if;

    if public.enqueue_notification(
         r.id, 'season_ending', v_title, v_body, v_route,
         jsonb_build_object(
           'season_id', v_season,
           'days_left', v_days,
           'tier', coalesce(v_next, r.current_tier)::text,
           'remaining_m', case when v_rem is null then null else round(v_rem) end,
           'season_distance_m', round(r.dist),
           'variant', v_var
         ),
         -- 변형(A/B/C)은 키에 넣지 않는다 — 같은 D-day 에 변형만 다른 두 건이 가는
         -- 사고를 키가 막아야 한다. 시즌당 최대 2건.
         'season_ending:' || v_season || ':d' || v_days
       ) is not null
    then
      v_sent := v_sent + 1;
    end if;
  end loop;

  return v_sent;
end;
$$;

comment on function public.notify_season_ending(timestamptz) is
  'NT-03 시즌 종료 D-14/D-3. 매일 09:00 KST. D-day 별로 다른 대상 필터 + 문구 3변형. '
  '미참여자(시즌 러닝 0건)와 D-3 의 휴면·비승급권은 발송 대상이 아니다.';
revoke execute on function public.notify_season_ending(timestamptz) from public, anon, authenticated;

-- =============================================================================
-- 46-2. NT-04 주간 순위 변동
-- =============================================================================
-- ⚠️ `rank_delta` 를 기준으로 쓰면 안 된다 — 직전 5분 배치 대비 변동이라 진동하는
--    사용자에게 하루 수십 건이 나가고, 3계단 내려갔다 올라온 사용자에게 순 변동 0인데
--    알림 2건이 나간다. 기준선은 `notified_rank`(마지막으로 알려준 순위)다.
--
-- 평가는 **랭킹 갱신 배치 직후 체이닝**한다(별도 주기 금지 — rank 스냅샷이 어긋난다).
-- 주기는 매시 1회: 5분마다 평가하면 상한 4건을 하루 이른 시각에 다 소진한다.
--
-- 하위권을 제외한 근거는 PRD §5.4.1 이다. 브론즈 3,000명 중 2,847위 사용자에게
-- "2,847->2,851위"는 순수 소음이고, 그가 반응하는 신호는 순위가 아니라 "앞사람까지
-- 0.8km"다 — 그건 NT-05 가 담당한다. NT-04=방어(잃을 것이 있는 사람) /
-- NT-05=추격(한 칸 올릴 수 있는 사람) 의 역할 분담이 이것이다.
create or replace function public.notify_rank_changes(p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start   timestamptz;
  v_week    text;
  v_sent    integer := 0;
  r         record;
  v_pc      integer;
  v_band    integer;
  v_dir     text;
  v_n       integer;
  v_total   integer;
  v_cap     integer;
  v_gap     double precision;
  v_gapb    double precision;
  v_name    text;
  v_title   text;
  v_body    text;
begin
  if not public._batch_hours_ok(p_at) then          -- G2 방해 금지
    return 0;
  end if;

  select b.period_start into v_start
    from public.leaderboard_period_bounds('weekly', p_at) b;

  -- G3 주 시작 후 24시간 경과. 주 초에는 표본이 1~2건이라 순위가 무의미하게 요동친다.
  if p_at - v_start < interval '24 hours' then
    return 0;
  end if;

  v_week := public.week_id_at(v_start);

  for r in
    select le.user_id, le.rank, le.notified_rank, le.notified_at, le.score,
           le.participant_count, le.tier, le.period_start
      from public.leaderboard_entries le
     where le.period       = 'weekly'
       and le.metric       = 'distance'
       and le.scope        = 'global'
       and le.tier is not null                       -- G1 티어 내 개인 순위만(크루 P2 제외)
       and le.period_start = v_start
     order by le.tier, le.rank
  loop
    v_pc := coalesce(r.participant_count, 0);

    -- G4 참가자가 한 자리면 "3계단 하락"이 곧 꼴찌다. 소규모 티어는 NT-05 가 담당.
    if v_pc < 10 then
      continue;
    end if;

    -- G5 첫 진입은 비교 대상이 없다. 기준선만 채우고 알림은 보내지 않는다.
    if r.notified_rank is null then
      update public.leaderboard_entries le
         set notified_rank = r.rank, notified_at = p_at
       where le.user_id = r.user_id and le.period = 'weekly' and le.metric = 'distance'
         and le.scope = 'global' and le.tier = r.tier and le.period_start = v_start;
      continue;
    end if;

    -- G6 같은 사용자에게 6시간 안에 두 번 보내지 않는다.
    if r.notified_at is not null and r.notified_at > p_at - interval '6 hours' then
      continue;
    end if;

    -- 순위권 필터. notified_rank 도 보는 이유: **밴드 안에 있다가 밖으로 밀려난 순간**이
    -- 가장 강한 복귀 동기다. 그 한 건을 놓치면 안 된다.
    v_band := greatest(30, ceil(v_pc * 0.3)::integer);
    if r.rank > v_band and r.notified_rank > v_band then
      continue;
    end if;

    -- 방향별 임계는 비대칭이다. 상승은 대개 방금 러닝을 끝낸 사용자가 앱 안에서 이미
    -- 확인하므로 재방문 가치가 낮다 -> 문턱을 높인다.
    v_dir := null;
    if r.rank - r.notified_rank >= 3 then
      v_dir := 'down';
    elsif r.notified_rank - r.rank >= 5
       or (r.rank <= 10 and r.notified_rank > 10)
       or (r.rank <= 3  and r.notified_rank > 3)
       or (r.rank  = 1  and r.notified_rank > 1) then
      v_dir := 'up';
    end if;

    if v_dir is not null then
      -- 상한: down 3 / up 2 / 주 합계 4. 키에 순번 n 을 넣어 unique 제약으로 강제한다.
      select count(*)::integer into v_total
        from public.notifications n
       where n.user_id = r.user_id and n.type = 'rank_change'
         and n.dedupe_key like 'rank_change:' || v_week || ':%';

      select count(*)::integer into v_n
        from public.notifications n
       where n.user_id = r.user_id and n.type = 'rank_change'
         and n.dedupe_key like 'rank_change:' || v_week || ':' || v_dir || ':%';

      -- ⚠️ CASE 식을 IF 조건 안에 인라인으로 쓰지 말 것. plpgsql 은 IF 조건을 **첫 THEN
      --    토큰까지**로 끊어 읽으므로 `if ... case ... then ... end then` 은 컴파일 에러다.
      v_cap := case v_dir when 'down' then 3 else 2 end;

      if v_total < 4 and v_n < v_cap then
        -- 격차: 바로 앞사람과의 거리 차. **down 문구에도 반드시 넣는다** — 순위만
        -- 알리면 "졌다"로 끝나고, 격차를 붙여야 "0.8km면 되찾는다"가 된다.
        select le.score - r.score into v_gap
          from public.leaderboard_entries le
         where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
           and le.tier = r.tier and le.period_start = v_start and le.rank = r.rank - 1;

        select r.score - le.score into v_gapb
          from public.leaderboard_entries le
         where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
           and le.tier = r.tier and le.period_start = v_start and le.rank = r.rank + 1;

        if v_dir = 'down' then
          -- 나를 지나쳐 앞선 사람 중 가장 가까운 1명.
          select le.display_name into v_name
            from public.leaderboard_entries le
           where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
             and le.tier = r.tier and le.period_start = v_start
             and le.rank < r.rank
             and le.notified_rank is not null and le.notified_rank > r.notified_rank
           order by le.rank desc
           limit 1;

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
             r.user_id, 'rank_change', v_title, v_body, '/ranking',
             jsonb_build_object(
               'direction', v_dir,
               'rank', r.rank,
               'previous_rank', r.notified_rank,
               'gap_m', round(coalesce(case when v_dir = 'down' then v_gap else v_gapb end, 0)),
               'participant_count', v_pc,
               'tier', r.tier::text,
               'week_id', v_week
             ),
             'rank_change:' || v_week || ':' || v_dir || ':' || (v_n + 1)
           ) is not null
        then
          v_sent := v_sent + 1;
        end if;
      end if;
    end if;

    -- ⚠️ 기준선 갱신은 발송 여부와 **분리한다.** 상한에 걸려 건너뛴 뒤 기준선을
    --    갱신하지 않으면 같은 변동이 매 주기 조건을 만족해 계속 재시도하고, G6 간격
    --    게이트만 남는다. 건너뛴 경우에도 갱신해야 조용해진다.
    update public.leaderboard_entries le
       set notified_rank = r.rank, notified_at = p_at
     where le.user_id = r.user_id and le.period = 'weekly' and le.metric = 'distance'
       and le.scope = 'global' and le.tier = r.tier and le.period_start = v_start;
  end loop;

  return v_sent;
end;
$$;

comment on function public.notify_rank_changes(timestamptz) is
  'NT-04 주간 순위 변동. **refresh_all_leaderboards 직후 체이닝**해야 한다 — 별도 주기로 '
  '돌리면 rank 스냅샷이 어긋난다. 기준선은 rank_delta 가 아니라 notified_rank 이며, '
  '발송을 건너뛴 경우에도 기준선은 갱신한다.';
revoke execute on function public.notify_rank_changes(timestamptz) from public, anon, authenticated;

-- 랭킹 갱신 + 알림 평가를 한 트랜잭션으로 묶는 cron 진입점.
create or replace function public.refresh_leaderboards_and_notify(p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.refresh_all_leaderboards(p_at);
  return public.notify_rank_changes(p_at);
end;
$$;

revoke execute on function public.refresh_leaderboards_and_notify(timestamptz)
  from public, anon, authenticated;

-- =============================================================================
-- 46-3. NT-05 주말 막판 유도
-- =============================================================================
-- 토 10:00(주말 첫 러닝 기회 직전) + 일 18:00(주간 마감 23:59 까지 러닝 1회가 물리적으로
-- 가능한 마지막 현실 시점). 금요일은 넣지 않는다 — 주말 러닝 기회가 아직 2일 남아
-- 긴급성이 없고 3회 발송은 예산 초과다.
--
-- ⚠️ 문구 기준은 **격차 우선**이다. PRD §5.10 NT-05 행의 예시 `"10위까지 2.1km"` 는
--    구현하지 않는다 — §5.4.1(확정 트레이드오프)·RK-04 가 "격차 우선, 절대순위·상위%
--    병기"를 확정했고, 브론즈 3,000명 중 2,847위 사용자에게 "10위까지"는 2,837계단이라는
--    도달 불가능한 목표다(원칙 ①). 랭킹 화면과 알림의 표기가 다르면 사용자는 둘 중
--    어느 쪽이 진짜인지 판단할 근거를 잃는다.
--
-- 격차 상한 5,000m 의 근거: 페르소나 1회 러닝 거리가 5~10km(PRD §5.3.2)다. 5km 를 넘는
-- 격차는 주말 하루로 뒤집을 수 없고, "앞사람까지 8.4km"는 추격 신호가 아니라 포기 신호다.
create or replace function public.notify_weekend_push(p_at timestamptz default now())
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_week  text;
  v_slot  text;
  v_dow   integer;
  v_sent  integer := 0;
  r       record;
  v_gap   double precision;
  v_gapb  double precision;
  v_name  text;
  v_title text;
  v_body  text;
  v_pc    integer;
  v_proj  integer;
begin
  if not public._batch_hours_ok(p_at) then
    return 0;
  end if;

  v_dow := extract(isodow from (p_at at time zone 'Asia/Seoul'))::integer;  -- 6=토, 7=일
  v_slot := case v_dow when 6 then 'sat' when 7 then 'sun' else null end;
  if v_slot is null then
    return 0;
  end if;

  select b.period_start into v_start
    from public.leaderboard_period_bounds('weekly', p_at) b;
  v_week := public.week_id_at(v_start);

  -- ── A(추격) · C(방어) : 이번 주 거리가 있는 사용자 = 리더보드에 행이 있는 사용자 ──
  for r in
    select le.user_id, le.rank, le.score, le.participant_count, le.tier
      from public.leaderboard_entries le
      join public.profiles p on p.id = le.user_id
     where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
       and le.tier is not null and le.period_start = v_start
       and exists (
         select 1 from public.runs a
          where a.user_id = le.user_id and a.status = 'completed' and a.is_flagged = false
            and a.started_at >= p_at - interval '28 days'
       )
  loop
    v_pc := coalesce(r.participant_count, 0);

    if r.rank > 1 then
      select le.score - r.score into v_gap
        from public.leaderboard_entries le
       where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
         and le.tier = r.tier and le.period_start = v_start and le.rank = r.rank - 1;

      -- A · 추격 (토 + 일)
      if v_gap is not null and v_gap <= 5000 then
        v_title := '앞사람까지 ' || public.fmt_km(v_gap) || 'km';
        v_body  := public.tier_ko(r.tier) || ' ' || r.rank || '위(상위 '
                   || public.top_pct(r.rank, v_pc) || '%) · 오늘 '
                   || public.fmt_km(v_gap) || 'km면 한 칸 올라가요.';
        if public.enqueue_notification(
             r.user_id, 'weekend_push', v_title, v_body, '/ranking',
             jsonb_build_object('rank', r.rank, 'participant_count', v_pc,
                                'gap_m', round(v_gap), 'tier', r.tier::text,
                                'week_id', v_week, 'variant', 'A'),
             'weekend_push:' || v_week || ':' || v_slot
           ) is not null then
          v_sent := v_sent + 1;
        end if;
      end if;

    elsif v_slot = 'sun' then
      -- C · 방어 (일요일만). 1위 방어 심리는 마감 임박에서만 작동한다 —
      -- 토요일 오전의 "2위와 1.2km 차"는 여유로 읽힌다.
      select r.score - le.score, le.display_name into v_gapb, v_name
        from public.leaderboard_entries le
       where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
         and le.tier = r.tier and le.period_start = v_start and le.rank = 2;

      if v_gapb is not null and v_gapb <= 5000 then
        v_title := public.tier_ko(r.tier) || ' 1위, 마감까지 '
                   || public.fmt_km(v_gapb) || 'km 차';
        v_body  := case when v_name is null or length(trim(v_name)) = 0
                        then '2위가 ' || public.fmt_km(v_gapb) || 'km 뒤에 있어요.'
                        else '2위 ' || v_name || '님이 ' || public.fmt_km(v_gapb)
                             || 'km 뒤에 있어요.' end;
        if public.enqueue_notification(
             r.user_id, 'weekend_push', v_title, v_body, '/ranking',
             jsonb_build_object('rank', 1, 'participant_count', v_pc,
                                'gap_m', round(v_gapb), 'tier', r.tier::text,
                                'week_id', v_week, 'variant', 'C'),
             'weekend_push:' || v_week || ':' || v_slot
           ) is not null then
          v_sent := v_sent + 1;
        end if;
      end if;
    end if;
  end loop;

  -- ── B(미러닝) : 일요일만 ─────────────────────────────────────────────────
  -- 이번 주 한 번도 안 뛴 사용자에게 토·일 두 번 보내면 잔소리다. 마지막 기회 1회로 족하다.
  if v_slot = 'sun' then
    for r in
      select p.id as user_id, p.current_tier as tier
        from public.profiles p
       where not exists (
               select 1 from public.leaderboard_entries le
                where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
                  and le.tier is not null and le.period_start = v_start and le.user_id = p.id
             )
         and exists (
               select 1 from public.runs a
                where a.user_id = p.id and a.status = 'completed' and a.is_flagged = false
                  and a.started_at >= p_at - interval '28 days'
             )
    loop
      -- **미러닝자에게 현재 순위(= 사실상 꼴찌)를 보여주면 안 된다.** 보여줄 것은
      -- 현재 위치가 아니라 도달 가능한 위치다 — "5km를 뛰면 상위 몇 %인가".
      select count(*)::integer into v_pc
        from public.leaderboard_entries le
       where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
         and le.tier = r.tier and le.period_start = v_start;

      select public.top_pct(
               (select count(*)::integer + 1
                  from public.leaderboard_entries le
                 where le.period = 'weekly' and le.metric = 'distance' and le.scope = 'global'
                   and le.tier = r.tier and le.period_start = v_start and le.score > 5000),
               v_pc + 1)
        into v_proj;

      v_title := '이번 주 기록이 아직 없어요';
      v_body  := public.tier_ko(r.tier) || ' 랭킹 마감까지 오늘 하루.'
                 || case when v_proj is null then ' 5km면 이번 주 기록이 남아요.'
                         else ' 5km면 상위 ' || v_proj || '%예요.' end;

      if public.enqueue_notification(
           r.user_id, 'weekend_push', v_title, v_body, '/ranking',
           jsonb_build_object('rank', null, 'participant_count', v_pc,
                              'remaining_m', 5000, 'tier', r.tier::text,
                              'week_id', v_week, 'variant', 'B'),
           'weekend_push:' || v_week || ':' || v_slot
         ) is not null then
        v_sent := v_sent + 1;
      end if;
    end loop;
  end if;

  return v_sent;
end;
$$;

comment on function public.notify_weekend_push(timestamptz) is
  'NT-05 주말 막판 유도. 토 10:00 / 일 18:00 KST, 주당 최대 2건. 격차 5km 초과는 발송하지 '
  '않는다(주말 하루로 뒤집을 수 없는 격차는 추격 신호가 아니라 포기 신호). 문구는 RK-04 '
  '포맷("앞사람까지 0.8km · 128위(상위 34%)") — PRD §5.10 의 "10위까지" 예시는 구현하지 않는다.';
revoke execute on function public.notify_weekend_push(timestamptz) from public, anon, authenticated;

-- =============================================================================
-- 46-4. pg_cron 스케줄 (서버는 UTC. 아래 주석의 시각이 KST 정본)
-- =============================================================================
select cron.unschedule('runnit-notify-season-ending')  where exists (select 1 from cron.job where jobname = 'runnit-notify-season-ending');
select cron.unschedule('runnit-rank-notify')           where exists (select 1 from cron.job where jobname = 'runnit-rank-notify');
select cron.unschedule('runnit-weekend-push-sat')      where exists (select 1 from cron.job where jobname = 'runnit-weekend-push-sat');
select cron.unschedule('runnit-weekend-push-sun')      where exists (select 1 from cron.job where jobname = 'runnit-weekend-push-sun');

-- NT-03 : 매일 09:00 KST (= 00:00 UTC). 아침이 하루 러닝 계획을 세우는 시각이다.
--         TRD §6.4 의 시즌 경계 배치(분기 첫날 00:05 KST)와 **별도 스케줄**이다.
select cron.schedule('runnit-notify-season-ending', '0 0 * * *',
  $cron$ select public.notify_season_ending(); $cron$);

-- NT-04 : 매시 정각, KST 08~22시 (= UTC 23시 + 00~13시).
--         랭킹 갱신과 **같은 함수 안에서** 체이닝한다 — 별도 주기로 돌리면 rank
--         스냅샷이 어긋난다. 기존 5분 주기 runnit-leaderboard 는 그대로 둔다
--         (화면 신선도용). 여기서 한 번 더 도는 것은 멱등이라 안전하다.
select cron.schedule('runnit-rank-notify', '0 23,0-13 * * *',
  $cron$ select public.refresh_leaderboards_and_notify(); $cron$);

-- NT-05 : 토 10:00 KST (= 토 01:00 UTC) / 일 18:00 KST (= 일 09:00 UTC).
select cron.schedule('runnit-weekend-push-sat', '0 1 * * 6',
  $cron$ select public.notify_weekend_push(); $cron$);
select cron.schedule('runnit-weekend-push-sun', '0 9 * * 0',
  $cron$ select public.notify_weekend_push(); $cron$);
