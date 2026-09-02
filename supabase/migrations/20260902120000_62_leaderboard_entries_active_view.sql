-- 62 · leaderboard_entries_active 뷰 — 클라이언트에는 "현재 활성 기간" 행만 노출한다
--
-- 배경:
--   `leaderboard_entries` 는 지난 기간(지난 주차 등) 행을 삭제하지 않고 누적 보존한다
--   (ARCHITECTURE §5.3, `refresh_leaderboard` 꼬리 DELETE 는 `period_start = v_start`
--   로 현재 기간 안의 stale 행만 지운다). 그런데 클라이언트
--   `supabase_ranking_repository.dart` 의 `_scoped()` 는 `period_start` 를 필터하지
--   않아, (period, metric, scope, tier) 조합에 주차가 2개 이상 쌓이면 여러 기간 행이
--   섞여 내려간다 → 주간 보드에서 rank=1 이 중복 반환된다.
--   마이그레이션 61 의 시즌 말 단축 주간은 같은 달력 주를 `period_start` 가 다른 두
--   조각(`2026-W40@2026-Q3` / `@2026-Q4`)으로 나누므로, 분기마다 이 형태가 확정적으로
--   발생한다.
--
-- 결정 (QA `_workspace/20260901_qa_short-week-optionb.md` C-1):
--   클라이언트가 KST·시즌 클램프 규칙을 Dart 로 재구현하면 서버
--   `leaderboard_period_bounds` 와 어긋날 위험이 크다. 따라서 서버가 "현재 활성
--   기간"을 정해 주는 뷰를 두고, 클라이언트는 이 뷰만 읽는다.
--
--   - weekly/daily/monthly/all_time 모두 `leaderboard_period_bounds` 가 처리하며,
--     weekly 는 시즌 클램프(61)까지 이 함수가 반영한다.
--   - `finalized_at` 은 필터에 넣지 않는다 — 진행 중인 주도 리더보드 화면에 보여야
--     하고, 확정 도장은 뱃지 판정용이지 조회 필터가 아니다(57).
--   - `security_invoker = true` — 뷰 자체에는 RLS 가 없으므로, 베이스 테이블
--     `leaderboard_entries` 의 RLS(로그인=전 스코프, anon=global 만; 마이그레이션 17)
--     가 그대로 적용되게 한다.
--   - Realtime 은 뷰를 publication 대상으로 삼지 않는다 — 클라이언트의
--     `watchLeaderboard` 는 베이스 테이블을 계속 구독하고 재조회만 뷰로 한다.

-- `leaderboard_period_bounds` 는 SECURITY INVOKER 순수 계산 함수라, 뷰가
-- security_invoker 로 실행되면 호출자(anon/authenticated) 권한으로 시즌 계산 함수들을
-- 부른다. 지금까지 이 함수는 SECURITY DEFINER 배치(refresh_leaderboard 등)에서만
-- 불려 grant 가 없어도 됐다. 뷰 경로를 위해 시즌 계산 체인에 실행 권한을 준다 —
-- 전부 IMMUTABLE·테이블 접근 0 인 순수 함수라 정보 노출이 없다(week_id_at·
-- leaderboard_period_bounds 가 이미 anon/authenticated 실행 가능한 것과 같은 근거).
grant execute on function
  public.season_start(text),
  public.season_end(text),
  public.season_next_id(text),
  public.season_id_at(timestamptz)
to anon, authenticated;

create or replace view public.leaderboard_entries_active
with (security_invoker = true) as
select le.*
from public.leaderboard_entries le
where le.period_start = (
  select b.period_start
  from public.leaderboard_period_bounds(le.period, now()) b
);

comment on view public.leaderboard_entries_active is
  'leaderboard_entries 중 leaderboard_period_bounds(period, now()) 가 정한 현재 활성 '
  '기간 행만. 클라이언트 랭킹 조회의 유일한 소스 — 누적 보존된 지난 기간 행과 시즌 말 '
  '단축 주간의 반대편 조각(61)을 서버가 걸러낸다. security_invoker=true 로 베이스 '
  '테이블 RLS 를 승계한다. Realtime 구독은 여전히 베이스 테이블로 한다.';

grant select on public.leaderboard_entries_active to anon, authenticated;
