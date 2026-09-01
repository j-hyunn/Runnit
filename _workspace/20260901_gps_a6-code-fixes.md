# A-6 후속 코드 수정 — 실내 러닝 무관 항목만

- 작성: 2026-09-01 / gps-tracking-engineer
- 입력: `_workspace/20260901_gps_field-accuracy-verification.md` §8.2 "코드 후속조치 후보"
- 근거: `docs/PRD.md` §5.1(TR-01~08)·§8.4, `docs/ARCHITECTURE.md` §6.3~6.5,
  `docs/TRD.md` §7·§8·§14
- **범위 제외**: C-5·C-6(실내 러닝) — 사용자가 웨어러블 연동 라운드로 연기 확정
  (PRD §10.2 #14, TRD §14 #26). 이번 변경에 `indoorRun` 경로는 한 줄도 건드리지 않았다.
- 커밋하지 않았다.

---

## 1. C-1 (High) — 임계값 문서·코드·서버 3자 정렬

### 1.1 실제 값 확인 (추측 없이 원본에서)

| 축 | PRD §8.4 (정본) | TRD §7·§8.3 (서술) | ARCHITECTURE §6.4 | 서버 구현 | 클라이언트 코드(수정 전) |
|---|---|---|---|---|---|
| 구간 속도 상한 | **25 km/h 초과 구간 제거** | 25 km/h | "서버와 동일 기준으로 클라이언트 1차 필터" | **해당 검사 없음.** `validate_run`은 `max_speed_mps > 15.0`(54km/h) 플래그 + 평균 `> 7.0 m/s` 플래그뿐 (마이그레이션 04) | 8.5 m/s ≈ **30.6 km/h** |
| 정확도 게이트 | (규정 없음) | `> 20m` 제외 | — | **대응 검사 없음** | **25m** |

즉 어긋난 곳이 두 군데였고 성격이 서로 다르다.

### 1.2 판단과 조치

**(a) 구간 속도 → 코드를 25 km/h로 내렸다.**
`GpsFilterConfig.maxPlausibleSpeedMps = 25 / 3.6`(≈6.944 m/s). 상수식을 그대로
`25 / 3.6`으로 적어 "이 숫자는 PRD의 25km/h다"가 코드에서 보이게 했다.

- 근거: PRD가 정본이고, ARCHITECTURE §6.4가 명시적으로 "서버 검증과 **동일 기준**의
  클라이언트 1차 필터"를 요구한다. 문서를 코드(30.6km/h)에 맞추려면 PRD §8.4의
  25km/h까지 같이 올려야 하는데, 그건 스펙 변경이라 사용자 확인 사항이다.
- 실효 근거: 서버가 제거할 구간을 클라이언트가 거리에 넣으면 **화면 거리 > 서버 확정
  거리**로 벌어진다. 티어·랭킹의 원천이 서버 재계산값이므로(PRD §8.4 원칙), 사용자에게
  보여준 값이 더 큰 쪽으로 어긋나는 것이 가장 나쁜 형태다.
- 러닝 상한으로서의 타당성: 25km/h = 2'24"/km. 지속주 상한(~20km/h)보다 위라 일반
  러닝·대회 페이스에는 닿지 않는다. 다만 **엘리트 인터벌 스프린트는 걸릴 수 있고**,
  fix를 버리면 다음 fix가 더 오래된 기준점과 비교되어 연쇄로 버려질 수 있다.
  → 실기기 검증(§3.1 세트 A/B)에서 손실이 관측되면 **서버 임계값과 함께** 올린다.
  한쪽만 올리면 C-1이 그대로 재발한다. TRD §8.3에 이 조건을 적어 뒀다.

**(b) 정확도 게이트 → 문서를 25m로 정정했다(코드 유지).**
이 게이트는 **클라이언트 전용**이다. 서버에는 대응 검사가 아예 없어서 "서버에 맞춘다"는
축이 존재하지 않고, 판단 기준은 "도심 캐니언에서 fix가 살아남는가" 하나뿐이다.
20m로 조이면 고층 구간에서 채택 fix가 급감해 TR-01(±3%)이 오히려 위태로워진다.
TRD §8.3의 서술값 20m를 코드 실측값 25m로 고쳤다.

### 1.3 부수 확인 — 서버가 아직 샘플 재계산을 안 한다 (신규 §14 #27)

`validate_run`은 **플래그만** 세우고, PRD §8.4·TRD §7이 규정한
"구간 제거 후 재계산 / 원본 샘플로 거리 재계산"은 구현돼 있지 않다. 즉 25km/h 기준은
현재 **클라이언트에만 살아 있다.** 방향은 안전하지만(클라이언트가 더 조인다),
"클라이언트 계산 값을 신뢰하지 않는다"는 원칙이 코드로는 아직 성립하지 않는다.
backend 담당 항목이라 이번에 건드리지 않고 TRD §7 ⚠️ 와 §14 #27로 기록했다.

---

## 2. C-2 (Medium) — 자동 일시정지를 화면에 드러냄

### 2.1 수동 일시정지와 **합치지 않았다** (판단)

`RunStatus.paused`로 승격하지 않고 별도 파생 상태
(`RunSessionAggregator.isAutoPaused`)로 뒀다. 이유 두 가지:

1. `RunStatus`는 15초 체크포인트와 서버 업로드에 그대로 실리는 **영속 상태**다.
   신호등마다 `paused`↔`recording`을 오가면 체크포인트가 그 순간 값을 저장하고,
   강제 종료 복구 시 "사용자가 멈춰 둔 러닝"으로 잘못 되살아난다.
2. 화면 컨트롤이 `paused`에서 "재개" 버튼으로 바뀌는데, 자동 일시정지에는 누를 대상이
   없다 — `resume()`은 `isPaused == false`라 no-op이라 **눌러도 아무 일도 안 나는
   버튼**이 생긴다. 해제는 사용자가 아니라 다음 이동 fix가 한다.

### 2.2 구현

- `RunSessionAggregator._hasMoved` 추가. 세션은 항상 정지 상태로 시작하므로
  (`GpsTrackFilter` 상태기계), 이 플래그가 없으면 **출발선에 서 있는 동안**
  "자동 일시정지됨"이 뜬다. 아직 한 번도 멈춘 적이 없는데.
- `resume()`에서 `_hasMoved = false`로 되돌린다 — 재개 직후 필터는 다시 정지 상태에서
  출발하므로, 살려 두면 재개 버튼을 누른 직후 배너가 뜬다.
- `isAutoPaused = !_paused && _hasMoved && filter.isStationary`.
- `GeolocatorRunTrackingService.isAutoPaused` → `autoPauseReaderProvider`
  (`wearableNoticeReaderProvider`와 같은 "호출 시점에 읽는 함수" 패턴 — 판정 근거가
  구현체의 가변 상태라 Riverpod가 변화를 통지하지 못한다).
- 표시는 `_ActiveBanners`의 info 배너: **"자동 일시정지됨 — 멈춘 동안은 거리·페이스에
  넣지 않아요. 다시 움직이면 이어서 기록해요."** 이 서브트리는 이미 초당 틱으로
  리빌드되므로 지도·통계 카드의 리빌드 범위를 넓히지 않는다(기존 성능 계약 유지).
  지도 딤은 **수동 일시정지 전용**으로 남겼다 — 두 상태가 화면에서 구분돼야 한다.

### 2.3 테스트

- 위젯(`test/tracking/tracking_page_test.dart`, 신규 3건):
  배너 노출 / 해제 시 사라짐 / 정지 아닐 때 없음 + **컨트롤이 "일시정지"로 남고
  "재개"가 뜨지 않음**(수동과 혼동되지 않는다는 회귀).
- 도메인(`test/tracking/gps_smoothing_test.dart`, 신규 1건):
  출발 전 false → 3분 주행 중 false → 60초 정지 true → 재주행 false →
  수동 pause 시 false(축이 다름) → resume 직후 false.

---

## 3. C-3 / C-4 (Medium) — TR-04(5초 이내 최신 위치 반영)

두 원인을 각각 끊었다.

### 3.1 C-3 폴링 — `batterySaver` 10초 → 5초

10초 폴링에서는 **앱이 아는 최신 좌표 자체가 최대 10초 전 것**이라 지도를 아무리 빨리
그려도 TR-04를 못 지킨다. 렌더링 문제가 아니라 데이터가 없는 문제다.

- 절전의 이득을 간격이 아니라 **정확도 등급(`medium`) + 거리필터(8m)** 로 옮겼다.
  GNSS 듀티 사이클과 콜백 수를 줄이는 축은 살아 있다.
- **트레이드오프(명시)**: 표준 대비 배터리 절감폭이 이전보다 **작아졌다.** 절전 모드는
  이제 "훨씬 드물게 잰다"가 아니라 "덜 정확하게, 덜 자주 콜백받는다"다.
  PRD §6(1시간 10% 이하)은 어차피 **표준이 기본값**이라 기본 경로의 목표치는 그대로다.
  절전 실측 소모율은 실기기 검증에서 채운다.
- 대안으로 "설정 화면에 트레이드오프를 문구로 고지"(원 C-3 제안)도 있었으나, PRD의
  P0 수용 기준을 **설정 문구로 면제**하는 형태라 택하지 않았다.

### 3.2 C-4 스무딩 지연 — 마커만 원시 fix로 분리

이동평균 창(5)은 표준 프로파일에서 약 2 fix(≈10초) 지연을 만든다. 선(폴리라인)은
그 값이 맞지만(지그재그가 죽는다) "지금 내 위치" 점까지 뒤처지면 체감 지연이
폴링 간격 + 스무딩 지연이 된다.

- `GeolocatorRunTrackingService.rawFixStream` 신설 — **정확도 게이트만** 통과시킨다
  (마커가 튀지 않을 최소한). 점프 게이트·이동평균은 거치지 않는다.
- `liveMarkerProvider`(신규) → `RunMapView`가 마커·카메라를 이 좌표로 몰고,
  폴리라인만 `liveRouteProvider`(스무딩 좌표)를 쓴다.
- 원시 좌표는 **거리 계산에 절대 쓰지 않는다.** 코드 주석·TRD §8.5에 못 박았다.
- 원시 스트림이 없는 구현체(테스트 fake)에서는 예전처럼 폴리라인 마지막 점으로
  마커를 그린다(`_followingRawFix` 플래그) — 기존 위젯 테스트가 그대로 통과한다.
- 일시정지 중에는 원시 좌표를 방출하지 않는다. 멈춰 있다는 사실이 화면에 보여야 한다.

### 3.3 남은 격차 → TRD §14 #28

`distanceFilter`(표준 3m / 절전 8m)는 **이동량이 적으면 콜백 자체를 억제**한다.
아주 느린 걷기·제자리 대기에서는 마커 갱신이 5초를 넘을 수 있고, 같은 이유로
**절전 모드에서는 정지 판정용 fix가 안 들어와 자동 일시정지(TR-03) 진입이 늦거나
안 될 수 있다.** 거리필터를 0으로 내리면 배터리 목표와 충돌하므로 실기기에서 두 수치를
함께 재고 결정한다. 완전 해결이 아니라는 사실을 문서에 남겼다.

---

## 4. R-2 (Medium) — Android 배터리 최적화 예외

`lib/features/tracking/data/battery_optimization.dart` 신설
(`BatteryOptimizationGuard`).

- **왜**: 포그라운드 서비스 + 상시 알림 위에 OEM 전력 관리가 한 겹 더 있다.
  샤오미·화웨이·오포·일부 삼성은 화면 꺼짐 수십 분 뒤 서비스째로 재운다 →
  60분 러닝 뒷부분이 통째로 비어 TR-02("데이터 손실 0")가 깨진다.
- **언제 묻는가**: `ensureReady()`의 3단계 — "항상 허용" 위치 권한을 **실제로 받은
  경우에만**. 포그라운드 전용으로 저하된 사용자에게는 의미 없는 다이얼로그다.
- **몇 번 묻는가**: 앱 생애에 **한 번**
  (`SharedPreferences: runnit.tracking.battery_opt_asked`, 알림 권한 프라이밍과 같은
  원칙). 물어봤다는 사실은 **요청 전에** 적는다 — 요청 도중 앱이 죽어도 다음 러닝에서
  같은 다이얼로그가 다시 뜨지 않게.
- **실패는 삼킨다**: 예외·거부로 러닝이 시작되지 않으면 안 된다. 결과는
  `hasBatteryOptimizationExemption`으로만 노출한다.
- 매니페스트에 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 추가(최소 변경, 주석에
  Play 정책 제약 기재 — 피트니스 트래킹은 허용 카테고리지만 스토어 등록 시 용도 설명
  필요). OEM 자체 설정(MIUI "자동 시작" 등)은 코드로 열 수 없다.

---

## 5. R-5 (Medium) — iOS 백그라운드 위치: **코드 변경 불필요**로 결론

`ios/Runner/Info.plist`를 확인했다. `UIBackgroundModes`에 `location`이 **이미 있다**
(`remote-notification`과 함께). 백그라운드 **위치**는 entitlement가 필요 없는 기능이라
`Runner.entitlements`가 pbxproj에 연결되지 않아도 동작한다.

→ **네이티브 파일 수정 없음.** 미연결 entitlement가 실제로 막고 있는 것은
**HealthKit(웨어러블 라운드 소관)** 과 **APNs `aps-environment`(TRD §14 #25 FCM 운영
설정)** 뿐이며, 둘 다 Xcode에서 Capability를 추가해야만 해결된다(파일 상단 주석에 절차가
이미 적혀 있다). 이 사실을 TRD §8.2에 기록해, 다음 사람이 "위치 백그라운드가 entitlement
때문에 안 되는 것"으로 오인하지 않게 했다.

---

## 6. 변경 파일

**코드**
- `lib/features/tracking/domain/gps_smoothing.dart` — 속도 임계값 25km/h, batterySaver 5초, 주석
- `lib/features/tracking/domain/run_session_aggregator.dart` — `isAutoPaused`, `_hasMoved`
- `lib/features/tracking/data/geolocator_run_tracking_service.dart` — `rawFixStream`, `isAutoPaused`, `filterConfig` 주입, 배터리 예외 3단계
- `lib/features/tracking/data/battery_optimization.dart` — **신규**
- `lib/features/tracking/presentation/tracking_ui_providers.dart` — `liveMarkerProvider`, `autoPauseReaderProvider`
- `lib/features/tracking/presentation/tracking_page.dart` — 자동 일시정지 배너
- `lib/features/tracking/presentation/widgets/run_map_view.dart` — 마커/선 좌표 분리

**네이티브**
- `android/app/src/main/AndroidManifest.xml` — `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 1줄 + 주석
- iOS: **수정 없음**(§5)

**테스트**
- `test/tracking/tracking_page_test.dart` — 자동 일시정지 3건
- `test/tracking/gps_smoothing_test.dart` — 자동 일시정지 상태 전이 1건

**문서**
- `docs/TRD.md` §7(서버 구현 차이 ⚠️), §8.2(배터리 예외·iOS 결론), §8.3(임계값 정정),
  §8.5(배터리 모드 표·마커 분리), §14 #27·#28 신설
- `docs/ARCHITECTURE.md` §6.4(임계값·자동 일시정지 상태 축), §6.5(프로파일 표)
- `_workspace/20260820_gps_tracking_notes.md` — 임계값·프로파일 표 2행 갱신

---

## 7. 검증

- `flutter analyze` → **No issues found.**
- `flutter test` → **279건 전체 통과**(기존 275 + 신규 4).
- 실기기 검증은 여전히 미실행이다 — 이 변경은 `20260901_gps_field-accuracy-verification.md`의
  측정 대상 파라미터를 바꿨으므로, 그 문서 §1.2/§1.3 표를 실행 시점에 이 값들로
  읽어야 한다(속도 25km/h, batterySaver 5초, 마커=원시 좌표).

## 8. 이번에 손대지 않은 것

| 항목 | 이유 |
|---|---|
| C-5(§5.7 판정축 `hasRouteSamples`) | 서버·스키마 소관 + 웨어러블 라운드 선행 작업으로 고정됨(ARCHITECTURE §6.3) |
| C-6(실내 러닝 거리 0) | 사용자 확정으로 웨어러블 라운드 연기(TRD §14 #26) |
| C-8(`flutter_background_service` 미사용 의존성) | 이번 범위 밖(정리 항목) |
| C-9(오프라인 복귀 감지 2분) | 이번 범위 밖. 측정 후 결정 |
| 서버 샘플 재계산 | backend 소관 — TRD §14 #27로 등재만 |
