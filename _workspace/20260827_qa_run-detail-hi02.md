# QA 경계면 검증 — HI-02 기록 상세 화면

검증: qa-integration-tester / 2026-08-27
대상: `_workspace/20260827_ui_run-detail-hi02.md` 산출물 (신규 8 파일 + 수정 3 파일)
기준: `docs/PRD.md` §5.2 HI-02 · §5.1 TR-07, `docs/ARCHITECTURE.md` v0.3 §7.2,
`docs/TRD.md` v0.10 §3.1/§3.2/§10.2, 마이그레이션 41

**요약: PASS 9 / FAIL 0 / 이슈 6 (CONFIRMED 3, PLAUSIBLE 3) / UNVERIFIED 2**
차단(blocking) 결함 없음. `flutter analyze` 0건, `flutter test` 170/170 통과.

---

## 1. 모델 ↔ provider ↔ 위젯 경계 — **PASS**

| 확인 항목 | 결과 |
|---|---|
| `runDetailProvider`가 타는 리포지토리 | `repository_providers.dart:26` → `buildLocalRunRepository` (`tracking_providers.dart:180`). **로컬(drift) 우선 + 원격 폴백**. 상세 화면 요구(samples 필요)와 맞다 |
| `findById(includeSamples: true)`가 samples를 실제로 채우는가 | **채운다.** 로컬 경로 `local_run_repository.dart:222` → `runRecordFromRow(row, includeSamples: true)` (`local_run_database.dart:97-99`가 `samplesJson`을 디코드). 원격 경로 `:230` → `_fromRemote(includeSamples: true)`는 `json['samples']`를 그대로 두고 문자열 방어까지 한다 |
| 목록과의 계약 분리 | `listByUser`/`watchByUser`는 `includeSamples` 없이 호출(`:258`, `:276`) — 주석 "계약: 목록의 samples는 항상 비어 있다"와 코드 일치. 상세만 샘플을 끌어오는 설계가 실제로 지켜진다 |
| `RunSample` ↔ `runs.samples` jsonb 키 | `run_sample.dart:22` `@JsonSerializable(fieldRename: FieldRename.snake)` → `cumulative_distance_meters` / `timestamp`. 서버 `_run_time_at_distance`가 읽는 `elem ->> 'cumulative_distance_meters'`, `elem ->> 'timestamp'`와 **정확히 일치** |
| `autoDispose` 판단 | 타당. 3,600 샘플/시간을 물고 있어 캐시 유지는 메모리 단조 증가. `runLapSplitsProvider`/`runRoutePointsProvider`도 같은 스코프라 누수 없음 |

---

## 2. 랩 판정 ↔ 서버 규칙 (`lap_splits.dart` ↔ 마이그레이션 41) — **PASS**

`_DistanceBasis.secondsAt()` (`lap_splits.dart:226-240`)를 `_run_time_at_distance`
SQL과 분기별로 1:1 대조했다.

| 분기 | 서버 SQL | 클라이언트 | 판정 |
|---|---|---|---|
| 목표 거리 0 이하 | `when p_meters <= 0 then min(t) from pts` | `if (targetMeters <= 0) return 0;` (= `_startTime` = 첫 샘플 시각) | **일치** |
| 도달 샘플 탐색 | `where d >= p_meters order by d,t limit 1` | `if (_cumulative[i] < targetMeters) continue;` (첫 `>=`) | **일치** |
| 첫 샘플이 히트(lag null) | `when pd is null then t` | `if (i == 0) return tEnd/1000;` | **일치** |
| segSpan 0 (일시정지) | `when (d - pd) <= 0 then t` | `if (segSpan <= 0) return tEnd/1000;` | **일치** |
| 미도달 | `when not exists(hit) then null` | 루프 끝 `return null` → 호출부 `break` (`:107`) | **일치** |
| 보간식 | `pt + (t-pt) * ((D-pd)/(d-pd))` | `tStart + (tEnd-tStart) * ratio` | **일치** |

부수 확인:
- `fullLapCount = floor(total/1000)`은 서버 `generate_series(1, floor(m/1000))`와 동일 범위.
  따라서 `:107`의 `break`(미도달)는 사실상 도달 불가 분기다 — 무해한 방어 코드.
- 서버는 `where t_end > t_start`로 0초 랩을 걸러내지만 클라이언트는 방출한다.
  1km를 1초 미만에 통과한 경우에만 갈리며, 그때도 `paceSecPerKm = 0` →
  `RunFormat.pace` 가드가 표시를 막고 `PaceChart`는 `paceSecPerKm > 0`으로 제외한다.
  **사용자에게 보이는 차이 없음.**
