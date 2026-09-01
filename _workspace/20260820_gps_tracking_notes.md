# GPS 트래킹 구현 노트 (Runnit)

- 작성: 2026-08-20 / gps-tracking-engineer
- 대상 코드: `lib/features/tracking/**`
- 상위 계약: `_workspace/20260819_132600_architect_data-model.md`(모델),
  `_workspace/20260819_132600_backend_schema.md` §6 `validate_run`(서버 재검증)

---

## 0. 이 문서의 요약

- 폰 GPS 트래킹, 워치(Apple Watch/Garmin) 심박 합류, 오프라인 우선 저장까지 구현 완료.
- **가장 중요한 수정**: 정지 상태 GPS 드리프트가 거리로 누적되던 버그를 잡았다.
  구간 임계값 방식 → **순 변위 기반 정지/이동 상태기계**로 교체. 합성 로그 기준
  5분 정지 시 누적 거리 124m → 0m.
- 네이티브 설정(iOS Info.plist / AndroidManifest)에 위치·백그라운드·헬스 항목 추가.
- flutter-ui-designer가 구독할 provider 계약은 §5.

---

## 1. 구현 파일

| 파일 | 역할 |
|------|------|
| `domain/gps_smoothing.dart` | **순수 Dart.** 정확도 게이트 → 이동평균 → 점프 제거 → 정지/이동 상태기계 |
| `domain/run_session_aggregator.dart` | **순수 Dart.** 스무딩 결과 → `RunRecord` 누적(거리/시간/고도/칼로리/심박) |
| `domain/polyline_codec.dart` | RDP 단순화 + Google encoded polyline(precision 5) |
| `data/geolocator_run_tracking_service.dart` | `RunTrackingService` 구현. 권한·위치 스트림·틱·체크포인트 **배선만** |
| `data/health_wearable_source.dart` | HealthKit / Health Connect 심박 폴링 어댑터 |
| `data/local_run_database.dart` (+`.g.dart`) | drift 로컬 테이블(`RunRecordRows`) |
| `data/local_run_repository.dart` | `RunRepository` 구현. 로컬 우선 저장 → 서버 upsert |
| `data/tracking_providers.dart` | Riverpod 배선 + `TrackingController` |

플러그인에 의존하는 코드와 계산 로직을 의도적으로 분리했다. `domain/`은
geolocator/health/riverpod를 전혀 모르므로 합성 GPS 로그로 단위 테스트가 된다.

---

## 2. GPS 스무딩과 거리 계산 — 무엇을 왜 이렇게 했나

### 2.1 파이프라인 (순서가 계약이다)

1. **정확도 게이트** — `accuracy > 25m`인 fix는 버린다. 가장 싸고 효과가 큰 필터.
   25m는 도심 캐니언에서 흔한 값이라 더 조이면 도심 러닝에서 fix가 안 남는다.
2. **신호 유실 감지** — 직전 fix와 20초 이상 벌어지면 이동평균 창과 정지판정 창을
   비운다. 유실 구간 앞뒤 좌표를 평균내면 존재하지 않는 중간 지점이 생긴다.
   기준점은 살려둬서 복구 직후 fix의 구간 속도로 이상치를 걸러낸다.
   공백이 120초를 넘으면 이어붙이지 않고 정지 상태로 재시작한다(차량 이동 등
   다른 원인일 확률이 높다).
3. **이동평균 스무딩** — 최근 5개 좌표 평균. 거리와 폴리라인 모두 이 좌표를 쓴다.
4. **점프 제거** — 구간 속도 > 8.5 m/s(≈30.6 km/h)면 버린다.
   서버 `validate_run`의 `implausible_max_speed`(15 m/s)보다 **클라이언트가 더
   보수적인 것은 의도적**이다 — 서버가 플래그를 달기 전에 걸러낸다.
   버린 fix는 이동평균 창에서도 빼낸다(이번에 수정) — 안 그러면 이상치 하나가
   이후 5개 fix의 스무딩을 오염시킨다.
5. **정지/이동 상태기계** — 아래 2.2.

### 2.2 정지 드리프트 버그와 그 수정 ★ 이 작업의 핵심

