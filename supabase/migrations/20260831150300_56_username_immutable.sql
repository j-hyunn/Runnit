-- =============================================================================
-- Runnit :: 56. username(고유 핸들) 서버 강제 고정 — AC-02 QA F-2
-- -----------------------------------------------------------------------------
-- 배경(QA 리포트 `_workspace/20260831_193521_qa_ac02-ac03.md` F-2):
--   AC-02 프로필 편집은 username 을 "읽기 전용"으로 두지만, 그 고정이 클라이언트
--   폼에만 있었다. `trg_profiles_guard`(05/19/39)는 블랙리스트라 열거되지 않은
--   컬럼을 통과시키고, `profiles_update_self` RLS 는 본인 행 UPDATE 전권을 준다.
--   즉 REST 를 직접 호출하면 핸들을 바꿀 수 있었다. username 은 랭킹·공유 카드·
--   알림의 사람 식별자라 변조되면 안 된다.
--
--   클라이언트는 이미 `_editablePatch` 에서 username 키를 제거했다(같은 커밋).
--   이 마이그레이션은 서버 백스톱이다.
--
-- 설계:
--   UPDATE 분기에서 `new.username := old.username` 을 **is_server_write 검사 밖**에
--   둔다 — PK(new.id) 와 같은 취급이다. username 은 생성 후 불변 식별자이고,
--   서버 배치에도 이를 바꾸는 정상 경로가 없다. 훗날 관리자 개명 기능이 필요하면
--   그때 별도 SECURITY DEFINER 함수로 열고 이 가드에 예외를 판다.
--   INSERT 분기는 그대로 둔다 — 가입 트리거(`on_auth_user_created`)가 username 을
--   여기서 처음 심는다.
--
-- 39 의 함수 본문을 그대로 두고 UPDATE 초입 한 줄만 추가한다(create or replace).
-- =============================================================================

create or replace function public.trg_profiles_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := now();

    if not public.is_server_write() then
      new.total_distance_meters   := 0;
      new.total_moving_seconds    := 0;
      new.total_run_count         := 0;
      new.total_xp                := 0;
      new.level                   := 1;
      new.current_streak_days     := 0;
      new.longest_streak_days     := 0;
      new.current_streak_weeks    := 0;
      new.longest_streak_weeks    := 0;
      new.streak_freeze_credits   := 1;
      new.streak_last_active_week := null;
      new.last_run_at             := null;
      new.current_tier            := 'bronze';
      new.season_distance_meters  := 0;
      new.tier_season_id          := null;
    end if;
    return new;
  end if;

  new.id         := old.id;
  new.username   := old.username;   -- 56: 핸들은 생성 후 불변(AC-02 F-2)
  new.created_at := old.created_at;
  new.updated_at := now();

  if not public.is_server_write() then
    new.total_distance_meters   := old.total_distance_meters;
    new.total_moving_seconds    := old.total_moving_seconds;
    new.total_run_count         := old.total_run_count;
    new.total_xp                := old.total_xp;
    new.level                   := old.level;
    new.current_streak_days     := old.current_streak_days;
    new.longest_streak_days     := old.longest_streak_days;
    new.current_streak_weeks    := old.current_streak_weeks;
    new.longest_streak_weeks    := old.longest_streak_weeks;
    new.streak_freeze_credits   := old.streak_freeze_credits;
    new.streak_last_active_week := old.streak_last_active_week;
    new.last_run_at             := old.last_run_at;
    new.crew_id                 := old.crew_id;
    new.current_tier            := old.current_tier;
    new.season_distance_meters  := old.season_distance_meters;
    new.tier_season_id          := old.tier_season_id;
  end if;

  return new;
end;
$$;

-- 19 가 걸어둔 실행 권한 회수를 유지한다(트리거 함수는 직접 호출 불가).
revoke execute on function public.trg_profiles_guard() from public, anon, authenticated;
