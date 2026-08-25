-- =============================================================================
-- Runnit :: 17. 게스트(비로그인) 모드 — anon 롤에 랭킹/뱃지 카탈로그만 개방
-- -----------------------------------------------------------------------------
-- 배경
--   07_rls.sql 은 "Runnit 은 로그인 사용자 전용" 전제로 anon 의 모든 테이블 GRANT 를
--   회수하고 모든 정책을 `to authenticated` 로 만들었다. 이제 로그인 수단이 카카오
--   하나뿐이므로, 로그인 전에 앱을 둘러볼 수 있는 게스트 모드가 필요하다.
--
-- 공개 범위(사용자 확정)
--   O  badges              — 뱃지 카탈로그(마스터 데이터). 개인정보 없음.
--   O  leaderboard_entries — 랭킹. 단, **scope = 'global' 행만**.
--   X  profiles, runs, user_badges, challenges, challenge_participations
--      -> 개인 식별/개인 활동 데이터. anon 에게 절대 열지 않는다.
--
-- leaderboard_entries 를 통째로 열지 않고 scope 를 제한하는 이유:
--   'crew' 는 특정 크루 내부 랭킹, 'friends' 는 팔로우 관계에 의존하는 랭킹이다.
--   두 스코프는 "누가 어느 크루에 속하는가 / 누구와 친구인가"라는 관계 정보를
--   순위표 형태로 노출한다. 로그인 사용자에게는 기존대로 전부 보이지만(정책 변경 없음),
--   익명 사용자에게까지 관계 정보를 흘릴 이유는 없다. 게스트가 크루/친구 탭을 열면
--   빈 결과가 오고, UI 는 로그인 유도 화면을 띄우면 된다.
--
-- 남는 노출(의도된 것): global 랭킹 행에는 username / display_name / avatar_url
--   스냅샷이 들어 있어 익명 사용자에게도 보인다. "랭킹 전체 공개"가 제품 요구사항이므로
--   그대로 둔다. display_name 에 실명을 넣는 사용자가 있을 수 있다는 점은
--   가입 UX(프로필 편집 안내)에서 다룰 문제이지 RLS 로 막을 문제가 아니다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) badges : anon 도 카탈로그 전체 조회
-- -----------------------------------------------------------------------------
-- 기존 badges_select_all(to authenticated) 은 건드리지 않고 anon 전용 정책을 더한다.
-- (정책은 OR 로 합쳐지며, 롤이 다르므로 서로 간섭하지 않는다.)
create policy badges_select_anon
  on public.badges for select
  to anon
  using (true);

grant select on public.badges to anon;

-- -----------------------------------------------------------------------------
-- 2) leaderboard_entries : anon 은 글로벌 랭킹만
-- -----------------------------------------------------------------------------
create policy leaderboard_select_anon_global
  on public.leaderboard_entries for select
  to anon
  using (scope = 'global');

grant select on public.leaderboard_entries to anon;

comment on policy leaderboard_select_anon_global on public.leaderboard_entries is
  '게스트 모드: 익명 사용자는 글로벌 랭킹만 조회. crew/friends 스코프는 관계 정보 노출이라 제외.';

-- -----------------------------------------------------------------------------
-- 3) 나머지 테이블은 anon 차단 상태를 재확인(멱등). 07 이후 누군가 열었더라도 되돌린다.
-- -----------------------------------------------------------------------------
revoke all on public.profiles, public.runs, public.user_badges,
              public.challenges, public.challenge_participations
  from anon;
revoke all on public.run_summaries from anon;

-- -----------------------------------------------------------------------------
-- 4) handle_new_auth_user : OAuth(카카오) 메타데이터 키에 대응
-- -----------------------------------------------------------------------------
-- 06 의 원본은 raw_user_meta_data 에서 'username' / 'display_name' / 'avatar_url' 만
-- 읽는다. 이 키들은 이메일+비밀번호 가입 시 클라이언트가 직접 넣어주던 것이고,
-- GoTrue 가 OAuth 프로바이더 응답으로 채우는 키는 다르다. 카카오의 경우 대략
--   name / full_name / nickname / preferred_username / user_name / picture / avatar_url
-- 가 들어오고 'display_name' 은 **들어오지 않는다**. 그대로 두면 카카오로 가입한
-- 사용자의 display_name 이 전부 NULL 이 되어 랭킹/프로필에 표시할 이름이 없다.
--
-- 이메일도 마찬가지다. 카카오는 이메일 제공 동의가 선택 항목이라 new.email 이
-- NULL 일 수 있다. 그 경우 username 기반값은 'runner' 로 떨어지고 아래 충돌 루프가
-- 'runner_0417' 같은 접미사를 붙인다 — 이 폴백은 원본 그대로 유효하므로 유지한다.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_meta         jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_base         text;
  v_username     text;
  v_display_name text;
  v_avatar_url   text;
  v_try          integer := 0;
begin
  -- username 기반값: 명시 username -> OAuth 핸들류 -> 이메일 로컬파트 -> 'runner'
  -- (카카오 닉네임은 한글인 경우가 많고, 아래 regexp 가 ASCII 외 문자를 지우므로
  --  실질적으로 'runner' 로 떨어진다. 의도된 동작 — 핸들은 나중에 사용자가 바꾼다.)
  v_base := coalesce(
    nullif(regexp_replace(coalesce(v_meta ->> 'username', ''),           '[^a-zA-Z0-9._-]', '', 'g'), ''),
    nullif(regexp_replace(coalesce(v_meta ->> 'preferred_username', ''), '[^a-zA-Z0-9._-]', '', 'g'), ''),
    nullif(regexp_replace(coalesce(v_meta ->> 'user_name', ''),          '[^a-zA-Z0-9._-]', '', 'g'), ''),
    nullif(regexp_replace(split_part(coalesce(new.email, ''), '@', 1),   '[^a-zA-Z0-9._-]', '', 'g'), ''),
    'runner'
  );
  v_base := left(v_base, 20);
  if length(v_base) < 2 then
    v_base := 'runner';
  end if;

  v_username := v_base;
  while exists (select 1 from public.profiles p where lower(p.username) = lower(v_username)) loop
    v_try := v_try + 1;
    v_username := v_base || '_' || lpad((floor(random() * 10000))::int::text, 4, '0');
    if v_try > 20 then
      v_username := 'runner_' || replace(new.id::text, '-', '');
      v_username := left(v_username, 30);
      exit;
    end if;
  end loop;

  -- 표시 이름: 명시값 -> 카카오/OAuth 가 주는 이름 계열. 전부 없으면 NULL(=UI 는 username 표시).
  v_display_name := coalesce(
    nullif(v_meta ->> 'display_name', ''),
    nullif(v_meta ->> 'full_name', ''),
    nullif(v_meta ->> 'name', ''),
    nullif(v_meta ->> 'nickname', '')
  );
  v_display_name := left(v_display_name, 50);

  v_avatar_url := coalesce(
    nullif(v_meta ->> 'avatar_url', ''),
    nullif(v_meta ->> 'picture', '')
  );

  insert into public.profiles (id, username, display_name, avatar_url)
  values (new.id, v_username, v_display_name, v_avatar_url)
  on conflict (id) do nothing;

  return new;
end;
$$;

-- 14/15 에서 트리거 함수의 RPC 노출을 회수했다. 함수를 재정의하면 기본 EXECUTE 권한이
-- 다시 붙으므로 동일하게 회수한다(PostgREST 로 직접 호출 불가하게 유지).
revoke execute on function public.handle_new_auth_user() from public, anon, authenticated;