**증상.** 이전 구현은 "구간 이동량이 노이즈 바닥값(≈1m) 미만이면 정지"라는
구간별 임계값을 썼다. 합성 회귀 테스트(정확도 6m, 1Hz, 5분간 제자리 흔들림)에서
**누적 거리 124m**가 잡혔다. 테스트는 이미 있었지만 통과한 적이 없었다.

**원인.** 이동평균을 거쳐도 정지 좌표는 평균 주변에서 계속 흔들린다. 구간
임계값은 그 흔들림 중 **임계값을 넘는 것만 골라 더하는** 필터라 왕복 오차가
상쇄되지 않고 한 방향으로만 쌓인다. 임계값을 올리면 느린 조깅이 잘려나가므로
같은 방식으로는 해결이 안 된다.

**수정.** 순 변위 기반 상태기계로 교체했다.

- `stationary`(세션은 여기서 시작 — 출발선에 선 시간이 거리가 되면 안 된다)
  - 기준점(anchor)에서 **순 변위**가 `max(8m, 정확도×1.5)` 이상이 되기 전까지
    거리를 1m도 누적하지 않는다.
  - 탈출하는 순간 anchor→현재 변위를 **통째로 한 번에** 더한다. 임계값에 도달할
    때까지의 실제 이동을 잃지 않는다.
  - 정지 중 anchor는 EMA(α=0.1)로 현재 좌표를 천천히 따라간다. 도심에서 서 있는
    동안 GPS가 수십 초에 걸쳐 서서히 흐르는 현상을 흡수해 오탈출을 막는다.
- `moving`
  - 스무딩 좌표 간 구간 누적. 구간 속도 < 0.6 m/s이거나 이동량이 노이즈
    바닥값 미만이면 그 구간만 버린다.
  - 최근 창(기본 10초, fix 간격의 2.5배 이상으로 자동 확대) 동안의 **순 변위**가
    `max(6m, 정확도)` 미만이면 `stationary`로 복귀.
- 히스테리시스: 탈출(8m) > 복귀(6m). 경계에서 상태가 떨리지 않는다.

**왜 순 변위인가.** 왕복 흔들림은 순 변위에서 서로 상쇄된다. 제자리에서 아무리
흔들려도 anchor 기준 변위는 임계값을 못 넘는다. 누적 자체가 원천 봉쇄된다.

**남는 오차(의도된 것).** 이동평균 창(5) 때문에 스무딩 좌표는 실제 위치보다
`(5-1)/2 = 2` fix만큼 뒤처진다. 그래서 멈춘 직후 약 30m가 늦게 잡히고, 재출발
직후 약 30m가 늦게 잡힌다. **부호가 반대라 전체 합계에서는 상쇄된다** —
신호등 시나리오 테스트에서 실제 1200m 대비 오차 1% 이내로 확인했다.

### 2.3 임계값 요약 (`GpsFilterConfig`)

| 값 | 기본 | 근거 |
|----|------|------|
| `maxAccuracyMeters` | 25 | 도심 캐니언 통상값. 더 조이면 fix가 안 남는다 |
| `maxPlausibleSpeedMps` | **25/3.6** | ≈6.94 m/s = **25 km/h**. PRD §8.4 서버 기준과 같은 숫자로 맞췄다(2026-09-01, A-6 C-1 — 이전 값 8.5). 근거·트레이드오프는 `20260901_gps_a6-code-fixes.md` §1 |
| `minMovingSpeedMps` | 0.6 | ≈2.2 km/h. 가장 느린 걷기(3 km/h)보다 낮아 실제 이동을 안 자른다 |
| `minStepMeters` | 1.0 | 속도 게이트를 통과해도 절대 이동량이 이보다 작으면 노이즈 |
| `smoothingWindow` | 5 | 더 키우면 실제 코너링이 뭉개진다 |
| `signalGapSeconds` | 20 | 이보다 긴 공백은 신호 유실 |
| `maxBridgeSeconds` | 120 | 2분 초과 공백은 이어붙이지 않는다 |
| `stationaryExitMeters` | 8 | 러닝 3초·걷기 6초 거리. 스무딩 후 지터(σ≈1m)의 8σ 밖 |
| `stationaryEnterMeters` | 6 | 탈출값보다 낮게(히스테리시스) |
| `stopWindowSeconds` | 10 | 정지 복귀 관측 창. fix 간격 × 2.5로 자동 확대 |
| `stationaryAnchorEma` | 0.1 | 정지 중 anchor 추종 계수 |

