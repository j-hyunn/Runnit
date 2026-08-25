-- =============================================================================
-- Runnit :: 07. Row Level Security
-- -----------------------------------------------------------------------------
-- 원칙
--   1) 모든 public 테이블은 RLS 를 켠다. 정책이 없으면 = 접근 불가(기본 거부).
--   2) 러닝 원본(runs)은 **본인만** 조회 가능. 타인에게 보이는 것은 비정규화된
--      leaderboard_entries 와 profiles 의 공개 필드뿐이다.
--   3) 서비스 롤(service_role)은 RLS 를 우회하므로 별도 정책이 필요 없다.
--   4) 정책 술어에는 auth.uid() 를 그대로 쓰지 않고 (select auth.uid()) 로 감싼다.
--      전자는 행마다 재평가되지만 후자는 InitPlan 으로 한 번만 평가된다
--      (Supabase performance advisor 의 auth_rls_initplan 권고).
-- =============================================================================

alter table public.profiles                 enable row level security;
alter table public.runs                     enable row level security;
alter table public.badges                   enable row level security;
alter table public.user_badges              enable row level security;
alter table public.challenges               enable row level security;
alter table public.challenge_participations enable row level security;
alter table public.leaderboard_entries      enable row level security;

-- -----------------------------------------------------------------------------
-- profiles : 공개 프로필. 읽기는 전체, 쓰기는 본인만(서버 전용 컬럼은 05 가드가 차단)
-- -----------------------------------------------------------------------------
create policy profiles_select_all
  on public.profiles for select
  to authenticated
  using (true);

create policy profiles_insert_self
  on public.profiles for insert
  to authenticated
  with check (id = (select auth.uid()));

create policy profiles_update_self
  on public.profiles for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- DELETE 정책 없음: 프로필 삭제는 auth.users 삭제(cascade)로만 일어난다.

-- -----------------------------------------------------------------------------
-- runs : 본인 기록만 CRUD
-- -----------------------------------------------------------------------------
-- 오프라인 upsert 주의:
--   RunRecord.id 는 클라이언트 생성 UUID 다. 남의 id 를 추측해 upsert 하면
--   UPDATE 경로를 타는데, update USING 이 user_id = auth.uid() 를 요구하므로
--   타인 행은 매칭되지 않고 요청이 실패한다(덮어쓰기 불가). 자기 행에 대해서는
--   같은 id 로 몇 번을 올려도 결과가 동일하다 = 멱등.
create policy runs_select_own
  on public.runs for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy runs_insert_own
  on public.runs for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy runs_update_own
  on public.runs for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy runs_delete_own
  on public.runs for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- badges : 마스터 데이터. 전원 읽기, 쓰기는 service_role 만.
-- -----------------------------------------------------------------------------
create policy badges_select_all
  on public.badges for select
  to authenticated
  using (true);

-- -----------------------------------------------------------------------------
-- user_badges : 본인 것만 조회. INSERT/DELETE 정책 없음(= 서버 재검증 경로 전용).
--               UPDATE 는 is_seen 표시용으로만 허용하고, 다른 컬럼 변경은
--               05 의 user_badges_guard 가 되돌린다.
-- -----------------------------------------------------------------------------
create policy user_badges_select_own
  on public.user_badges for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy user_badges_update_seen
  on public.user_badges for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- challenges : 공개 챌린지 + 본인이 속한 크루의 챌린지만 조회
-- -----------------------------------------------------------------------------
create policy challenges_select_visible
  on public.challenges for select
  to authenticated
  using (
    crew_id is null
    or crew_id = (select p.crew_id from public.profiles p where p.id = (select auth.uid()))
  );

-- -----------------------------------------------------------------------------
-- challenge_participations : 본인 참가 기록만. 참가(INSERT)/탈퇴(DELETE)는 허용,
--                            진척도 갱신은 서버 전용(05 가드).
-- -----------------------------------------------------------------------------
create policy challenge_participations_select_own
  on public.challenge_participations for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy challenge_participations_insert_own
  on public.challenge_participations for insert
  to authenticated
  with check (user_id = (select auth.uid()));

create policy challenge_participations_delete_own
  on public.challenge_participations for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- leaderboard_entries : 전원 읽기, 쓰기 정책 없음(refresh_* 함수/service_role 전용)
-- -----------------------------------------------------------------------------
create policy leaderboard_select_all
  on public.leaderboard_entries for select
  to authenticated
  using (true);

-- -----------------------------------------------------------------------------
-- 익명(anon) 롤 차단 — Runnit 은 로그인 사용자 전용이다.
-- 위 정책은 전부 `to authenticated` 이므로 anon 은 어떤 정책에도 매칭되지 않는다.
-- 테이블 GRANT 자체도 회수해 두어 오류를 더 이르게 낸다.
-- -----------------------------------------------------------------------------
revoke all on public.profiles, public.runs, public.badges, public.user_badges,
              public.challenges, public.challenge_participations,
              public.leaderboard_entries
  from anon;
revoke all on public.run_summaries from anon;

-- -----------------------------------------------------------------------------
-- Realtime : 미확인 뱃지 큐(unseenBadgeQueueProvider)를 폴링 없이 구독하기 위해
--            user_badges 도 publication 에 넣는다. RLS 가 켜져 있으므로 구독자는
--            자기 행 변경만 수신한다.
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.user_badges;
  end if;
end;
$$;
