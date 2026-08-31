-- =============================================================================
-- Runnit :: 54. AC-02 — avatars Storage 버킷 + storage.objects RLS
-- -----------------------------------------------------------------------------
-- 배경(PRD §5.8 AC-02): 프로필 사진 변경. 클라이언트가 이미지를 이 버킷에 업로드한 뒤
--   반환된 public URL 을 profiles.avatar_url 에 써 넣는다(컬럼 자체는 01 부터 있었고
--   지금까지는 카카오가 준 원격 URL 만 들어갔다 — 17_anon_guest_access 참조).
--
-- 경로 규약 (**반드시 지킬 것**):
--     avatars/{auth.uid()}/{임의 파일명}
--   1번째 폴더 세그먼트가 소유자 uuid 다. 아래 RLS 가 이 규약 하나로 쓰기 권한을
--   판정하므로, 클라이언트가 규약을 어기면 업로드가 42501 로 거절된다.
--   파일명에 타임스탬프를 넣어 **매번 새 경로**로 올리고 이전 파일을 지우는 방식을
--   권장한다(같은 경로 덮어쓰기는 CDN/이미지 캐시 때문에 앱에서 옛 사진이 남는다).
--
-- 왜 public 버킷인가:
--   AC-03(타인 프로필 조회)과 랭킹 리스트는 남의 아바타를 그려야 하고, 게스트 모드
--   (마이그레이션 17)에서도 global 랭킹의 avatar_url 이 보인다. 서명 URL 로 하면
--   랭킹 1페이지마다 N개의 서명을 발급받아야 하는데, 아바타는 애초에 랭킹에서
--   전원에게 공개되는 정보라 보호할 실익이 없다.
--   -> 읽기는 완전 공개, 쓰기만 본인 폴더로 제한한다.
--
-- 용량/포맷 제한은 정책이 아니라 **버킷 설정**으로 건다:
--   RLS 술어에서는 업로드 바이트 수를 알 수 없다(metadata 는 업로드 완료 후 채워진다).
--   storage API 는 file_size_limit / allowed_mime_types 를 업로드 전에 강제한다.
--   2MB · jpeg/png/webp — 프로필 썸네일 용도로 충분하고, 클라이언트는 업로드 전에
--   리사이즈(장변 512px 권장)해서 올린다.
--
-- ⚠️ 이 파일은 storage 스키마를 건드린다. 로컬 `supabase db reset` 및 원격 적용 모두
--    postgres 롤로 실행되므로 storage.objects 에 정책을 만들 수 있다. 정책 생성이
--    권한 문제로 실패하면 Supabase 대시보드(Storage > Policies)에서 동일 술어로
--    만들어야 하며, 그 경우 이 파일의 정책 블록은 no-op 로 남는다.
--
-- 📌 원격 적용 이력 (2026-08-31, xwtbwexcofcgmbvktwdo):
--    · 버킷 insert 는 apply_migration 으로 적용됨.
--    · storage.objects 정책 4종은 apply_migration 이 `42501: must be owner of
--      table objects` 로 거부되어 **execute_sql(대시보드 SQL 에디터와 동등 경로)로
--      적용**했다. 즉 원격엔 반영됐으나 supabase_migrations 이력에는 정책 부분이
--      없다 — `db reset`/브랜치 DB 는 이 파일이 그대로 실행되며 정책 4종이 살아난다
--      (권한이 되는 환경이므로). 원격만 이력 밖이고, 값은 파일과 동일하다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) 버킷
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars',
  'avatars',
  true,
  2097152,                                              -- 2 MiB
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- -----------------------------------------------------------------------------
-- 2) storage.objects RLS — 읽기 전체 공개 / 쓰기는 본인 폴더만
-- -----------------------------------------------------------------------------
-- storage.objects 는 Supabase 가 이미 RLS 를 켜 둔 상태다(중복 실행 무해).
alter table storage.objects enable row level security;

drop policy if exists avatars_select_public   on storage.objects;
drop policy if exists avatars_insert_own      on storage.objects;
drop policy if exists avatars_update_own      on storage.objects;
drop policy if exists avatars_delete_own      on storage.objects;

-- 읽기: 로그인 여부 무관(게스트 랭킹에서도 아바타가 보여야 한다).
create policy avatars_select_public
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'avatars');

-- 업로드: 본인 uuid 폴더 안에만.
--   (storage.foldername(name))[1] = 첫 번째 경로 세그먼트.
--   auth.uid() 를 (select ...) 로 감싸는 것은 07_rls.sql 과 같은 이유(InitPlan).
create policy avatars_insert_own
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- 덮어쓰기(upsert: true 로 올릴 때 UPDATE 경로를 탄다).
--   using = 지금 그 파일이 내 폴더인가 / with check = 옮긴 뒤에도 내 폴더인가.
--   둘 다 걸어야 남의 파일을 내 폴더로 이름 바꿔 가져오는(=탈취) 경로가 막힌다.
create policy avatars_update_own
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- 삭제: 사진 교체 시 이전 파일 정리 + 사진 제거.
--   AC-04(계정 삭제) 시 남는 파일은 별도 정리 대상이다 — auth.users 삭제는
--   storage.objects 를 cascade 하지 않는다(§미해결, TRD §14 에 기록).
create policy avatars_delete_own
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

comment on policy avatars_select_public on storage.objects is
  'AC-02/AC-03: 아바타는 랭킹·타인 프로필에서 전원에게 보인다. 읽기 완전 공개.';
comment on policy avatars_insert_own on storage.objects is
  'AC-02: 경로 규약 avatars/{uid}/{filename}. 첫 세그먼트가 본인 uuid 여야 업로드 가능.';