### 2.4 배터리 ↔ 정확도 프로파일 (`TrackingProfile`, 사용자 설정 노출 대상)

| 프로파일 | fix 간격 | distanceFilter | geolocator 정확도 |
|----------|---------|----------------|-------------------|
| `highAccuracy` | 1s | 0m | best |
| `standard`(기본) | 5s | 3m | high |
| `batterySaver` | **5s** | 8m | medium |

⚠️ `batterySaver`의 fix 간격은 2026-09-01(A-6 C-3)에 10s → 5s로 바뀌었다.
10s에서는 TR-04(5초 이내 최신 위치 반영)를 구조적으로 만족할 수 없었다.
절전 이득은 이제 정확도 등급(medium)과 거리필터(8m)에서만 나온다.

⚠️ **러닝 중에는 바꾸지 말 것.** `trackingProfileProvider`가 바뀌면
`runTrackingServiceProvider`가 재생성되어 진행 중 세션이 사라진다.
설정 화면은 진행 중 세션이 있으면 이 항목을 비활성화해야 한다.

---

## 3. elapsedSeconds vs movingSeconds — 정지 판정 기준

계약서 §2.2 그대로다.

- `elapsedSeconds` = `endedAt - startedAt` **벽시계**. 일시정지 포함.
  집계기가 아니라 시계가 정한다(`snapshot(now:)` 인자).
- `movingSeconds` = 이동으로 인정된 구간의 합.
  - 일시정지 중에는 fix를 아예 넣지 않으므로 자동으로 멈춘다.
  - **정지 상태(신호등 대기 등)도 제외된다.** 상태기계가 `isMoving=false`로
    판정한 구간은 거리도 시간도 안 더한다.
  - 한 구간이 이동시간에 더할 수 있는 최대치는 `signalGapSeconds`(20초)다 —
    신호 유실 구간이 통째로 이동시간이 되는 걸 막는다.
- `snapshot()`에서 `movingSeconds = min(moving, elapsed)`로 한 번 더 조인다.
  서버 `validate_run`의 `moving_exceeds_elapsed` 플래그를 유발하지 않기 위해서다.
- **페이스의 분모는 movingSeconds다.** 정지 시간을 넣으면 신호등 하나에 페이스가
  무너진다. 제외가 러너의 기대와도 일치한다.

**일시정지 처리.** `pause()/resume()`은 필터의 `breakContinuity()`를 호출해
기준점·창·상태를 전부 비운다. 그러지 않으면 일시정지 동안 이동한 거리가 재개
순간 한 번에 누적된다(회귀 테스트로 고정).

---

## 4. 네이티브 설정 변경 내역

기존 카카오 딥링크 설정은 **건드리지 않고 추가만** 했다.

### 4.1 `ios/Runner/Info.plist`

| 키 | 이유 |
|----|------|
| `NSLocationWhenInUseUsageDescription` | 1단계 "앱 사용 중 허용" |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | 2단계 "항상 허용" 승격 |
| `NSLocationAlwaysUsageDescription` | permission_handler가 locationAlways 상태 조회 시 참조 |
| `UIBackgroundModes` = `[location]` | `AppleSettings.allowBackgroundLocationUpdates=true`는 이 선언이 없으면 런타임 예외 |
| `NSHealthShareUsageDescription` | HealthKit **읽기 전용**. 쓰기 안 하므로 Update 키는 두지 않음 |
| `NSMotionUsageDescription` | 모션 보조 |

### 4.2 `ios/Runner/Runner.entitlements` (신규)

HealthKit 자격(`com.apple.developer.healthkit`)을 담은 파일을 만들어 뒀지만
**아직 Xcode 프로젝트에 연결되지 않았다.** pbxproj를 손으로 편집하지 않기 위해
파일만 준비했다.

> **후속 필요 작업(수동):** Xcode → Runner 타겟 → Signing & Capabilities →
> `+ Capability` → **HealthKit** 추가. 그래야 `CODE_SIGN_ENTITLEMENTS`가 이
> 파일을 가리키고 실기기에서 HealthKit 읽기가 동작한다.
> 이 작업 전까지 워치 심박 연동은 실기기에서 항상 폴백(폰 단독)으로 떨어진다.

