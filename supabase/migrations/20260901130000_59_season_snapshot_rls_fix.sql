-- =============================================================================
-- Runnit :: 59. 시즌 스냅샷 RLS 반전 수정 (QA C-1, blocking)
-- -----------------------------------------------------------------------------
-- 배경 (`_workspace/20260901_qa_weekly-finalize-season-snapshot.md` §1 C-1)
--   마이그레이션 58 의 `season_snapshots_select_visible` 는 무효 시즌(`is_voided`)
--   스냅샷을 본인에게만 보이게 하려 했으나 **정확히 반대로 동작한다.**
--
--     or not exists (select 1 from public.season_histories sh where … and sh.is_voided)
--
--   RLS 정책식 안의 서브쿼리는 **참조 테이블의 RLS 를 그대로 받는다**(정책 소유자가
--   아니라 호출자 권한으로 평가된다). `season_histories_select_visible` 가
--   `(is_voided = false) or (user_id = auth.uid())` 이므로 **타인의 무효 시즌 행은
--   이 서브쿼리에게도 보이지 않는다** → `not exists` 가 항상 true → 무효 시즌
--   스냅샷이 전원에게 공개된다.
--
--   라이브 재현(트랜잭션 내 삽입 후 롤백, 타인 계정으로 조회):
--     snapshot_visible_to_other = 1   ← 버그 (보이면 안 되는데 보인다)
--     history_visible_to_other  = 0   ← season_histories 는 정상 차단
--
--   즉 `season_histories` 가 감추는 무효 시즌 결과를 스냅샷이 대신 노출해,
--   부정 판정 사용자의 시즌 순위가 그대로 남는다 — 무효 처리의 의미가 사라진다.
--
-- 왜 58 이 이걸 놓쳤나 — "동일 공개 범위"라는 표현의 함정
--   `season_histories_select_visible` 는 **같은 테이블의 컬럼 검사**(`is_voided`)라
--   서브쿼리가 없고 따라서 이 문제가 없다. 58 은 "같은 공개 범위"를 목표로 삼았지만
--   **정책의 형태가 달랐다** — 한쪽은 컬럼 술어, 다른 쪽은 교차 테이블 서브쿼리다.
--   공개 범위가 같다는 서술이 이 구조 차이를 가렸다.
--
-- 수정: 서브쿼리를 SECURITY DEFINER 헬퍼로 빼내 RLS 밖에서 평가한다.
--   함수 소유자(postgres) 권한으로 실행되므로 `season_histories` 의 RLS 를 통과하고,
--   반환값은 boolean 하나라 무효 여부 외에는 아무것도 새지 않는다.
--   정책 평가에 호출자의 EXECUTE 권한이 필요하므로 `authenticated` 에만 grant 한다.
--
-- ⚠️ 남은 설계 논점 (수정 대상 아님, TRD §14 #31 로 등재)
--   무효 시즌 사용자가 **숨겨지기만 하면 그 티어의 `rank`·`participant_count` 에
--   구멍이 남는다**(3위가 안 보여 1·2·4위로 보인다). 진짜 무효 처리라면 스냅샷
--   재산정 또는 `is_voided` 반영 후 재랭크가 필요하다 — RK-10 UI 라운드에서
--   gamification-designer 와 확정한다.
--
-- 부수 정정 (QA C-3, 코드 아님)
--   57-6 백필 주석의 "현 시드 규모에서는 아무도 이 뱃지를 못 받은 상태"는 **사실이
--   아니었다.** 라이브에 `season_weekly_rank` 뱃지 3건이 이미 있다(user `…00a8`,
--   2026-08-25 부여, 플래티넘 위클리킹/탑텐/라이징 — 모집단 1명 보드에서 나간
--   **마이그레이션 41(모집단 게이트) 이전의 레거시 지급**). 57 이 만든 문제가 아니고
--   백필로 추가 지급도 없었다(멱등 테스트에서 3건 유지 확인). 회수 여부는
--   gamification-designer 판단 사항이라 이 마이그레이션은 데이터를 건드리지 않는다.
--   로컬 57 파일의 주석은 같은 커밋에서 사실에 맞게 고쳤다.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 59-1. 무효 시즌 판별 헬퍼 — RLS 밖에서 평가되는 유일한 목적의 함수
-- -----------------------------------------------------------------------------
create or replace function public._season_history_voided(
  p_user_id   uuid,
  p_season_id text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.season_histories sh
     where sh.user_id   = p_user_id
       and sh.season_id = p_season_id
       and sh.is_voided
  );
$$;

comment on function public._season_history_voided(uuid, text) is
  '해당 사용자·시즌의 `season_histories.is_voided` 여부(마이그레이션 59, QA C-1). '
  '`season_leaderboard_snapshots` 의 SELECT 정책 전용 — RLS 정책식 안의 서브쿼리는 '
  '참조 테이블의 RLS 를 그대로 받으므로, 그대로 두면 `season_histories` 가 이미 '
  '감춘 타인의 무효 행이 서브쿼리에도 안 보여 차단 조건이 반전된다. SECURITY DEFINER '
  '로 그 평가를 RLS 밖으로 뺀다. 반환값이 boolean 하나라 무효 여부 외에는 새지 않는다.';

revoke execute on function public._season_history_voided(uuid, text) from public, anon;
-- 정책 평가는 호출자 권한으로 일어나므로 EXECUTE 가 필요하다.
grant execute on function public._season_history_voided(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- 59-2. 정책 교체
-- -----------------------------------------------------------------------------
drop policy if exists season_snapshots_select_visible
  on public.season_leaderboard_snapshots;

create policy season_snapshots_select_visible
  on public.season_leaderboard_snapshots
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or not public._season_history_voided(user_id, season_id)
  );

comment on table public.season_leaderboard_snapshots is
  '시즌 마감 시점의 티어별 시즌 누적 거리 랭킹 영구 스냅샷(마이그레이션 58, PRD RK-10 / HI-06). '
  '쓰기는 `snapshot_season_leaderboard()` 뿐이고 그 함수는 `recompute_season_tier` 의 '
  '시즌 마감 지점에서만 호출된다 — `season_histories` 와 같은 트랜잭션·같은 멱등 규약. '
  '한 번 적재된 행은 갱신하지 않는다(on conflict do nothing). '
  '⚠️ 공개 범위는 `season_histories` 와 **결과적으로** 같지만 정책 형태가 다르다 — '
  '무효 시즌 판정이 교차 테이블 참조라 SECURITY DEFINER 헬퍼 '
  '`_season_history_voided()` 를 거친다(마이그레이션 59, QA C-1). 이 정책을 고칠 때 '
  '헬퍼를 인라인 서브쿼리로 되돌리면 차단이 조용히 반전된다.';
