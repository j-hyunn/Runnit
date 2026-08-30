-- =============================================================================
-- Runnit :: 45. 알림 트리거 계열 — NT-01 티어 승급 / NT-02 티어 근접 / NT-06 뱃지·레벨
-- -----------------------------------------------------------------------------
-- 정본: _workspace/20260828_181500_gamification_notification-rules.md §1 · §5
--       _workspace/20260828_164428_architect_notifications.md §0 · §4
--
-- 왜 트리거인가: 티어는 **기록 저장 즉시** 확정된다(PRD §8.1). 승급 판정이 배치로
-- 밀리면 "방금 골드가 됐는데 홈 화면은 실버"라는 상태가 생기고, 티어·랭킹이라는
-- 이 앱의 화폐가 신뢰를 잃는다. 랭킹 계열(NT-03/04/05)은 46번 배치가 담당한다.
--
-- 트리거 순서 (runs 테이블) — 접두 번호로 고정
--   runs_01_recompute_stats     프로필 캐시·XP·레벨 + 시즌 티어 재계산
--   runs_02_challenge_progress  챌린지 진척
--   runs_03_evaluate_badges     뱃지 재평가·지급
--   runs_04_notifications       ← 신설. 위 셋의 **결과를 읽어** NT-02 / NT-06 발행
--
-- ⚠️ 방해 금지 시간 예외(§5.4): 트리거 계열(NT-01/02/06)은 22:00~08:00 에도 보낸다.
--    사용자가 **방금 러닝을 끝낸 순간**이기 때문이다. 새벽 5시에 뛴 사람에게
--    "방금 골드로 승급했어요"를 08:00까지 미루면 러닝의 문맥이 사라진 뒤 도착한다.
--    배치 계열만 08:00~22:00 으로 제한한다(46번).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 45-1. 트랜잭션 내 성취 묶음용 세션 변수 2개
-- -----------------------------------------------------------------------------
-- `한 러닝 = 성취 푸시 최대 1건`(§5.2)을 지키려면 "뱃지 지급"과 "레벨 상승"이 같은
-- 러닝에서 일어났는지 알아야 한다. 레벨 상승은 profiles UPDATE 로만 관측되고 러닝
-- 정보를 갖고 있지 않으므로, 러닝 트리거가 자기 run_id 를 트랜잭션 로컬 설정에
-- 남기고 레벨 트리거가 그것을 읽는다.
--
--   runnit.notify_run_id  : 지금 처리 중인 러닝 id (runs_01 이 심고 runs_04 가 지운다)
--   runnit.notify_level   : 이 트랜잭션에서 오른 최종 레벨 (profiles 트리거가 심는다)
--
-- 별도 테이블을 쓰지 않는 이유: 이 상태의 수명은 트랜잭션 하나이고, 테이블로 만들면
-- 롤백된 트랜잭션의 잔재를 청소하는 배치가 또 필요해진다.

create or replace function public._notify_ctx(p_key text)
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select nullif(coalesce(current_setting(p_key, true), ''), '');
$$;

