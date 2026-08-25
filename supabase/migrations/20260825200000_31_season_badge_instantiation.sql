-- =============================================================================
-- Runnit :: 31. 시즌 뱃지 인스턴스 발급 (PRD GM-08 / §5.5)
-- -----------------------------------------------------------------------------
-- 근거: _workspace/20260825_181914_backend_badge-v2-migration.md §7.3
--       _workspace/20260825_193000_backend_badge-evaluation-logic.md §8-3
--
-- scope='seasonal' && season_id is null 인 41개 행은 "마스터 템플릿"이다.
-- 이 마이그레이션은 현재 시즌(Season.currentId() 와 동일 공식, public.season_id_at())에
-- 대해 템플릿을 `{templateId}@{seasonId}` id 로 복제한 "인스턴스" 행을 만든다.
--
-- seasons 테이블을 새로 만들지 않았다 — architect/backend 이전 판단이 여전히 유효하다:
-- 시즌은 달력에서 결정론적으로 유도되고(season_id_at/season_start/season_end, 마이그레이션 20),
-- season_id 는 badges.season_id 에 FK 없는 text 로 이미 저장되고 있다(25번 스키마).
-- 인스턴스 테이블에 필요한 것은 "이 텍스트 값이 유효한 시즌인가"뿐인데 그건
-- season_id_at 의 정규식과 동일한 포맷 체크(badges_season_id_scope 는 이미 있음)로 충분하다.
--
-- 발급 시점: **lazy + 3개 진입점**. 별도 크론을 새로 두지 않고 기존 시즌 관련 경로
-- 3곳에 멱등 호출을 끼워 넣는다(ON CONFLICT (id) DO NOTHING 이라 중복 호출이 안전하다):
--   1) evaluate_badges()     — 러닝 업로드 시 (뱃지가 지급되려면 인스턴스가 있어야 한다)
--   2) sync_my_season()      — 홈 화면 진입 시 (러닝을 하지 않아도 갤러리에 시즌 뱃지가 보여야 한다)
--   3) reset_stale_seasons() — 분기 첫날 00:05 KST 크론 (사용자가 열기 전에 미리 만들어 둔다)
-- 세 경로가 이미 "현재 시즌" 개념을 다루는 지점이라 새 크론보다 자연스럽고, 셋 중
-- 아무거나 먼저 도달해도 결과가 같다(멱등).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 31-1. ensure_season_badge_instances — 템플릿 41종 -> 현재 시즌 인스턴스 발급(멱등)
-- -----------------------------------------------------------------------------
create or replace function public.ensure_season_badge_instances(
  p_season_id text default null
)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_season text := coalesce(p_season_id, public.season_id_at(now()));
  v_count  integer;
begin
  if v_season !~ '^\d{4}-Q[1-4]$' then
    raise exception '잘못된 seasonId 형식 (기대: 2026-Q3): %', v_season using errcode = '22000';
  end if;

  insert into public.badges (
    id, name, description, category, scope, trigger_type,
    condition_type, condition, badge_grade, season_id
  )
  select
    tpl.id || '@' || v_season,
    tpl.name,
    tpl.description,
    tpl.category,
    tpl.scope,
    tpl.trigger_type,
    tpl.condition_type,
    tpl.condition,
    tpl.badge_grade,
    v_season
  from public.badges tpl
  where tpl.scope = 'seasonal'
    and tpl.season_id is null
  on conflict (id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.ensure_season_badge_instances(text)
  from public, anon, authenticated;

comment on function public.ensure_season_badge_instances(text) is
  '시즌 뱃지 템플릿(scope=seasonal, season_id is null) 41종을 {templateId}@{seasonId} id 로 '
  '복제해 현재(또는 지정) 시즌 인스턴스를 발급한다. 멱등(ON CONFLICT DO NOTHING). '
  '"리셋"은 상태 삭제가 아니라 새 시즌마다 새 badges 행 + 빈 user_badges 로 자연히 구현된다 — '
  '지난 시즌 인스턴스와 그 user_badges 는 그대로 남아 이력이 보존된다.';

-- -----------------------------------------------------------------------------
-- 31-2. evaluate_badges — 판정 루프 진입 시 현재 시즌 인스턴스를 먼저 보장
-- -----------------------------------------------------------------------------
-- 스코프 필터(scope='permanent' or (scope='seasonal' and season_id is not null))는
-- 27번에서 이미 그렇게 짜여 있다 — 인스턴스만 생기면 자동으로 판정 대상에 들어온다.
create or replace function public.evaluate_badges(p_user_id uuid, p_source_run_id uuid default null)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_badge   record;
  v_awarded integer := 0;
begin
  if p_user_id is null then
    return 0;
  end if;

  perform set_config('runnit.server_write', 'on', true);

  perform public.ensure_season_badge_instances();

  for v_badge in
    select b.id, b.condition_type, b.condition
    from public.badges b
    where (b.scope = 'permanent' or (b.scope = 'seasonal' and b.season_id is not null))
      and not exists (
        select 1 from public.user_badges ub
        where ub.user_id = p_user_id and ub.badge_id = b.id
      )
  loop
    if public.evaluate_badge_condition(p_user_id, v_badge.condition_type, v_badge.condition) then
      insert into public.user_badges (user_id, badge_id, earned_at, source_run_id, is_seen, verified, revoked)
      values (p_user_id, v_badge.id, now(), p_source_run_id, false, true, false)
      on conflict (user_id, badge_id) do nothing;

      if found then
        v_awarded := v_awarded + 1;
      end if;
    end if;
  end loop;

  perform set_config('runnit.server_write', 'off', true);

  return v_awarded;
end;
$function$;

revoke execute on function public.evaluate_badges(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 31-3. sync_my_season — 홈 화면 읽기 경로에서도 보장 (러닝 없이도 갤러리에 노출)
-- -----------------------------------------------------------------------------
create or replace function public.sync_my_season()
returns public.tier
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_season text := public.season_id_at(now());
  v_tier   public.tier;
  v_stale  boolean;
begin
  if v_uid is null then
    raise exception '인증이 필요하다' using errcode = '28000';
  end if;

  perform public.ensure_season_badge_instances(v_season);

  select (p.tier_season_id is distinct from v_season), p.current_tier
    into v_stale, v_tier
    from public.profiles p
   where p.id = v_uid;

  if not found then
    return null;
  end if;

  if v_stale then
    perform public.recompute_season_tier(v_uid, now());
    select p.current_tier into v_tier from public.profiles p where p.id = v_uid;
  end if;

  return v_tier;
end;
$$;

revoke execute on function public.sync_my_season() from public, anon;
grant  execute on function public.sync_my_season() to authenticated;

comment on function public.sync_my_season() is
  '읽기 경로 지연 복구: 본인 프로필의 시즌이 지났으면 마감+리셋 후 현재 티어를 반환. '
  '31번부터는 호출 시마다 현재 시즌 뱃지 인스턴스 발급도 함께 보장한다(멱등). 멱등.';

-- -----------------------------------------------------------------------------
-- 31-4. reset_stale_seasons — 분기 크론에서도 보장 (사용자가 열기 전에 미리 발급)
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

revoke execute on function public.reset_stale_seasons(timestamptz)
  from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 31-5. 백필 — 지금 당장 현재 시즌 인스턴스를 만들어 둔다(검증 편의 + 실제 발급).
-- -----------------------------------------------------------------------------
select public.ensure_season_badge_instances();
