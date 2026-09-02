-- =============================================================================
-- Runnit :: 62. evaluate_badge_condition 앵커 치환 패치 회귀 가드 (R-12)
-- -----------------------------------------------------------------------------
-- 배경
--   `evaluate_badge_condition` 은 24KB 짜리 디스패처다. 마이그레이션 57·61 이
--   이 함수를 **전문 재작성 없이 문자열 앵커 치환**으로 패치했다:
--     · 57-5 : `season_weekly_rank_lte` 분기에 `and le.finalized_at is not null`
--              → 확정 안 된(진행 중인) 주의 일시적 1위로 영구 뱃지가 나가던 경로 차단
--     · 61-3 : 판정 시 `current_setting('runnit.badge_season')` GUC 를 읽음
--              → 시즌 말 걸친 주 RK-06 미지급 + 미획득 과거 시즌 인스턴스가
--                현재 시즌 데이터로 재판정되던 잠재 결함 차단
--
--   위험(R-12): 앞으로 누군가 이 함수를 **전문(create or replace, 본문 통째)** 으로
--   재정의하면서 이 두 조각을 다시 넣지 않으면, 에러 없이 조용히 사라지고 두 버그가
--   부활한다. 현재 시드 규모(티어당 1~5명)에서는 자동 테스트도 못 잡는다.
--
--   근본 해법은 이 함수를 앵커 치환하지 말고 전문 관리하거나 분기를 작은 함수로
--   분해하는 것이다(다음에 실질적으로 손댈 때 함께). 그때까지의 안전망으로,
--   **이 가드 블록을 이후 마이그레이션에서도 유지**한다 — 전문 재정의가 두 조각을
--   빠뜨리면 그 마이그레이션이 즉시 실패한다.
--
--   ⚠️ 이 함수를 의도적으로 재설계해 두 메커니즘을 다른 방식으로 대체한다면,
--      같은 커밋에서 이 가드도 함께 갱신/제거하라(QA `_workspace/20260901_qa_short-week-optionb.md` §3 P-15).
-- =============================================================================

do $$
declare
  v_src text;
begin
  select pg_get_functiondef(oid)
    into v_src
    from pg_proc
   where proname = 'evaluate_badge_condition'
     and pronamespace = 'public'::regnamespace;

  if v_src is null then
    raise exception 'evaluate_badge_condition 함수를 찾을 수 없다 — 마이그레이션 27/32/41/57/61 전제가 깨졌다';
  end if;

  if position('and le.finalized_at is not null' in v_src) = 0 then
    raise exception 'evaluate_badge_condition: 마이그레이션 57 의 finalized_at 필터가 사라졌다 — 진행 중인 주의 일시적 1위로 영구 뱃지가 나간다 (TRD #23)';
  end if;

  if position('runnit.badge_season' in v_src) = 0 then
    raise exception 'evaluate_badge_condition: 마이그레이션 61 의 badge_season GUC 가 사라졌다 — 시즌 말 걸친 주 RK-06 미지급 + 과거 시즌 인스턴스 오판정이 되살아난다 (TRD #30, QA C-2)';
  end if;
end $$;