revoke execute on function public._notify_ctx(text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 45-2. runs_01 확장 — run_id 를 트랜잭션 컨텍스트에 심는다
-- -----------------------------------------------------------------------------
-- 마이그레이션 22 의 본문 그대로이며, 맨 앞의 set_config 한 줄만 더했다.
create or replace function public.trg_runs_recompute_stats()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recompute_profile_stats(old.user_id);
    perform public.recompute_season_tier(old.user_id);
    return old;
  end if;

  -- (45번) 이 트랜잭션이 "러닝 저장 유래"임을 표시한다. runs_04 가 읽고 지운다.
  perform set_config('runnit.notify_run_id', new.id::text, true);

  perform public.recompute_profile_stats(new.user_id);
  perform public.recompute_season_tier(new.user_id);

  if tg_op = 'UPDATE' and old.user_id is distinct from new.user_id then
    perform public.recompute_profile_stats(old.user_id);
    perform public.recompute_season_tier(old.user_id);
  end if;
  return new;
end;
$$;

revoke execute on function public.trg_runs_recompute_stats() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 45-3. NT-01 티어 승급 — tier_change_history INSERT 가 유일한 발화점
-- -----------------------------------------------------------------------------
-- 왜 profiles.current_tier 감시가 아니라 이 테이블인가:
--   `tier_change_history` 는 마이그레이션 34 이후 **상승만** 기록한다. 시즌 하드
--   리셋(전원 브론즈)과 부정 기록 무효화는 이 테이블에 행을 만들지 않으므로,
--   여기 INSERT 되는 것이 곧 "승급"이다. profiles 를 감시하면 시즌 경계의 리셋을
--   승급과 구분하는 분기를 따로 써야 하고, 그 분기가 틀리면 분기 첫날 전 사용자에게
--   "브론즈 승급!" 알림이 나간다.
--
-- 상한: dedupe_key = tier_promotion:{season_id}:{tier} → 시즌당 최대 3건(구조적).
create or replace function public.trg_tier_promotion_notify()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_dist double precision;
begin
  -- 브론즈는 시즌 시작 기본값이라 "승급"이 아니다. 34번이 상승만 기록하므로 여기
  -- 브론즈 행이 들어올 경로는 없지만, 방어선으로 남긴다.
  if new.tier = 'bronze' then
    return null;
  end if;

  select p.season_distance_meters into v_dist
    from public.profiles p where p.id = new.user_id;

  perform public.enqueue_notification(
    new.user_id,
    'tier_promotion',
    public.tier_ko(new.tier) || ' 승급!',
    '이번 시즌 ' || public.fmt_km(v_dist) || 'km를 달렸어요. '
      || public.season_label(new.season_id) || ' ' || public.tier_ko(new.tier) || '에 올랐어요.',
    '/home',
    jsonb_build_object(
      'tier', new.tier::text,
      'season_id', new.season_id,
      'season_distance_m', round(coalesce(v_dist, 0))
    ),
    'tier_promotion:' || new.season_id || ':' || new.tier::text
  );
  return null;
end;
$$;

revoke execute on function public.trg_tier_promotion_notify() from public, anon, authenticated;

drop trigger if exists tier_change_history_02_notify on public.tier_change_history;
create trigger tier_change_history_02_notify
after insert on public.tier_change_history
for each row execute function public.trg_tier_promotion_notify();

-- -----------------------------------------------------------------------------
-- 45-4. NT-06 레벨 상승 — profiles.level 감시
-- -----------------------------------------------------------------------------
-- gamification §5.1 확정: **`user_badges` 에 레벨업 합성 행을 만들지 않는다.**
--   ① XP_badge 가 user_badges 행마다 XP 를 주므로 합성 행은 레벨업→XP→레벨업 순환을
--      만든다(TRD 가 category='level' 뱃지의 XP 를 0 으로 못박은 것과 같은 함정).
--   ② 의미 있는 레벨 마일스톤(5/10/.../60)은 이미 lvl_* 뱃지로 존재하고 기존
--      AchievementCelebrationHost 가 잡는다.
--   ③ 만렙 60 = 생애 59번 레벨업. 매번 풀페이지 축하는 축하를 죽인다.
-- 따라서 레벨업은 **알림 전용 별도 경로**이고 인앱 축하 큐를 건드리지 않는다.
--
-- 러닝 유래면 여기서 보내지 않고 컨텍스트에만 남긴다 — runs_04 가 뱃지와 **묶어서**
-- 1건으로 보낸다(§5.2 한 러닝 = 성취 푸시 최대 1건).
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

  -- 러닝 없이 레벨이 오르는 경로가 실제로 있다: XP-3(뱃지 verified/revoked 변경)과
  -- XP-4(tier_change_history INSERT)도 total_xp 를 갱신한다(TRD §3.8.4).
  -- 그때는 run_id 가 없으므로 키를 레벨로 잡는다.
  v_next_xp := (public.xp_level_thresholds())[new.level + 1];

  perform public.enqueue_notification(
    new.user_id,
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

drop trigger if exists profiles_02_level_notify on public.profiles;
create trigger profiles_02_level_notify
after update of level on public.profiles
for each row execute function public.trg_level_up_notify();

-- -----------------------------------------------------------------------------
-- 45-5. runs_04_notifications — NT-02 근접 + NT-06 묶음
-- -----------------------------------------------------------------------------
create or replace function public.trg_runs_notifications()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_season      text;
  v_tier        public.tier;
  v_next        public.tier;
  v_dist        double precision;
  v_total_xp    integer;
  v_remaining   double precision;
  v_threshold   integer;
  -- NT-06
  v_level       integer;
  v_badge_cnt   integer := 0;
  v_rep_id      uuid;
  v_rep_name    text;
  v_rep_desc    text;
  v_title       text;
  v_body        text;
  v_next_xp     integer;
begin
  -- ── NT-02 다음 티어 근접 ────────────────────────────────────────────────
  -- 조건 6가지가 전부 참일 때만 1건. 하나라도 빠지면 "곧 승급"이 거짓말이 된다.
  select p.tier_season_id, p.current_tier, p.season_distance_meters, p.total_xp, p.level
    into v_season, v_tier, v_dist, v_total_xp, v_level
    from public.profiles p where p.id = new.user_id;

  v_next := public.next_tier(v_tier);

  if v_season is not null
     and v_next is not null                                    -- ① 플래티넘이면 다음 목표가 없다
     and coalesce(new.is_flagged, false) = false               -- ④ 부정 기록으로 승급을 약속하지 않는다
     and new.status = 'completed'
     and new.activity_type <> 'indoor_run'                     -- ④ PRD §8.3 실내·수동은 티어 미반영
     and public.season_end(v_season) - now() > interval '24 hours'  -- ⑤ 도달 불가능한 목표는 안 보낸다
  then
    v_threshold := public.tier_proximity_threshold_m(v_next);
    v_remaining := public.tier_threshold_m(v_next) - coalesce(v_dist, 0);

    -- ② remaining > 0 : 0 이하면 이미 승급이라 NT-01 이 대신 나간다. 같은 러닝에서
    --    승급 알림과 근접 알림이 겹치면 안 된다.
    -- ③ 밴드 안(§1.1 구간별 고정 테이블)
    if v_remaining > 0 and v_remaining <= v_threshold then
      perform public.enqueue_notification(
        new.user_id,
        'tier_proximity',
        public.tier_ko(v_next) || '까지 ' || public.fmt_km(v_remaining) || 'km',
        '이번 시즌 ' || public.fmt_km(v_dist) || 'km를 달렸어요. 한 번만 더 나가면 '
          || public.tier_ko(v_next) || '예요.',
        '/home',
        jsonb_build_object(
          'tier', v_next::text,
          'remaining_m', round(v_remaining),
          'season_id', v_season
        ),
        -- 시즌·티어당 정확히 1회. 재발송 규칙이 없는 이유: 시즌 누적 거리는 단조
        -- 증가(TI-08)라 잔여 거리는 단조 감소하고, 정상 경로에서 각 밴드에 단 한 번만
        -- 진입한다. 예외는 부정 기록 무효화로 거리가 줄었다 다시 느는 경우인데,
        -- 그 사용자에게 "다시 5km 남았어요"를 보내는 것은 최악의 UX다 — 키가 막는다.
        'tier_proximity:' || v_season || ':' || v_next::text
      );
    end if;
  end if;

  -- ── NT-06 뱃지·레벨 묶음 (한 러닝 = 성취 푸시 최대 1건) ─────────────────
  -- 티어 승급 뱃지(category='season_tier')는 **세지 않는다**. NT-01 이 같은 사건을
  -- 이미 알렸고, "골드 승급!" + "뱃지 1개 획득(골드 뱃지)"는 같은 것을 두 번 세는 것이다.
  select count(*)::integer
    into v_badge_cnt
    from public.user_badges ub
    join public.badges b on b.id = ub.badge_id
   where ub.source_run_id = new.id
     and ub.user_id = new.user_id
     and ub.revoked = false
     and b.category <> 'season_tier';

  if v_badge_cnt > 0 then
    -- 대표 = 최고 grade, 동급이면 카탈로그 순(id).
    select ub.id, b.name, b.description
      into v_rep_id, v_rep_name, v_rep_desc
      from public.user_badges ub
      join public.badges b on b.id = ub.badge_id
     where ub.source_run_id = new.id
       and ub.user_id = new.user_id
       and ub.revoked = false
       and b.category <> 'season_tier'
     order by case b.badge_grade
                when 'diamond'  then 5
                when 'platinum' then 4
                when 'gold'     then 3
                when 'silver'   then 2
                when 'bronze'   then 1
                else 0                     -- special 은 희소도 축이 다르다. 최하위로 둔다.
              end desc,
              b.id asc
     limit 1;
  end if;

  v_level := nullif(public._notify_ctx('runnit.notify_level'), '')::integer;

  if v_badge_cnt > 0 or v_level is not null then
    v_next_xp := case when v_level is null then null
                      else (public.xp_level_thresholds())[v_level + 1] end;

    v_title := case
      when v_level is not null and v_badge_cnt > 0
        then 'Lv.' || v_level || ' 달성 · 뱃지 ' || v_badge_cnt || '개 획득'
      when v_level is not null then 'Lv.' || v_level || ' 달성'
      when v_badge_cnt = 1     then v_rep_name || ' 획득!'
      else '뱃지 ' || v_badge_cnt || '개를 획득했어요'
    end;

    v_body := case
      when v_badge_cnt = 1  then coalesce(v_rep_desc, v_rep_name)
      when v_badge_cnt >= 2 then v_rep_name || ' 외 ' || (v_badge_cnt - 1) || '개'
      when v_next_xp is null then '누적 ' || v_total_xp || 'XP · 만렙에 도달했어요.'
      else '누적 ' || v_total_xp || 'XP · 다음 레벨까지 '
           || greatest(v_next_xp - v_total_xp, 0) || 'XP'
    end;

    perform public.enqueue_notification(
      new.user_id,
      'badge_level',
      v_title,
      v_body,
      '/runs/' || new.id::text,
      jsonb_build_object(
        -- ⚠️ user_badge_id 는 **참조용**이다. 클라이언트는 이 값으로 인앱 축하를 띄우지
        --    않는다(ARCHITECTURE §7.4.1 — 소비 지점은 AchievementCelebrationHost 하나).
        --    푸시를 탭하면 이동만 하고, 큐에 is_seen=false 행이 있으면 호스트가 축하한다.
        --    뱃지 3개면 호스트가 3개를 순차 축하한다 — 푸시가 1건인 것과 무관하며 정상이다.
        'user_badge_id', v_rep_id,
        'badge_count', v_badge_cnt,
        'level', v_level,
        'run_id', new.id
      ),
      'badge_level:run:' || new.id::text
    );
  end if;

  -- 컨텍스트 정리. 한 트랜잭션에서 러닝을 여러 건 올리면 다음 행으로 새어 나간다.
  perform set_config('runnit.notify_level',  '', true);
  perform set_config('runnit.notify_run_id', '', true);
  return null;
end;
$$;

revoke execute on function public.trg_runs_notifications() from public, anon, authenticated;

drop trigger if exists runs_04_notifications on public.runs;
create trigger runs_04_notifications
after insert or update on public.runs
for each row execute function public.trg_runs_notifications();

comment on function public.trg_runs_notifications() is
  'NT-02(티어 근접) + NT-06(뱃지·레벨 묶음). runs_01~03 의 결과를 읽으므로 반드시 마지막에 '
  '돈다. 한 러닝의 최대 성취 푸시는 2건(NT-01 tier_promotion + NT-06 badge_level) — '
  '뱃지 3개 + 레벨업이 동시에 터져도 badge_level 은 1건이다.';