- 경계 시각을 먼저 초 반올림한 뒤 차분하는 선택(`:108`, `:116`)은 서버와 랩당 최대
  1초 어긋나지만, **표에 찍히는 시간과 그 시간에서 유도한 페이스가 항상 일치**한다는
  더 중요한 성질을 산다. 표시용 값이므로 타당한 트레이드오프다.

### "의도적으로 다른 2지점" 판단 — **둘 다 타당**

1. **자투리 방출 (`isPartial`)** — 타당. 서버가 자투리를 버리는 이유는
   `pace_variance_lte`의 CV 왜곡 방지이지 "자투리가 존재하지 않아서"가 아니다
   (마이그레이션 41-0-b 주석). 소비 측이 자투리를 통계에서 제외하는지 확인했다:
   `LapTable._fastestFullLapIndex`(`lap_table.dart:87`)가 `isPartial` skip,
   `PaceChart`(`pace_chart.dart:51`, `:45`)가 스케일·`canRender` 양쪽에서 제외.
   **계약이 실제로 지켜진다.**
2. **Haversine 폴백** — 타당하며, 실질 위험도는 UI 담당이 우려한 것보다 **더 낮다**.
   `RunSample`을 만드는 곳은 앱 전체에 `run_session_aggregator.dart:172` 한 곳뿐이고,
   그 자리는 `cumulativeDistanceMeters`(non-nullable `double`)를 **항상** 채운다
   (`gps_smoothing.dart:93`). 즉 폴백 경로는 현재 코드가 만들어내는 어떤 기록에서도
   실행되지 않는 순수 방어 코드다. 상세 내용은 §3-(a).

---

## 3. UI 담당이 넘긴 2건

### (a) 서버 뱃지 판정 근거와의 페이스 불일치 — **문제 없음 (CONFIRMED)**

ARCHITECTURE §7.2 전제("게이미피케이션 판정은 순수 함수 + 서버 재검증이 정본")는
유지된다. 근거 세 가지:

1. **화면 값은 어떤 판정에도 쓰이지 않는다.** `computeLapSplits`의 소비처는
   `LapTable`·`PaceChart` 둘뿐이고(grep 확인), `gamification/domain/`이 이 함수를
   부르지 않는다. §7.4가 못박은 "판정은 전부 서버, 큐에 뜬 시점에 `verified = true`"
   구조가 깨지지 않는다.
2. **폴백 경로에서의 불일치는 "소수점 차이"가 아니라 "서버는 아예 판정하지 않음"이다.**
   `_run_km_split_seconds`는 `cumulative_distance_meters is not null`인 샘플만 집계하므로,
   그 값이 없는 기록에서 서버가 내는 스플릿은 **0개**다. 스플릿 기반 뱃지
   (`pace_variance_lte`·`negative_split`·`final_km_faster_pct`)는 전부 false로 귀결된다.
   따라서 "화면은 5'00\"인데 뱃지는 4'59\" 기준으로 줬다" 같은 모순이 사용자에게
   보일 수 없다.
3. **폴백은 현재 도달 불가.** §2 참고. 워치 임포트 경로가 생겨 `cumulativeDistanceMeters`
   없는 샘플을 만들게 되면 그때 다시 봐야 한다 — 그 시점에는 **업로드 전에 클라이언트가
   누적거리를 채워 서버 입력과 원천을 통일**하는 편이 낫다(폴백 유지보다).

`runs.samples jsonb` 스키마 대조(마이그레이션 01 `:95`, `:119`
`jsonb_typeof(samples) = 'array'`) 결과 키 이름·타입 모두 `RunSample`과 일치.
`docs/TRD.md:969`의 `lat/lng/ts` 예시는 `:961`이 "초기 요청/응답 shape 설계로만 보존"
이라 명시한 폐기 블록이므로 불일치가 아니다.

### (b) 트래킹 `RunMapView` OSM 출처 표기 없음 — **CONFIRMED · 별도 이슈로 남길 것**

`lib/features/tracking/presentation/widgets/run_map_view.dart:73`이
`https://tile.openstreetmap.org/{z}/{x}/{y}.png`를 쓰면서 출처 표기 위젯이 없다.
앱 전체에서 OSM 타일을 쓰는 곳은 이 파일과 신규 `run_route_map.dart:65` 둘뿐이고,
후자에만 `_OsmAttribution`(`:89`, `:110`)이 붙었다.

**"별도 이슈"가 맞다 — 단, 드롭하지 말 것.** OSM 타일 이용 정책상 출처 표기는 선택이
아니고, 트래킹 화면은 사용자가 가장 오래 보는 지도다. HI-02 범위 밖이므로 이번
변경에 섞지 않은 판단은 옳지만, `run_route_map.dart:110`의 `_OsmAttribution`을
공용 위젯으로 올려 두 화면이 함께 쓰게 하는 후속 작업을 권한다.
→ 담당: flutter-ui-designer (또는 gps-tracking-engineer)

