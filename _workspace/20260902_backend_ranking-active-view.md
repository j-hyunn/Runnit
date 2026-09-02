# 주간 보드 rank 중복 수정 — `leaderboard_entries_active` 뷰 (마이그레이션 62)

| 항목 | 내용 |
|------|------|
| 작업일 | 2026-09-02 |
| 담당 | running-app-builder (backend 직접) |
| 대상 결함 | `_workspace/20260901_qa_short-week-optionb.md` C-1 |
| 원격 | `xwtbwexcofcgmbvktwdo` — 마이그레이션 `62_leaderboard_entries_active_view`, `62b_grant_season_calc_functions_for_active_view` 적용 완료 |
| 사용자 승인 | 뷰 방식 + main 선머지 |

## 문제

`leaderboard_entries`는 지난 기간 행을 삭제 없이 **누적 보존**한다(ARCHITECTURE §5.3, `refresh_leaderboard` 꼬리 DELETE는 `period_start = v_start`로 현재 기간 stale 행만 삭제). 클라이언트 `supabase_ranking_repository.dart`의 `_scoped()`는 `(period, metric, scope, tier)`만 필터하고 `period_start`를 안 걸어, 주차가 2개 이상 쌓이면 여러 기간 행이 섞여 내려온다 → **rank=1 중복**.

- 라이브 재현: `(weekly, distance, global, bronze)` 조회 시 `period_start` 2026-08-16(4행)·2026-08-23(1행) 혼재, rank=1 두 행.
- 마이그레이션 61 시즌 말 단축 주간이 같은 달력 주를 `period_start` 다른 두 조각(`2026-W40@2026-Q3`/`@2026-Q4`)으로 나눠, 분기마다 이 형태가 확정적으로 발생.
- `_scoped()`의 전제 주석("배치가 이전 기간 행을 정리")은 **거짓**이었다.
- `fetchMyEntry`의 `.maybeSingle()`은 한 사용자가 두 주에 행을 가지면 예외(현 시드엔 해당자 0명).

## 수정

### 마이그레이션 62 — 뷰

```sql
create or replace view public.leaderboard_entries_active
with (security_invoker = true) as
select le.*
from public.leaderboard_entries le
where le.period_start = (
  select b.period_start from public.leaderboard_period_bounds(le.period, now()) b
);
grant select on public.leaderboard_entries_active to anon, authenticated;
```

- KST·시즌 클램프 규칙을 **서버 한 곳**(`leaderboard_period_bounds`)에만 두고 클라이언트가 복제하지 않게 한다. weekly는 이 함수가 시즌 클램프(61)까지 반영.
- `security_invoker = true` → 베이스 테이블 RLS(마이그레이션 17: `authenticated` 전 스코프, `anon` `scope='global'`만) 승계. 라이브에서 `set role anon` 후 `distinct scope` = `global` 확인.
- `finalized_at`은 필터에 안 넣는다 — 진행 중인 주도 화면에 보여야 하고 확정 도장은 뱃지 판정용(57).

### 마이그레이션 62b — grant

`leaderboard_period_bounds`(SECURITY INVOKER)가 뷰의 invoker 권한으로 `season_start`/`season_end`/`season_id_at`/`season_next_id`를 호출한다. 이 함수들은 지금껏 SECURITY DEFINER 배치에서만 불려 grant가 없었고, 뷰 경로에서 `permission denied for function season_start`가 났다. 전부 IMMUTABLE·테이블 접근 0 인 순수 함수라 `anon, authenticated`에 execute 부여(`week_id_at`·`leaderboard_period_bounds`가 이미 실행 가능한 것과 같은 근거).

### Dart — `lib/features/ranking/data/supabase_ranking_repository.dart`

- `_viewTable = 'leaderboard_entries_active'`(조회), `_baseTable = 'leaderboard_entries'`(Realtime 구독).
- `_scoped()`가 `_viewTable`을 읽는다. `fetchLeaderboard`·`fetchMyEntry`가 이를 사용.
- `watchLeaderboard`의 `watchTableAndRefetch(table: _baseTable)` — 뷰는 `supabase_realtime` publication에 없으므로 구독은 베이스 테이블, 재조회 콜백만 뷰 기반.
- `_scoped()`의 틀린 전제 주석 정정, `fetchMyEntry`의 `.maybeSingle()` 안전성 근거 주석 추가.

## 검증

| 확인 | 결과 |
|------|------|
| `(weekly,distance,global,bronze)` 뷰 조회 (앵커 2026-08-25 기준 predicate) | rank=1 **1행만** (2026-08-23 주), 2026-08-16 주 제외 ✓ |
| `all_time` 보드 | base 27 = view 27 (전부 현재 기간) ✓ |
| `monthly`(7월 시드) | 현재 9월 → 뷰에서 정확히 제외 ✓ |
| anon RLS 승계 | 뷰에서 `scope='global'`만 노출 ✓ |
| `flutter analyze` | No issues found |
| `flutter test` | 279 passed |
| build_runner | 모델 변경 없음 (머지 후 stale 산출물 재생성만) |

## 남는 사항 (코드 결함 아님)

라이브 시드 `runs`가 전부 8월치라 `refresh_all_leaderboards()`를 돌려도 `daily/weekly/monthly` 현재 기간 행이 0이다 → 랭킹 화면이 빈 보드로 보인다. 프로덕션에선 5분 배치가 최근 러닝 기준 현재 기간을 채우므로 정상. 라이브 데모용으로 화면에 데이터를 채우려면 최근 날짜의 `runs` 시드가 필요하다.
