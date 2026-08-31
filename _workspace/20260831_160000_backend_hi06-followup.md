# HI-06 QA 후속 조치 (2026-08-31, 오케스트레이터 직접 처리)

앞선 backend-engineer(sonnet) 에이전트가 이 작업을 했다고 **보고했으나 실제 파일이 워크트리에
반영되지 않았다**(마이그레이션 52 부재, 문서 미수정). 최종 QA(`20260831_234500_qa_hi-final.md`)가
B-2·B-3을 다시 CONFIRMED로 올려 확인. 오케스트레이터가 직접 재작업.

## B-3 (CONFIRMED) — season_histories RLS 문서 드리프트

- **증상**: `docs/TRD.md` §5, `docs/ARCHITECTURE.md` §5.5 표가 `season_histories`를
  "본인 행만 select"로 서술. `tier_change_history`와 한 셀에 묶여 있었음.
- **실제 정책**: 마이그레이션 21 `season_histories_select_visible` —
  `using (is_voided = false or user_id = (select auth.uid()))`, `anon` 은 `revoke all`.
  즉 무효 처리되지 않은 타인 행은 `authenticated` 에게 공개(TI-09 프로필 표시 전제).
- **조치**: 두 문서에서 `season_histories` 행을 분리하고 실제 공개 범위로 정정.
  AC-03(타인 프로필 역대 시즌)이 이 범위를 그대로 재사용한다는 점 명시. 코드 변경 없음.

## B-2 (CONFIRMED) — best_weekly_rank 티어 스코프 누락

- **증상**: 마이그레이션 43 `recompute_season_tier` 의 시즌 마감 insert에서
  `best_weekly_rank := (select min(le.rank) from leaderboard_entries le where ... )` 에
  `tier` 축 필터가 없음. 마이그레이션 23 이후 `leaderboard_entries` 에 통합 보드
  (`tier IS NULL`)와 티어별 보드가 공존 → 두 스코프 rank가 한 `min()` 에 혼입.
  현재는 티어 보드가 통합 보드의 부분집합이라 값이 우연히 맞지만, 마감 후 수정 불가 컬럼.
- **조치**: **마이그레이션 52** (`20260831130000_52_season_history_rank_tier_scope.sql`).
  43 함수 전문을 그대로 복사하고 서브쿼리에 `and le.tier is not null` 한 줄만 추가.
  `create or replace` + `revoke` 재적용 → 멱등.
- **43 대조**: 선언부·1~4단계·`greatest` 강등 방지·`tier_change_history` 조건·`revoke`
  전부 동일. 서브쿼리 1줄 + `comment on function` 문구만 차이.

## 상태

- 마이그레이션 51·52 모두 **원격 적용 완료** (2026-08-31, `xwtbwexcofcgmbvktwdo`, MCP `apply_migration`).
- 적용 후 검증: over-limit 러닝 0건(51-1 정리 UPDATE no-op) · `runs_delete_own` 정책 제거 확인 · 길이 CHECK 2개 확인 · `compute_run_xp` 시그니처 일치 확인 · 조작 UPDATE(거리 2배) 되돌리기 스모크 테스트 통과 · security advisor 신규 경보 없음.
- 로컬 마이그레이션 파일과 원격 이력 동기화됨 (원격 name: `51_run_edit_title_note_only`, `52_season_history_rank_tier_scope`).
- Dart 무변경. `flutter analyze`/`flutter test` 영향 없음.

## 남은 PLAUSIBLE (미조치, 낮은 우선순위)

- **분기 전환 직후 5분 창**: `mySeasonHistoriesProvider` 는 순수 select라
  `sync_my_season()` 을 호출하지 않음. 00:00~00:05 KST에 홈을 거치지 않고
  마이→역대 시즌 직행 시 직전 시즌 행이 아직 없어 빈 상태가 잠깐 보일 수 있음.
  cron(`reset_stale_seasons`)이 00:05에 돌면 해소. 첫 실사용은 2026-10-01.
- **GPX A-6 (iPad 공유 팝오버 앵커)**: `run_detail_page.exportRunAsGpx` 가
  `context.findRenderObject()` 로 화면 전체 RenderBox를 앵커로 씀(⋮ 버튼 아님).
  크래시 아님, iPad 팝오버 위치만 화면 중앙 근처로 어긋남. HI-09 메모 서술과 코드 불일치.
- **GPX A-7**: `routePolyline` 에만 좌표가 있고 `samples` 가 빈 기록은 상세 지도는
  뜨지만 GPX 메뉴는 안 뜸(`hasExportableRoute` 는 samples만 검사). polyline엔
  per-point 시각이 없어 설계상 정당하나 미문서화.
