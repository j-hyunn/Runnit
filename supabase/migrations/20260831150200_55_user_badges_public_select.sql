-- =============================================================================
-- Runnit :: 55. AC-03 — 타인 프로필의 획득 뱃지 조회 RLS
-- -----------------------------------------------------------------------------
-- 배경(PRD §5.8 AC-03): 랭킹에서 사용자를 탭하면 그 사람의 티어·누적 요약·**획득
--   뱃지**를 본다. 티어/누적 요약은 profiles 가 이미 전체 공개(profiles_select_all,
--   07_rls.sql)라 추가 작업이 없고, 역대 시즌은 season_histories_select_visible
--   (마이그레이션 21)이 이미 타인 행을 연다. 남은 것이 user_badges 였다 —
--   지금까지 정책은 user_badges_select_own 하나뿐이라 타인의 뱃지는 0건이 온다.
--
-- 🛑 스키마 드리프트 정정 (2026-08-31 확인)
--   원격 DB(xwtbwexcofcgmbvktwdo)에는 `user_badges_select_public` 정책이 **이미
--   존재한다.** 그런데 이 이름은 마이그레이션 파일 어디에도 없고, 적용 이력
--   (supabase_migrations.schema_migrations)도 52 에서 끝난다 — 즉 대시보드나 임시
--   execute_sql 로 마이그레이션 밖에서 만들어진 정책이다.
--   결과: **원격에는 있고 파일에는 없는** 상태라, `supabase db reset` 이나 새 환경
--   (스테이징/브랜치 DB)에는 이 정책이 생기지 않아 AC-03 이 그 환경에서만 조용히
--   깨진다. 이 파일이 그 간극을 메운다.
--
--   술어는 원격에 살아 있는 것과 **한 글자도 다르지 않게** 맞췄다
--   (`user_id <> auth.uid() and revoked = false and verified = true`).
--   그래야 원격 적용이 진짜 no-op 이 되고(동작 변화 0), 파일과 라이브가 같은 값으로
--   수렴한다. drop-then-create 로 감싸 몇 번을 돌려도 결과가 같다.
--
--   `user_id <> auth.uid()` 를 붙인 이유(원격 원본의 의도 추정 + 유지 근거):
--   본인 행은 user_badges_select_own 이 이미 통과시키므로, 두 정책의 대상 집합을
--   서로소로 만들어 "본인 행이 두 정책 모두에 매칭"되는 중복 평가를 줄인다.
--   결과 집합은 어느 쪽이든 동일하다(정책은 OR 로 합쳐진다).
--
-- 왜 select_own 을 대체하지 않고 더하는가:
--   본인은 revoked=true 행도 봐야 한다(회수된 뱃지가 갤러리에서 소리 없이 사라지면
--   사용자는 앱이 고장난 줄 안다 — 회수 사실 자체를 보여줘야 한다). 정책은 OR 로
--   합쳐지므로 "본인 전체 + 타인은 유효한 것만" 이 그대로 표현된다.
--
-- 술어에 verified 를 함께 거는 이유:
--   evaluate_badges 는 항상 verified=true 로 발급하므로 현재는 revoked 만으로도
--   결과가 같다. 그럼에도 두 조건을 다 거는 것은, 앞으로 "판정은 됐지만 재검증
--   대기" 상태를 도입하더라도 **미검증 뱃지가 타인에게 새어 나가지 않도록** 기본값을
--   보수적으로 고정해 두기 위함이다.
--
-- 노출되는 개인 상태 컬럼(is_seen / source_run_id) 판단:
--   · is_seen — "이 사용자가 뱃지 획득 팝업을 봤는가". 민감정보가 아니고 타인이
--     알아도 아무 일도 일어나지 않는다.
--   · source_run_id — 뱃지를 만든 러닝의 uuid. runs 는 여전히 본인만 select 가능
--     하므로(runs_select_own, 이번에 손대지 않는다) id 를 알아도 그 러닝의 내용은
--     조회되지 않는다. **AC-03 은 최근 러닝 목록을 노출하지 않는다**는 확정 사항이
--     runs RLS 로 그대로 강제된다.
--   -> 컬럼 제한 뷰(security_invoker view)를 두는 대안은 채택하지 않았다. 얻는 것이
--      없고 클라이언트가 본인/타인 경로마다 다른 소스를 써야 해서 모델이 갈라진다.
--      위 두 컬럼 중 하나라도 민감해지면 그때 뷰로 좁힌다.
--
-- anon 은 그대로 차단이다(마이그레이션 17 — user_badges 는 게스트 공개 대상 아님).
-- =============================================================================

