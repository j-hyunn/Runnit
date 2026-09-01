# A-3 · A-5 · A-6 통합 검증 (커밋 전 게이트)

| 항목 | 내용 |
|---|---|
| 작성 | 2026-09-01, qa-integration-tester |
| 대상 | 미커밋 변경 전체 (수정 21 + 신규 미추적 파일) |
| 입력 | `docs/PRD.md` §5.1·§8.3·§8.4·§10.2, `docs/ARCHITECTURE.md` §6.3~6.5·§9·§9.1, `docs/TRD.md` §7·§8·§9·§14(#25~#28), 세션 노트 4건 |
| 결과 | **PASS 12 / CONFIRMED 6 / PLAUSIBLE 4 / 재현 불가·수동 이관 5** |
| 코드 수정 | **없음** — 명백한 버그 없음. 문서 모순 3건은 PRD 변경이 필요해 사용자 확인 사항(CLAUDE.md 규칙 4) |
| 커밋 | 하지 않았다 |

---

## 0. 최종 테스트 결과 (재실행)

```
flutter analyze  → No issues found! (2.9s)
flutter test     → All tests passed!  (279건)
```

세션 노트가 보고한 수치(analyze clean / 279건)와 일치한다. 회귀 없음.

---

## 1. 항목별 결과

### 1-A. A-5 동기화 경계

| # | 점검 항목 | 결과 | 근거 |
|---|---|---|---|
| A5-1 | `save()` fire-and-forget이 **요약 화면**과 충돌하지 않는가 | ✅ PASS | 요약 화면은 `stop()` 반환 스냅샷이 아니라 `storedRunProvider`(`tracking_ui_providers.dart:35`)를 읽고, 그것은 drift `watch()` 기반 `myRunsProvider`를 구독한다. 업로드가 끝나 `applyServerConfirmation`이 `summaryJson`/`sync_status`를 쓰면 스트림이 자동 재발행되어 게이트가 `pending → confirmed`로 넘어간다. **폴링·재조회 없이 성립** |
| A5-2 | **성취 연출**이 업로드 완료를 기다리는 경로에 묶여 있지 않은가 | ✅ PASS | 축하 큐 소비 지점은 `AchievementCelebrationHost`(`achievement_celebration.dart:76`) 하나이고, 소스는 `pendingAchievementsProvider`(`share_providers.dart:49`) → `watchUnseenBadges` **realtime 구독**이다. `save()`의 반환 시점과 무관. `runCompletedProvider`(`tracking_providers.dart:96`)는 **구독자가 0개**라 `stop()`의 이벤트 발행 시점 변화가 영향을 주지 않는다 |
| A5-3 | **공유 카드 게이트**가 `isFlagged == null`을 대기하지 않는가 | ✅ PASS | `RunShareButton`(`summary_achievements.dart:97`)은 `stored.isFlagged == true`일 때만 숨긴다 — null은 통과. 상세 화면의 `_FlaggedBanner`(`run_detail_page.dart:513`)도 null이면 띄우지 않는다. **null 대기로 막히는 UI는 없다**(`pending` 문구만 표시) |
| A5-4 | 업로드 응답의 `isFlagged`/`awardedXp`가 fire-and-forget 이후에도 로컬 행에 반영되는가 | ✅ PASS | `_schedulePush → _push → _upsertRemote(.select(_confirmationColumns).single()) → applyServerConfirmation`(`local_run_repository.dart:130~237`). 보낼 때 제거하는 집합과 받을 때 채우는 집합이 `_serverOwnedKeys` **한 상수**라 방향 어긋남이 구조적으로 불가능. 컬럼명은 전부 snake_case이고 `summaryJson`도 `toJson()`(snake_case) 그대로라 키 규약 일치(`local_run_database.dart:76·96`). 테스트로 잠김(`offline_sync_test.dart` "업로드 성공 응답의 서버 확정값이 로컬에 반영된다") |
| A5-5 | `syncPending(userId:)`가 게스트/로그아웃에서 정상인가 | ✅ PASS | 코디네이터가 `_trySync()` 진입 즉시 `userId == null`이면 반환(`run_sync_coordinator.dart:66-67`). 로그인 리스너는 `null → non-null` 전이만 발화하므로 로그아웃은 아무것도 트리거하지 않고, 로그아웃 후 2분 타이머가 돌아도 같은 가드에서 막힌다. 테스트 2건이 잠금 |
| A5-6 | `connectivity_plus` provider가 테스트 주입 가능한가 | ✅ PASS | `connectivityRestoredProvider`(`run_sync_coordinator.dart:94`)가 `Provider<Stream<void>>`로 분리돼 있고 `run_sync_coordinator_test.dart:36`이 `overrideWithValue`로 갈아끼운다. 플랫폼 채널 미접촉. 전환 필터(오프라인→온라인만 통과)도 provider 안에 있어 테스트가 그 로직을 우회하는 점은 의도된 트레이드오프 |
| A5-7 | 타임아웃 30초 후 `_syncing` 래치 해제 | ✅ PASS | `_trySync()`의 `finally`에서만 해제(`run_sync_coordinator.dart:76-80`), 그 종료 보장은 한 계층 아래 `uploadTimeout`(`local_run_repository.dart:175`)이 한다. 코디네이터에 워치독을 두지 않은 판단이 특성 테스트로 명문화됨(`run_sync_coordinator_test.dart:150`). 타임아웃/예외 양쪽에서 다음 신호가 발화하는 것을 테스트 2건이 잠금 |

→ **A-5 findings: F-3, F-8**

### 1-B. A-6 GPS 경계

| # | 점검 항목 | 결과 | 근거 |
|---|---|---|---|
| A6-1 | `maxPlausibleSpeedMps` 25km/h 하향이 기존 스무딩 테스트·거리 누적과 정합하는가 | ✅ PASS | 점프 게이트는 **원시가 아니라 스무딩 좌표** 간 구간 속도로 판정한다(`gps_smoothing.dart:417-424`). 창 5의 이동평균이 노이즈를 크게 감쇠하므로 4 m/s 러너(스무딩 step ≈ 20m/5s)와 6.94 m/s 임계값 사이에 약 73% 헤드룸이 남는다. 기존 거리 정확도 테스트 전부 통과. 버려질 때 `_lastLat`을 유지하므로 다음 fix의 분모(`stepSeconds`)가 커져 **연쇄 폐기는 자기 제한적**이다 — 노트가 우려한 연쇄는 수식상 발생하지 않는다 |
| A6-2 | 마커=원시 / 폴리라인=스무딩 분리에 끝점 어긋남 부작용이 없는가 | ⚠️ PASS(조건부) | 정확도 게이트를 **양쪽이 같은 `filterConfig` 인스턴스**로 쓰므로(`geolocator_run_tracking_service.dart:310` ↔ `gps_smoothing.dart:348`) 한쪽만 통과하는 fix는 없다. 일시정지 중 원시 방출 차단도 걸려 있다. 마커가 선 끝보다 약 2 fix 앞서는 것은 **의도된 설계**(TRD §8.5 명시). 다만 F-6·F-7 참조 |
| A6-3 | `isAutoPaused` 배너가 출발 대기·수동 일시정지·재개 직후에 오작동하지 않는가 | ✅ PASS | `isAutoPaused = !_paused && _hasMoved && filter.isStationary`(`run_session_aggregator.dart:79`). 출발 대기 → `_hasMoved=false`, 수동 일시정지 → `_paused=true`, 재개 직후 → `resume()`이 `_hasMoved=false`로 되돌림(`:125`). 세션 미시작이면 `_aggregator == null` → false. 도메인 테스트가 ①~⑥ 전이를 한 케이스로 전부 잠금(`gps_smoothing_test.dart:256`), 위젯 테스트가 "컨트롤은 '일시정지'로 남고 '재개'가 뜨지 않는다"를 회귀로 고정 |
| A6-4 | `filterConfig` 주입이 집계기와 원시 게이트 양쪽에 일관되게 전달되는가 | ✅ PASS | 서비스 → `RunSessionAggregator(filterConfig: filterConfig)` → `GpsTrackFilter(config:)`. 프로덕션은 양쪽 모두 기본값 `const GpsFilterConfig()`라 동일 |
| A6-5 | `batterySaver` 5초 하향의 파생 영향 | ✅ PASS(주의) | `expectedIntervalSeconds`는 폴링 주기 외에 `_effectiveStopWindowSeconds`(25s → 12.5s)와 `_noiseFloor` cap(3.0m → 1.5m)에도 쓰인다. 실제 fix 간격이 5초로 함께 바뀌었으므로 **정합**하지만, 절전 프로파일 전용 회귀 테스트는 없다(F-5 계열) |

→ **A-6 findings: F-4, F-5, F-6, F-7, F-9**

### 1-C. A-3 iPad 앵커

| # | 점검 항목 | 결과 | 근거 |
|---|---|---|---|
| A3-1 | `shareOriginOfKey`가 GPX·공유카드 두 경로에서 일관되게 쓰이는가 | ✅ PASS | 앱 전체에서 `sharePositionOrigin`을 채우는 경로는 정확히 2곳이며(`gpx_export_service.dart:57`, `share_service.dart:59`) 둘 다 호출부가 `shareOriginOfKey(GlobalKey)`로 계산한다(`run_detail_page.dart:67`, `share_card_sheet.dart:112`). `exportRunAsGpx` 내부의 구 계산은 **삭제**돼 재사용 여지가 없다. 남은 `findRenderObject()` 3곳은 앵커와 무관(`app_shell.dart:73` 탭바 크기, `share_card_renderer.dart:83` 캡처 경계, `notification_tile.dart:188` 뷰포트 겹침) |
| A3-2 | `_DetailActions` Stateful 전환이 기존 테스트와 충돌하지 않는가 | ✅ PASS | 트리 위치가 동일해 State가 리빌드 간 유지된다. `_overflowKey`가 State 소유라 리빌드마다 새 키가 되는 문제 없음. `run_detail_page_test.dart` 16건 전부 통과, iPad 앵커 케이스 1건 추가(화면 전체 사각형과 다름 + 크기 1/4 미만 + ⋮ 아이콘과 겹침 + 중심이 우상단) |
| A3-3 | `onSelected` 시점에 키의 렌더 오브젝트가 유효한가 | ✅ PASS | `PopupMenuButton` 본체는 메뉴 라우트가 pop되는 동안에도 마운트 상태다. `share_card_sheet`는 `setState` 직후 계산하지만 리빌드는 다음 프레임이라 현재 트리가 유효 — `attached`·`hasSize` 이중 검사로 방어도 돼 있다 |

→ **A-3 findings: 없음**

### 1-D. 문서 정합 (실내 러닝 되돌림 재확인)

| # | 점검 항목 | 결과 | 근거 |
|---|---|---|---|
| D-1 | PRD v1.7 유지, §10.2 #14만 추가 | ✅ PASS | `git diff docs/PRD.md`가 **정확히 1줄 추가**(§10.2 표 14행). 문서 버전·변경 이력 미변경 |
| D-2 | TRD에 실내 시간기반 XP/스트릭 서술 잔존 없음 | ✅ PASS | `grep 실내 docs/TRD.md` 4건 전부 **기존 거리 기반 서술** 또는 연기 항목(#16→#26 이관, #26 본문). 시간 기반 산식·스트릭 대안 조건 서술 0건 |
| D-3 | ARCHITECTURE §6.3.1 제거 | ✅ PASS | `grep "6.3.1" docs/*.md` → 0건. §6.3에는 `hasRouteSamples` 미구현 상태 주석만 추가됨 |
| D-4 | TRD §14 #26~#28 상호 모순 없음 | ✅ PASS(조건부) | #26(실내 연기) / #27(서버 샘플 재계산 미구현) / #28(TR-04 잔여 격차)은 서로 다른 축이고 직접 모순 없음. F-11의 잠재 상호작용만 기록 |
| D-5 | 실내 시간기반 설계 노트 처리 | ✅ PASS | `_workspace/20260901_architect_indoor-time-based.md` 1행에 **"채택되지 않았다 · 문서 반영본은 되돌렸다"** 배너가 명시돼 있어 다음 사람이 정본으로 오독할 위험이 낮다 |

→ **문서 findings: F-1, F-2, F-10, F-11**

---

## 2. Findings

### 🔴 F-1 (CONFIRMED · Medium) — PRD 내부 모순: TR-10은 여전히 P1인데 §10.2 #14는 Phase 4로 연기했다

- `docs/PRD.md:188` — `| TR-10 | 실내 러닝(트레드밀) 수동 입력 | **P1** | 티어·랭킹 반영 여부는 §8.3 |`
- `docs/PRD.md:612` — `| 14 | 실내 러닝(TR-10) 전면 … | 🔵 **Phase 4** 웨어러블 연동 라운드에서 일괄 처리 |`
- `docs/PRD.md:497` — §8.3 표 `| 전용 실내 뱃지 | ✅ 지급 |` ↔ `docs/TRD.md:1596` #26 ⑦ "전용 실내 뱃지 0종 신설" (미이행 · 연기)

PRD가 정본인데 **같은 문서 안에서 우선순위가 P1과 Phase 4로 갈린다.** 또 §8.3이 "지급"이라고 단정한 실내 뱃지는 카탈로그에 0종이고 그 이행이 Phase 4로 밀렸는데 §8.3 본문은 그대로다. 이 상태로 커밋하면 다음 라운드에서 "PRD가 P1이라고 했다"를 근거로 실내 작업이 다시 열릴 수 있다.

**필요 조치(사용자 확인 사항)**: CLAUDE.md 규칙 4에 따라 PRD 스펙 변경은 사용자 확정 + 변경 이력 기록이 필요하다. 최소 둘 중 하나 —
(a) §5.1 TR-10 우선순위를 `P1 → Phase 4`로 바꾸고 §8.3 "전용 실내 뱃지 ✅ 지급"에 미이행·연기 각주를 달고 PRD 버전을 v1.8로 올린다, 또는
(b) #14를 "연기 결정"이 아니라 "미결 질문"으로만 두고 TR-10 우선순위는 건드리지 않는다(그럴 경우 #14 본문의 "Phase 4에서 일괄 처리" 단정을 완화).

### 🟠 F-2 (CONFIRMED · Low) — ARCHITECTURE §6.3의 페이즈 표기가 PRD·TRD와 다르다

- `docs/ARCHITECTURE.md:437` — "**P1** 웨어러블 연동 라운드의 착수 전 선행 작업으로 고정한다(TRD §14 #26)"
- `docs/PRD.md:612` / `docs/TRD.md:1596` — "**Phase 4** 웨어러블 연동 라운드"

PRD 자체도 §5.7 "웨어러블 연동 (P1)" ↔ §11 로드맵 "Phase 4 — 웨어러블 연동"으로 흔들리는 선행 문제가 있다(`docs/PRD.md:374` vs `:631`). F-1을 정리할 때 페이즈 라벨을 한 번에 통일할 것.

또한 §6.3 주석이 인용하는 `TRD §14 #26`은 실내 러닝 항목이고 **`hasRouteSamples`를 명시적으로 담고 있지 않다** — #26 본문에 "`hasRouteSamples` 도입" 항목을 추가하거나 별도 번호를 부여해야 상호 참조가 성립한다.

### 🟠 F-3 (CONFIRMED · Medium) — 같은 기록을 `_schedulePush` 체인과 `syncPending()`이 **동시에** 밀어 올릴 수 있다

`local_run_repository.dart:130`(`_schedulePush`)과 `:250`(`syncPending`)은 **서로 다른 실행 경로**다. `_uploads` 체인은 `save()`가 띄운 업로드끼리만 직렬화하고, `syncPending()`의 `_push()`는 그 체인을 타지 않는다.

재현 시나리오:
1. 러닝 종료 → `save()`가 행을 `pending`으로 쓰고 백그라운드 업로드 시작(3,600 샘플, 저대역에서 수십 초)
2. 그 사이 코디네이터의 신호(2분 주기 / 앱 복귀 / **연결 회복**)가 발화
3. `syncPending()`이 `sync_status != synced` 조건으로 **같은 행**을 집어 두 번째 업로드 시작

결과: 업로드가 멱등(`id` = 클라이언트 UUID)이라 **중복 행·데이터 손상은 없다.** 잃는 것은 대역폭(같은 페이로드 2회 전송)과 `applyServerConfirmation` 2회 실행(마지막 쓰기 승리, 값은 동일). 러닝 직후 = 신호 회복 직후인 경우가 많아 실제로 겹칠 확률이 낮지 않다.

- **A-5 이전에도 존재하던 경합이다**(그때도 행은 await 중 `pending`이었다) → **회귀 아님**
- 다만 A-5로 `_uploads` 체인이 생기면서 **증폭 여지가 늘었다**: 연달아 3건을 저장하면 체인이 순차 대기 중인 3건을 `syncPending()`이 한꺼번에 병렬로 다시 올린다

**제안(이번 범위 밖, 별도 라운드)**: `_push()` 진입 시 `id` 단위 in-flight 집합으로 가드하거나, `save()`의 업로드도 `syncPending()`과 같은 큐를 타게 통합. 관측 없이 고치면 오히려 지연이 생길 수 있어 계측 선행 권장.

### 🟡 F-4 (CONFIRMED · Low) — 새로 만든 주입 이음매 2개에 호출자·테스트가 하나도 없다

- `GeolocatorRunTrackingService.filterConfig`(`geolocator_run_tracking_service.dart:44`) — 프로덕션(`tracking_providers.dart:56`)도 테스트도 넘기지 않는다. 전부 기본값
- `GeolocatorRunTrackingService.batteryOptimizationGuard`(`:57`) — 동상. 노트는 "테스트에서 교체 가능하도록 주입받는다"고 적었으나 교체하는 테스트가 없다
- `lib/features/tracking/data/battery_optimization.dart` — **테스트 0건**. "요청 전에 `asked` 플래그를 먼저 쓴다", "iOS는 항상 true", "예외는 삼킨다" 세 계약이 코드 주석에만 있다

주입 자체는 옳은 설계다. 다만 지금은 "테스트 가능하게 만들었다"가 사실이 아니라 **의도 표명**에 그친다. `BatteryOptimizationGuard`는 `SharedPreferences.setMockInitialValues`로 앱 생애 1회 계약을 바로 잠글 수 있다.

### 🟡 F-5 (CONFIRMED · Low) — 구현체 → provider 이음매가 테스트에서 항상 우회된다

| 이음매 | 우회 방식 |
|---|---|
| `GeolocatorRunTrackingService.isAutoPaused` → `autoPauseReaderProvider` | 위젯 테스트가 `autoPauseReaderProvider.overrideWithValue(() => true)`로 통째 대체 |
| `GeolocatorRunTrackingService.rawFixStream` → `liveMarkerProvider` → `RunMapView` 마커 | `liveMarkerProvider`가 `service is! GeolocatorRunTrackingService`면 빈 스트림. 테스트 fake가 전부 여기 해당해 **`_followingRawFix == true` 경로가 한 번도 실행되지 않는다** |
| `batterySaver` 프로파일 5초 변경 | 프로파일별 회귀 테스트 없음(`expectedIntervalSeconds`가 정지판정 창·노이즈 바닥값에도 쓰이는데 그 조합을 잠그는 테스트가 없다) |

도메인 로직(집계기 상태 전이, 스무딩)은 잘 잠겨 있다. 비어 있는 것은 **"구현체의 가변 상태가 provider를 거쳐 화면에 도달하는가"** 한 칸이다. 실기기 검증 체크리스트에 이 세 줄을 명시적으로 넣을 것.

### 🟡 F-6 (PLAUSIBLE · Low) — `_followingRawFix`를 `_moveTo` **성공 전에** 세운다

`run_map_view.dart:90-95`:
```dart
ref.listen<AsyncValue<LatLng>>(liveMarkerProvider, (_, next) {
  final point = next.valueOrNull;
  if (point == null) return;
  _followingRawFix = true;   // ← _moveTo가 실패해도 true가 된다
  _moveTo(point);
});
```
`_moveTo`는 `_controller == null`이면 아무것도 하지 않고 반환한다(`:146-148`). 지도 컨트롤러가 준비되기 전에 첫 원시 fix가 도착하면 플래그만 켜지고 마커는 안 그려지며, 이후 `_syncRoute`도 `if (!_followingRawFix)` 때문에 마커를 그리지 않는다. 다음 원시 fix(약 5초 뒤)에 자가 치유되지만, 그 직후 사용자가 일시정지하면(원시 방출 중단) 폴리라인만 있고 **현재 위치 마커가 없는 상태**가 유지될 수 있다.

한 줄 수정으로 닫힌다(`_moveTo`가 컨트롤러를 확보했을 때만 플래그를 세운다). 실기기 없이 재현 확인이 안 돼 **이번에 고치지 않았다** — 지도 초기화 타이밍을 바꾸는 변경이라 확인 없이 손대는 편이 더 위험하다.

### 🟡 F-7 (PLAUSIBLE · Low) — 마커·**카메라**가 점프 게이트를 거치지 않은 좌표를 따라간다

`geolocator_run_tracking_service.dart:307-313`의 원시 게이트는 정확도만 본다. 정확도는 양호한데 위치가 튄 fix(도심 캐니언의 반사파는 accuracy를 낮게 보고하기도 한다)가 오면 마커뿐 아니라 **카메라까지** 그 지점으로 끌려간다(`run_map_view.dart:155-161`의 `scrollAndZoomTo`). 거리 계산은 영향 없다(원시 좌표는 누적에 안 쓰인다 — 코드·문서에 명시).

의도적 트레이드오프임은 문서에 적혀 있으나, **"마커가 튄다"와 "화면이 통째로 스크롤된다"는 체감이 다르다.** 실기기 검증에서 카메라 튐이 관측되면 원시 게이트에 완화된 점프 상한(예: 스무딩용의 2배)만 추가하는 절충안이 있다.

### 🟡 F-8 (PLAUSIBLE · Low) — 연결 감지 provider의 **동기 예외**는 삼켜지지 않는다

`run_sync_coordinator.dart:42-44`는 스트림 **에러**만 `onError`로 삼킨다. `_ref.read(connectivityRestoredProvider)` 또는 `Connectivity().onConnectivityChanged` 자체가 동기적으로 던지면 `RunSyncCoordinator` 생성자가 통째로 실패하고, `RunnitApp`이 시작 시 이 provider를 `watch`하므로 **4신호 전부**를 잃는다.

노트는 "구독 실패(플러그인 미등록 등)는 삼켜 나머지 신호로 계속 동작한다"고 적었으나 코드가 보장하는 것은 그 절반이다. `connectivity_plus`가 스트림을 지연 생성하므로 실제 발생 확률은 낮다 — 그래서 PLAUSIBLE. `try { … } catch (_) { _connectivity = const Stream<void>.empty().listen((_) {}); }` 정도로 닫힌다.

### 🟡 F-9 (PLAUSIBLE · Low) — 25 km/h 하향에 "일반 러닝은 잘리지 않는다"를 잠그는 테스트가 없다

기존 거리 정확도 테스트가 전부 통과하므로 **관측된 회귀는 없다**(§1-B A6-1의 헤드룸 계산도 안전 쪽). 다만 새로 추가된 4건 중 이 임계값 변경을 직접 겨냥한 테스트는 없다 — 지금 통과하는 것은 우연이 아니라 여유 덕분이지만, 그 여유가 코드로 고정돼 있지 않다.

제안: 정확도 15~25m 노이즈를 얹은 3.5~4.5 m/s 합성 로그에서 **폐기된 fix 비율이 X% 미만**임을 잠그는 테스트 1건. 임계값을 다시 만질 때 이 테스트가 경보 역할을 한다.

### ⚪ F-10 (CONFIRMED · 표기) — 변경 이력 행 삽입 위치

- `docs/ARCHITECTURE.md` — v0.13이 v0.1과 v0.2 **사이**에 들어갔다
- `docs/TRD.md` — v0.19가 v0.15와 v0.18 **사이**에 들어갔다(TRD 표는 원래도 정렬돼 있지 않다)

내용 오류는 아니지만 ARCHITECTURE 표는 지금까지 순서가 유지돼 있었다. 커밋 전 1줄 이동 권장.

### ⚪ F-11 (CONFIRMED · 기록만) — TRD §14 #27과 #26 ②의 잠재 상호작용이 상호 참조되지 않는다

#27(서버가 샘플로 거리 재계산 — 베타 오픈 전)을 구현하면, **경로 샘플이 없는 기록의 거리는 0으로 재계산된다.** 그런데 #26 ②는 "웨어러블 실내 거리(경로 없는 기기 측정값)의 반영 범위"를 열어 두고 있다. 둘을 각자 진행하면 웨어러블 실내 거리를 받아들이기로 결정한 직후 #27 구현이 그것을 0으로 깎는 충돌이 난다.

지금은 어느 쪽도 구현 전이라 **실제 모순은 없다.** #27 본문에 "샘플 없는 기록의 취급은 #26 ②와 함께 결정" 한 줄만 추가해 두면 충분하다.

---

## 3. 재현 불가 · 수동 검증으로 이관 (수정 요청하지 않음)

| # | 항목 | 사유 |
|---|---|---|
| M-1 | iPad 팝오버가 실제로 ⋮ 버튼을 가리키는지 | 위젯 테스트는 `origin` 사각형 값까지만 검증. UIKit 팝오버 렌더는 실기기에서만 |
| M-2 | 25 km/h 임계값의 엘리트 인터벌 손실 여부 | 합성 로그로는 판단 불가. `20260901_gps_field-accuracy-verification.md` §3.1 세트 A/B |
| M-3 | 절전 모드 실측 배터리 소모율 (5초 폴링 전환 후) | 노트가 "실기기에서 채운다"로 명시 |
| M-4 | `distanceFilter` 3m/8m이 만드는 마커·자동 일시정지 지연 (TRD §14 #28) | 실기기 |
| M-5 | 배터리 최적화 예외 다이얼로그의 OEM별 동작 | 샤오미·화웨이 실기기 필요 |

---

## 4. 커밋 전 확인 체크리스트

**필수 (blocking)**

- [ ] **F-1 해소** — PRD §5.1 TR-10 우선순위와 §10.2 #14의 페이즈를 일치시킬지 사용자에게 확인. 스펙 변경이면 PRD 변경 이력 + 버전(v1.8) 갱신 (CLAUDE.md 규칙 4)
- [ ] **F-2 해소** — ARCHITECTURE §6.3의 "P1" ↔ PRD/TRD "Phase 4" 통일, TRD §14 #26에 `hasRouteSamples` 항목 추가(상호 참조 성립)

**권장 (non-blocking, 한 줄짜리)**

- [ ] F-10 — ARCHITECTURE v0.13 / TRD v0.19 변경 이력 행 위치 정렬
- [ ] F-11 — TRD §14 #27에 "#26 ②와 함께 결정" 한 줄 추가

**신규 파일 스테이징 누락 확인** (`git add` 안 하면 CI가 컴파일조차 못 한다)

- [ ] `lib/core/utils/share_anchor.dart` — 없으면 `run_detail_page.dart`·`share_card_sheet.dart`가 import 실패
- [ ] `lib/features/tracking/data/battery_optimization.dart` — 없으면 `geolocator_run_tracking_service.dart`가 import 실패
- [ ] `test/sync/offline_sync_test.dart`, `test/sync/run_sync_coordinator_test.dart` — **디렉터리 전체가 미추적**이다. `offline_sync_test.dart`도 아직 한 번도 커밋된 적이 없다
- [ ] `_workspace/20260901_*.md` 7건 (이 리포트 포함)

**의존성**

- [ ] `pubspec.yaml`에 `connectivity_plus: ^7.3.1` 추가됨. `pubspec.lock`은 `.gitignore` 대상이라 diff에 안 뜬다 — 다른 개발자·CI는 `flutter pub get` 필요. **커밋 메시지에 명시할 것**
- [ ] `android/app/src/main/AndroidManifest.xml`에 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 추가됨 — Play 스토어 등록 시 용도 설명 필요(주석에 기재됨)

**최종 게이트**

- [ ] `flutter analyze` → No issues found (✅ 확인됨)
- [ ] `flutter test` → 279건 통과 (✅ 확인됨)
- [ ] 커밋 단위 분리 권장: A-3(UI) / A-5(sync) / A-6(GPS) / docs — 세 라운드가 독립적이라 되돌리기 단위도 독립적이어야 한다

**다음 라운드로 이관 (커밋 차단 아님)**

- [ ] F-3 중복 업로드 경합 — 계측 후 결정 (backend-engineer)
- [ ] F-4 `BatteryOptimizationGuard` 테스트, F-5 provider 이음매 테스트 (gps-tracking-engineer)
- [ ] F-6 `_followingRawFix` 순서, F-7 카메라 튐 — 실기기 검증 결과와 묶어서 (gps-tracking-engineer)
- [ ] F-8 코디네이터 생성자 방어, F-9 임계값 회귀 테스트