### 4.3 `android/app/src/main/AndroidManifest.xml`

| 항목 | 이유 |
|------|------|
| `ACCESS_COARSE_LOCATION` / `ACCESS_FINE_LOCATION` | 포그라운드 위치 |
| `ACCESS_BACKGROUND_LOCATION` | API 29+ 분리 권한. 2단계로 별도 요청 |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_LOCATION` | API 34+ 서비스 타입별 권한 |
| `POST_NOTIFICATIONS` | 포그라운드 서비스 상시 알림(API 33+) |
| `WAKE_LOCK` | 화면 꺼짐 상태 유지 |
| `health.READ_HEART_RATE` | Health Connect 심박 읽기 |
| `<uses-feature ... gps required=false>` | 위치 하드웨어 없는 기기도 설치 가능 |
| `<queries><package com.google.android.apps.healthdata>` | package visibility(API 30+). 없으면 Health Connect를 항상 "미설치"로 판단 |
| MainActivity `ACTION_SHOW_PERMISSIONS_RATIONALE` intent-filter | Health Connect 권한 화면의 근거 링크 |
| `ViewPermissionUsageActivity` activity-alias | Health Connect 권한 사용처 표시 |

### 4.4 백그라운드 트래킹 방식 — `flutter_background_service`를 쓰지 않았다

`pubspec.yaml`에 의존성은 있지만 코드에서 사용하지 않는다. 이유:

- **Android**: geolocator의 `AndroidSettings.foregroundNotificationConfig`가
  포그라운드 서비스와 상시 알림을 이미 띄운다. 별도 서비스를 하나 더 돌리면
  위치 스트림이 두 프로세스로 갈라져 샘플이 중복/유실된다.
- **iOS**: 백그라운드 실행 자체가 불가능하고, `UIBackgroundModes=location` +
  `allowBackgroundLocationUpdates`로 위치 콜백만 계속 받는 구조다.
  `flutter_background_service`가 할 수 있는 일이 없다.

의존성 제거는 pubspec 변경이라 이번 작업 범위 밖으로 뒀다. 정리 시 삭제 후보다.

### 4.5 권한 요청 흐름 (`ensureReady()`)

1. 위치 서비스 자체가 꺼져 있으면 → `Failure.serviceDisabled(service:'location')`.
2. `locationWhenInUse` 요청 → 거부 시 `Failure.permissionDenied`
   (`permanentlyDenied` 플래그 포함 → UI가 설정 앱 안내를 띄울 근거).
3. `locationAlways` 승격 요청 → **실패해도 던지지 않는다.**
   `hasBackgroundLocationPermission=false`로 두고 포그라운드 전용으로 우아하게 저하.
   이 값이 false면 Android 포그라운드 알림도 띄우지 않는다(어차피 백그라운드
   위치가 안 오는데 상시 알림만 남는 상황 방지).

처음부터 "항상 허용"을 요청하지 않는 이유는 iOS/Android 모두 거부율이 급등하기
때문이다(스킬 §2).

---

## 5. flutter-ui-designer가 구독할 provider 계약 ★

전부 `lib/features/tracking/data/tracking_providers.dart`에 있다.

| provider | 타입 | 용도 |
|----------|------|------|
| `trackingControllerProvider` | `AsyncNotifierProvider<TrackingController, RunRecord?>` | 명령 계층. `start/pause/resume/stop/discard` |
| `activeRunProvider` | `StreamProvider<RunRecord>` | 진행 중 누적 상태. **1초마다** 갱신 |
| `liveRunSampleProvider` | `StreamProvider<RunSample>` | 새 GPS 샘플 1건. 지도 폴리라인 **증분** 연장용 |
| `runCompletedProvider` | `StreamProvider<RunRecord>` | 러닝 종료 이벤트(뱃지 판정/업로드 후처리용) |
| `interruptedRunProvider` | `FutureProvider<RunRecord?>` | 앱 재시작 시 복구 가능한 미완결 세션 |
| `trackingProfileProvider` | `StateProvider<TrackingProfile>` | 배터리↔정확도 설정 |
| `runTrackingServiceProvider` | `Provider<RunTrackingService>` | 엔진 본체. 보통 직접 구독하지 않는다 |

사용 예:

```dart
final run = ref.watch(activeRunProvider).valueOrNull;
Text(run == null ? '0.00' : (run.distanceMeters / 1000).toStringAsFixed(2));

