-- =============================================================================
-- Runnit :: 18. handle_new_auth_user() 동시 가입 경합(레이스 컨디션) 수정
-- -----------------------------------------------------------------------------
-- mobile-architect 지적(카카오 전용 로그인 세션, _workspace/20260820_125920_auth_architecture.md):
-- 기존 "while exists 조회 -> insert" 패턴은 조회와 삽입 사이에 TOCTOU 경합이 있다.
-- 이메일 미동의(카카오 email scope 미동의) 사용자는 폴백 베이스가 전부 'runner'로
-- 수렴하므로, 두 사용자가 정확히 동시에 가입하면 둘 다 조회 시점엔 "비어있음"으로
-- 보여 같은 username 으로 insert 를 시도하고, 하나는 profiles_username_key 위반으로
-- **auth 가입 자체가 실패**할 수 있었다.
--
-- 수정: INSERT 시도 -> unique_violation 캐치 -> 새 후보로 재시도(낙관적 동시성).
-- PL/pgSQL 의 EXCEPTION 블록은 암묵적 서브트랜잭션(세이브포인트)이라 실패한 시도만
-- 롤백되고 트리거 전체는 계속 진행된다.
--
-- 검증: 이메일 없는 두 사용자를 동일 raw_user_meta_data(name="레이스테스트")로
-- 순차 가입시켜 username 'runner' / 'runner_9769' 로 정상 분기됨을 확인(원격에서
-- 실제 auth.users insert 후 삭제로 검증, 잔여 데이터 없음).
-- =============================================================================

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

  v_username := v_base;

  loop
    v_try := v_try + 1;
    begin
      insert into public.profiles (id, username, display_name, avatar_url)
      values (new.id, v_username, v_display_name, v_avatar_url)
      on conflict (id) do nothing;
      exit;
    exception when unique_violation then
      if v_try > 20 then
        v_username := 'runner_' || replace(new.id::text, '-', '');
        v_username := left(v_username, 30);
        insert into public.profiles (id, username, display_name, avatar_url)
        values (new.id, v_username, v_display_name, v_avatar_url)
        on conflict (id) do nothing;
        exit;
      end if;
      v_username := v_base || '_' || lpad((floor(random() * 10000))::int::text, 4, '0');
    end;
  end loop;

  return new;
end;
$$;

comment on function public.handle_new_auth_user() is
  'auth.users AFTER INSERT 트리거. username 충돌은 조회 후 삽입이 아니라 삽입 시도 + '
  'unique_violation 캐치 + 재시도(낙관적 동시성)로 처리해 동시 가입 경합을 막는다.';