---

## 4. 라우팅 — **PASS**

| 확인 | 결과 |
|---|---|
| `Routes.runDetail = 'run/:runId'` 서브라우트 | `app_router.dart:114-117`, `/history` 하위 → 전체 경로 `/history/run/:runId`. 플레이스홀더 제거되고 `RunDetailPage`로 교체됨 |
| 딥링크 진입 시 뒤로가기 | 동작한다. go_router가 매칭된 라우트 스택 전체(HistoryPage → RunDetailPage)를 세우므로 `HistoryHeader`의 `Navigator.maybePop()`(`history_header.dart:35`)이 활동 탭으로 되돌린다. `maybePop`이라 팝할 대상이 없어도 예외가 아니다 |
| 앱 내 네비게이션 병존 | 타일 `onTap`은 `Navigator.of(context).push`(`history_page.dart:357`, `run_history_list_page.dart:42`). **앱 전역의 기존 패턴과 일치**한다 — `home_page.dart:479`, `profile_page.dart:61`도 같은 방식. URL은 갱신되지 않지만 셸 브랜치 navigator 위에 쌓여 바텀 네비가 유지된다 |
| 삭제된 기록 딥링크 | 로컬 미스 → 원격 `maybeSingle()` null → `findById` null 반환 → `run_detail_page.dart:64-67` "기록을 찾을 수 없어요" **재시도 버튼 없음**. 의도대로 |
| 오프라인 딥링크 | `guardSupabase`(`supabase_error.dart:39`)가 예외를 `Failure`로 매핑 → error 상태 → "불러오지 못했어요" + 재시도. 적절 |

⚠️ 다만 **go_router 경로에 in-app 호출자가 없어** 딥링크 라우트가 조용히 썩을 수 있다.
푸시 알림(Phase 2 NT-01~08)이 이 경로로 들어올 예정이므로, 위젯 테스트 한 건
(`GoRouter` + `/history/run/:id` 초기 location → `RunDetailPage` 렌더) 추가를 권한다.

---

## 5. `flutter analyze` / `flutter test` — **PASS**

```
flutter analyze  → No issues found! (3.1s)
flutter test     → All tests passed! (170/170)
```

신규 테스트 커버리지 확인: `lap_splits_test.dart` 22건(완전/자투리/보간/거리원천/
제외조건/부가지표 6그룹), `run_detail_page_test.dart` 9건(로딩·에러·null·경로 있음·
실내·짧은 기록·flagged true/null·메모). **상태 처리 표(설계 노트 §4)의 모든 행이
테스트로 뒷받침된다.**

---

## 6. 발견 이슈 (심각도순)

### I-1 · CONFIRMED · **Medium** — 트래킹 지도에 OSM 출처 표기 없음
- 위치: `lib/features/tracking/presentation/widgets/run_map_view.dart:73`
- 내용: §3-(b). OSM 타일 정책 위반 상태.
- 조치: 별도 이슈. `run_route_map.dart:110`의 `_OsmAttribution`을 공용 위젯으로 승격 후 양쪽 적용.
- 담당: flutter-ui-designer

### I-2 · PLAUSIBLE · **Medium** — 원격 폴백이 빈 samples를 로컬에 영구 캐시할 수 있다
- 위치: `lib/features/tracking/data/local_run_repository.dart:225-236`
- 내용: `findById(id, includeSamples: false)`가 로컬 미스 → 원격 히트일 때
  `_fromRemote`가 `json['samples'] = []`로 만든 레코드를 `_writeLocal`로 **로컬에 캐시**한다
  (`:299-308`, `:233`). 이후 같은 id를 `includeSamples: true`로 부르면 로컬 행이 히트해
  `:222`가 **빈 samples를 반환** — 다른 기기에서 뛴 기록의 상세 화면이 경로·랩 없이
  영구적으로 뜬다. 재조회로도 복구되지 않는다.
- **현재는 도달 불가:** `lib/` 내 `findById` 호출자는 `share_providers.dart:147`과
  `run_detail_providers.dart:17` 둘뿐이고 **둘 다 `true`**다. 잠재 함정.
- 조치 제안(HI-02 범위 밖, 트래킹 모듈 소유): ① `includeSamples: false`일 때는 캐시를
  쓰지 않거나, ② 원격 조회를 항상 samples 포함으로 하고 반환 시점에만 비우거나,
  ③ 로컬 행에 "샘플 미보유" 플래그를 두고 상세 조회 시 원격을 다시 본다.
- 담당: gps-tracking-engineer + backend-engineer

### I-3 · CONFIRMED · **Low** — `docs/ARCHITECTURE.md`가 HI-02를 미구현으로 기술
- 위치: `docs/ARCHITECTURE.md:517`
  → "1. 기록 상세 화면(HI-02, 현재 `RunDetailPlaceholder`) — 경로 지도·랩 테이블·페이스 그래프"