drop policy if exists user_badges_select_public on public.user_badges;

create policy user_badges_select_public
  on public.user_badges for select
  to authenticated
  using (
    user_id <> (select auth.uid())
    and revoked = false
    and verified = true
  );

-- advisor 참고: performance 린트 `multiple_permissive_policies` 가 user_badges /
--   authenticated / SELECT 에 대해 WARN 을 낸다(정책 2개가 매 행마다 평가된다).
--   **원격에 정책이 이미 있어 이 경고도 이미 떠 있다 — 이 파일이 새로 만드는 경고가
--   아니다.** 하나로 합치면(`user_id = auth.uid() or (verified and not revoked)`)
--   경고는 사라지지만, "본인 규칙"과 "공개 규칙"이 한 술어에 뭉쳐 어느 쪽을 고쳐도
--   다른 쪽이 흔들린다. 뱃지 행 수는 사용자당 수십 건 규모라 실측 이득이 없어
--   가독성을 택하고 경고를 수용한다.

comment on policy user_badges_select_public on public.user_badges is
  'AC-03: 타인 프로필의 획득 뱃지 갤러리. 회수(revoked)/미검증 행은 제외. 본인 전체 조회는 user_badges_select_own 이 담당.';

-- -----------------------------------------------------------------------------
-- 조회 인덱스 — 추가 생성 없음
-- -----------------------------------------------------------------------------
-- 타인 프로필 진입 쿼리는 `where user_id = :id order by earned_at desc` 다.
-- 마이그레이션 25 가 이 정책의 술어와 **정확히 같은 조건**의 부분 인덱스를 이미
-- 만들어 뒀다(당시엔 정책 없이 인덱스만 선행 생성된 상태였다):
--     user_badges_public_idx (user_id, earned_at desc) where revoked = false and verified = true
-- 본인 갤러리는 user_badges_user_earned_idx 가 커버한다. 새 인덱스는 필요 없다.

-- -----------------------------------------------------------------------------
-- ⚠️ Realtime 영향 (07_rls.sql 이 user_badges 를 supabase_realtime 에 넣어 뒀다)
-- -----------------------------------------------------------------------------
-- Realtime 은 구독자의 RLS 로 각 변경 이벤트의 가시성을 판정한다. 이 정책이 붙는
-- 순간부터 **타인의 뱃지 발급 이벤트도 구독자에게 도달**한다. 미확인 뱃지 큐
-- (unseenBadgeQueueProvider / core/api/realtime_refetch.dart)가 이벤트마다 refetch
-- 한다면 남이 뱃지를 딸 때마다 불필요한 재조회가 돈다.
--
-- 확인 결과 현재 코드는 안전하다 —
--   supabase_gamification_repository.dart `watchUnseenBadges()` 가 이미
--   `PostgresChangeFilter(eq, 'user_id', userId)` 로 구독을 좁혀 두었다.
-- 다만 이 필터는 지금까지 "RLS 가 어차피 막아 주는데 덤으로" 였던 것이,
-- 이 마이그레이션 이후로는 **유일한 방어선**이 된다. user_badges 를 구독하는
-- 코드를 새로 만들 때 user_id 필터를 빼면 조용히 트래픽이 폭증한다.
-- 서버에서 막을 수 있는 성질이 아니다(정책을 좁히면 AC-03 이 깨진다).
