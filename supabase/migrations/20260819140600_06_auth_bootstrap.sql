-- =============================================================================
-- Runnit :: 06. Supabase Auth 연동 — 가입 시 profiles 행 자동 생성
-- -----------------------------------------------------------------------------
-- 클라이언트가 signUp 직후 별도로 profiles 를 INSERT 하게 만들면, 그 요청이
-- 실패했을 때 "auth 계정은 있는데 프로필이 없는" 유령 사용자가 남는다.
-- auth.users 트리거로 원자적으로 만든다.
-- =============================================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_base     text;
  v_username text;
  v_try      integer := 0;
begin
  -- 1순위: 가입 시 넘긴 메타데이터. 2순위: 이메일 로컬파트. 3순위: 'runner'
  v_base := coalesce(
    nullif(regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', ''), '[^a-zA-Z0-9._-]', '', 'g'), ''),
    nullif(regexp_replace(split_part(coalesce(new.email, ''), '@', 1), '[^a-zA-Z0-9._-]', '', 'g'), ''),
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

  insert into public.profiles (id, username, display_name, avatar_url)
  values (
    new.id,
    v_username,
    nullif(new.raw_user_meta_data ->> 'display_name', ''),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_auth_user();