- 내용: 남은 작업 목록에 그대로 남아 있으나 이번 변경으로 구현 완료.
  CLAUDE.md 규칙 3(문서를 코드와 어긋나지 않게 갱신) 대상.
- 조치: 해당 항목 제거 또는 "해소" 표기. §12 Open Item 2(지도 SDK)는 그대로 유지
  — `RunRouteMap`도 `flutter_map`을 쓰므로 PRD §7(`flutter_naver_map`)과의 불일치가
  이번에 **한 화면 더 늘었다**. 사용자 결정 대기 상태 유지가 맞다.

### I-4 · CONFIRMED · **Low** — `RunHistoryTile` 문서 주석이 낡았다
- 위치: `lib/features/history/presentation/widgets/run_tile.dart:12-14`
  → "상세 화면이 아직 없어 [onTap]은 지금은 항상 null(비활성)"
- 내용: 이번 변경으로 두 호출부 모두 `onTap`을 넘긴다. 주석이 사실과 반대.

### I-5 · PLAUSIBLE · **Low** — 랩 시간(경과 기준)과 요약 평균 페이스(이동 기준)의 기준 불일치
- 위치: `lap_splits.dart:184-185` vs `run_detail_page.dart:202` (`RunFormat.paceOf` →
  `tracking_format.dart:48-55`, `avgPaceSecPerKm` 또는 `movingSeconds` 기반)
- 내용: 랩 시간은 샘플 타임스탬프 차이(= **경과** 시간, 일시정지 포함)이고 요약의
  "평균 페이스"는 **이동** 시간 기반이다. 일시정지가 긴 러닝에서 Σ 랩 시간 ≠ 이동 시간이고,
  최속 랩 페이스가 평균 페이스보다 느리게 나올 수도 있다. 사용자가 버그로 읽을 여지.
- **서버와는 일치한다** — `_run_km_split_seconds`도 타임스탬프 차이를 쓰므로 뱃지 판정과의
  괴리는 없다. 순수 화면 내 정합성 문제.
- 조치 제안: 수정보다 표기가 낫다. 랩 테이블 하단에 "구간 시간은 일시정지를 포함한
  경과 시간" 한 줄, 또는 일시정지가 있는 기록에서만 노출. 우선순위 낮음.

### I-6 · PLAUSIBLE · **Low** — 샘플 정규화 방식이 서버와 다르다(정렬 vs 폐기)
- 위치: `lap_splits.dart:270-279` `_timeOrdered`
- 내용: 클라이언트는 시각이 증가하지 않는 샘플을 **버린다**. 서버는 `order by d, t`로
  **정렬**해 전부 쓴다. 타임스탬프가 중복·역행하는 임포트 데이터에서 클라이언트의
  보간 구간이 서버보다 길어져 값이 갈릴 수 있다.
- 현재 샘플 생산자(`run_session_aggregator.dart:172`)는 단조 증가를 보장하므로 미도달.
  §3-(a)와 같은 이유로 워치 임포트가 생기면 재검토 대상.

---

## 7. UNVERIFIED (검증 못 한 것 — 추정으로 수정 요청하지 않음)

1. **딥링크 실제 해석.** `/history/run/:id`가 실기기/시뮬레이터에서 실제로 열리는지는
   테스트도 실행도 하지 않았다. 코드 구조상 동작해야 한다는 판단까지만. → §4의 테스트 추가 권고.
2. **서버 스플릿과의 수치 대조.** 마이그레이션 41 SQL을 **읽어서** 분기별로 대조했을 뿐,
   같은 샘플 배열을 실제 Postgres와 Dart에 각각 넣어 값을 비교하지는 않았다.
   결정적 검증이 필요하면 `_run_km_split_seconds` 골든 케이스를 backend-engineer와
   공유 픽스처로 맞추는 것을 권한다.

---

## 8. 판정

**HI-02는 병합 가능하다.** PRD §5.2가 요구한 3요소(경로 지도·랩·페이스 그래프)가
모두 구현·테스트됐고, 랩 계산은 서버 정본(마이그레이션 41)과 분기 단위로 일치하며,
의도적으로 다른 2지점은 모두 근거가 타당하고 소비 측에서 계약이 지켜지는 것을 확인했다.
ARCHITECTURE §7.2("판정은 서버, 화면 값은 표시용")를 깨는 지점 없음.

발견 이슈 중 이번 변경이 **만든** 것은 I-4(주석) 하나뿐이다. I-1·I-2·I-5·I-6은
기존 코드 또는 후속 모듈의 문제이며 HI-02를 막지 않는다. I-3은 문서 갱신 대상이다.