final controller = ref.read(trackingControllerProvider.notifier);
await controller.start();               // 권한 요청 + 세션 시작
final record = await controller.stop(); // 로컬 저장 + 업로드 시도 + 종료 이벤트
```

**UI가 반드시 처리해야 할 것**

1. `trackingControllerProvider`가 `AsyncError(Failure.permissionDenied)`이면
   권한 안내. `permanentlyDenied=true`면 "설정 열기" 버튼.
2. `activeRunProvider`는 **에러도 흘린다**(`Failure.serviceDisabled`).
   러닝 도중 위치 서비스가 꺼진 경우다. 세션은 유지되고 누적값은 보존된다.
3. **Garmin 지연 안내.** `GeolocatorRunTrackingService.usesDelayedWearableSync`가
   true면 "워치 데이터는 Garmin Connect 동기화 후 반영됩니다" 배너를 띄운다.
4. **워치 미연동은 에러가 아니다.** 폰 단독 트래킹으로 조용히 폴백한다.
   필요하면 `wearableConnected`로 "폰으로 기록 중" 정도만 알린다.
5. `activeRunProvider`의 `RunRecord.samples`는 **항상 비어 있다**(의도적).
   경로는 `liveRunSampleProvider`로 증분 누적하거나 `routePolyline`을 쓴다.

### 5.1 gamification / backend 연결점

- **gamification-designer**: `runCompletedProvider`를 `ref.listen`으로 구독한다.
  이벤트에 최종 `RunRecord` 전체가 실리므로 뱃지 판정이 다시 계산할 필요가 없다.
  발행 시점은 **로컬 저장이 끝난 뒤**다 — 아직 저장 안 된 기록으로 판정하는
  상황을 막기 위해서다.
- **backend-engineer**: 업로드는 `LocalRunRepository`가 담당한다.
  완료 기록만 즉시 단건 `upsert`(id = 클라이언트 UUID v4라 멱등),
  실패분은 `syncPending()` 배치 재시도. 진행 중 체크포인트는 서버로 보내지 않는다.
  payload에서 `avg_pace_sec_per_km` / `awarded_points` / `created_at` /
  `updated_at`은 제거한다(서버 소유).

---

## 6. 워치 연동 현황

- **Apple Watch**: HealthKit에 거의 실시간으로 쓰이므로 지연 수 초.
  `RunSampleSource.watch`.
- **Garmin**: Garmin Connect 앱이 HealthKit/Health Connect로 **동기화한 뒤에야**
  보인다. 러닝 중에는 대개 아무것도 안 보인다. `sourceName`에 `garmin`이 들어가면
  `RunSampleSource.external`로 표기해 소비 측이 실시간이 아님을 구분한다.
  실시간이 꼭 필요해지면 Garmin Health API 직접 연동(개발자 승인 필요)이
  후속 단계다 — MVP는 동기화 경유.
- **왜 폴링인가**: HealthKit도 Health Connect도 "지금 이 순간의 심박수"를 밀어주는
  공개 스트림 API가 없다. 둘 다 저장소이고 워치가 쓴 값을 폰이 읽는 구조다.
  10초 주기로 최근 60초를 조회해 최신 데이터포인트를 취한다.
- 심박/케이던스는 **별도 모델을 만들지 않고** 다음 GPS fix에 얹어 `RunSample`로
  합류시킨다(모델 통합 원칙). 좌표 없는 샘플이 대량으로 끼면 경로/차트 소비 측이
  전부 null 체크를 해야 하기 때문이다.

---

## 7. 검증 결과와 한계

### 통과한 것

- `dart analyze` — 이슈 0건.
- `flutter test` — 22개 전부 통과(트래킹 8개 포함).
  - 정지 5분 → 누적 거리 < 5m (시드 5종 반복 검증)
  - 일정 속도 러닝 → 실제 거리 5% 오차 이내 복원
  - 신호등 90초 정지 → 정지 구간 미누적, 전체 합계 오차 1% 이내
  - 정확도 불량/순간이동 fix 폐기
  - 일시정지 중 거리·이동시간 불변, 재개 시 몰아넣기 없음
  - elapsed/moving/페이스 관계, 고도 데드밴드, 워치 심박 합류
- `dart run build_runner build` — drift/freezed 생성 코드 최신 상태.

### 이 환경에서 검증하지 못한 것 (한계)

1. **실기기 GPS 정확도.** 시뮬레이터는 실제 GNSS 노이즈를 재현하지 못한다.
   임계값은 합성 로그 + 문헌값 기준이므로, **실기기 필드 테스트에서
   §2.3 표의 값을 재조정해야 한다.** 특히 `stationaryExitMeters`(8m)는
   출발 반응 속도와 직결되므로 체감 확인이 필요하다.
2. **백그라운드 트래킹.** 화면 꺼짐/앱 백그라운드에서의 위치 콜백 유지는
   실기기에서만 확인 가능하다. Android는 제조사별 배터리 정책(샤오미/화웨이 등)이
   포그라운드 서비스를 죽이는 사례가 있어 기기별 확인이 필요하다.
3. **HealthKit 실데이터.** Runner.entitlements가 아직 Xcode 타겟에 연결되지
   않았고(§4.2), 시뮬레이터에는 Apple Watch 심박 데이터가 없다.
4. **로그인 상태의 트래킹 화면.** 라우터 가드 때문에 카카오 로그인 없이는
   트래킹 화면에 진입할 수 없다. 세션을 인위적으로 심는 방식은 쓰지 않았다.

### 후속 작업 제안

- [ ] Xcode에서 HealthKit Capability 추가(§4.2) — 워치 연동 전제 조건
- [ ] 실기기 필드 테스트 후 §2.3 임계값 재조정
- [ ] `flutter_background_service` 의존성 제거 검토(§4.4)
- [ ] Android 제조사별 배터리 최적화 예외 안내 UI

## 8. 업로드 실패 재시도 누락 수정 (2026-08-21)

**발견 경위**: "실기기로 설치하면 DB에 데이터가 정상적으로 쌓이는가"를 점검하던 중,
`LocalRunRepository.save()`가 러닝 종료 시 서버 업로드를 **딱 한 번만** 시도하고,
실패하면 로컬에 `SyncStatus.failed`로 남긴 뒤 그대로 방치한다는 걸 확인했다.
`RunRepository.syncPending()`(재시도용으로 이미 정의돼 있던 메서드)을 **앱 어디서도
호출하지 않고 있었다** — 인터페이스와 구현체 두 곳 말고는 참조가 0건. 지금까지
시뮬레이터 + 안정적인 Mac Wi-Fi 환경에서만 테스트해서 첫 시도가 항상 성공했기 때문에
드러나지 않았을 뿐, 실외 실기기 환경(러닝 종료 시점에 신호가 불안정할 수 있음)에서는
로컬에만 남고 서버 DB에는 영원히 안 올라가는 기록이 실제로 생길 수 있는 구조였다.

**수정**: [run_sync_coordinator.dart](../lib/core/sync/run_sync_coordinator.dart) 신설.
연결 상태를 직접 감지하는 패키지(connectivity_plus 등)를 새로 추가하는 대신, 이미
있는 신호 3가지로 재시도 시점을 커버했다:
1. 로그인 성공 시(`currentUserIdProvider` null→non-null 전이)
2. 앱이 백그라운드→포그라운드로 돌아올 때(`AppLifecycleListener.onResume`) — 신호
   없다가 회복되는 가장 흔한 패턴
3. 앱이 켜져 있는 동안의 주기 폴백(2분 `Timer.periodic`)

[app.dart](../lib/app.dart)의 `RunnitApp.build()`에서 `ref.watch(runSyncCoordinatorProvider)`로
한 번 읽어 앱 수명 동안 계속 살아있게 했다(autoDispose가 아니므로 계속 유지).
`dart analyze` clean, `flutter test` 56/56 통과, 시뮬레이터 재기동해 크래시/회귀 없음 확인.

**한계**: 여전히 "네트워크가 끊긴 순간을 즉시 감지"하지는 못한다(최대 2분 폴백 지연,
또는 앱을 다시 열 때까지). 진짜 즉시성이 필요해지면 그때 `connectivity_plus`를
추가하는 게 맞다 — 지금 단계에서는 과한 의존성이라 판단해 뺐다.
