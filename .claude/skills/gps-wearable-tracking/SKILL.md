---
name: gps-wearable-tracking
description: "Flutter 러닝 앱의 GPS 위치 추적 및 웨어러블(Apple Watch·Garmin 우선, HealthKit/Health Connect) 연동 구현 워크플로우. 권한 처리, 백그라운드 추적, GPS 스무딩, 거리/페이스/칼로리 계산을 다룬다. 'GPS 트래킹 구현', '워치 연동', '애플워치 연동', '가민 연동', '백그라운드에서 기록 유지', '거리 계산 이상함' 요청 시 사용."
---

# GPS·웨어러블 트래킹 구현

폰 GPS와 웨어러블 센서로 러닝을 정확하게 기록하는 절차.

## 1. 전체 흐름

```
권한 요청 → 위치 스트림 시작(포그라운드 서비스) → 원시 RunSample 수집
  → 스무딩/이상치 제거 → 거리·페이스·칼로리 계산 → RunRecord 조립 → 세션 종료 이벤트 발행
```

## 2. 권한 처리

권한 요청은 단계적으로 한다 — 한 번에 "항상 허용"을 요청하면 iOS/Android 모두 거부율이 높아진다:
1. 앱 사용 중 위치 권한 요청 (`when in use`)
2. 백그라운드 트래킹이 실제로 필요한 시점(러닝 시작 버튼)에 "항상 허용" 승격 요청
3. 웨어러블 연동은 별도로 Health Connect/HealthKit 권한을 요청 (위치 권한과 별개 플로우)

플랫폼별 상세 API는 필요한 쪽만 로드한다:
- Android 구현 세부사항(Foreground Service, Health Connect — Garmin/Wear OS 공통 경로) → [references/android-health-connect.md](references/android-health-connect.md)
- iOS 구현 세부사항(Background Modes, HealthKit — Apple Watch 네이티브 + Garmin 동기화 경로) → [references/ios-healthkit.md](references/ios-healthkit.md)
- Garmin 특화 사항(Garmin Connect 동기화 설정, Garmin Health API 개요) → [references/garmin-integration.md](references/garmin-integration.md)

## 3. 웨어러블 우선순위와 연동 경로

이 앱은 Apple Watch와 Garmin을 우선 지원 대상으로 한다. 두 기기는 연동 경로 자체가 다르므로 구분해서 설계한다.

| 기기 | 연동 경로 | 실시간성 | 우선순위 |
|------|----------|----------|----------|
| Apple Watch | HealthKit 네이티브 (`HKWorkoutSession`, 필요 시 watchOS 컴패니언 앱) | 높음 | 1순위 |
| Garmin | Garmin Connect 앱이 사용자 설정에 따라 HealthKit(iOS)/Health Connect(Android)에 운동 데이터를 동기화 → 앱은 그 경로로 읽음 | 낮음(동기화 지연) | 1순위 (경로는 다르지만 지원 우선순위는 Apple Watch와 동급) |
| 기타 Wear OS 기기 | Health Connect | 중간 | 2순위 |

**핵심:** Garmin은 기기와 직접 통신하는 것이 아니라 Garmin Connect의 동기화를 경유한다. 즉 iOS에서는 HealthKit 연동을, Android에서는 Health Connect 연동을 이미 구현했다면 Garmin 지원은 대부분 "추가로 얻어지는" 것에 가깝다 — 별도의 Garmin 전용 SDK 통합 없이도 동작한다. 실시간성이 부족한 점(동기화 지연)만 UI에 명시하면 된다. 완전한 실시간 연동이 꼭 필요해지는 시점에는 Garmin Health API(개발자 승인 필요) 직접 연동을 검토하되, MVP에서는 권장하지 않는다. 상세: [references/garmin-integration.md](references/garmin-integration.md)

워치가 연결되지 않았거나 사용자가 폰만 소지한 경우, 폰 GPS 단독 트래킹으로 자동 폴백한다. 이것은 에러가 아니라 정상 경로다 — 워치 연동을 필수 요구사항처럼 처리해 트래킹 자체를 막지 않는다. `RunSample.source`를 `phone`/`watch`로 표시해 두면, 이후 세션에서 데이터 출처를 구분할 수 있다(§ mobile-architect의 `RunSample` 모델 참조). Garmin과 Apple Watch를 소스 값으로 더 세분화할지(`watch:apple` vs `watch:garmin`)는 뱃지/통계에서 기기별 구분이 필요한지에 따라 mobile-architect와 협의한다.

## 4. GPS 스무딩 — 왜 필요한가

GPS 원시 좌표는 실내/도심에서 실제 위치보다 수 미터~수십 미터 벗어난 값을 반환할 수 있다. 스무딩 없이 연속된 두 좌표 간 직선거리를 그대로 누적하면, 사용자가 정지해 있어도 GPS 드리프트로 거리가 계속 증가하는 버그가 생긴다. 반드시 필터링 후 거리를 계산한다. 알고리즘 상세와 이상치 판정 기준은 [references/gps-smoothing.md](references/gps-smoothing.md) 참조.

## 5. 배터리 최적화

GPS 폴링 주기와 정확도(`LocationAccuracy`)는 배터리 소모와 직결된다. 다음을 사용자 설정으로 노출하는 것을 권장한다:

| 모드 | 정확도 | 폴링 주기 | 용도 |
|------|--------|----------|------|
| 고정밀 | best | 1~2초 | 대회/기록 갱신용 러닝 |
| 표준 | high | 5초 | 일반 러닝 |
| 절전 | medium | 10초+ | 장거리(마라톤) |

## 6. 거리/페이스/칼로리 계산

- 거리: 스무딩된 연속 포인트 간 Haversine 공식 누적
- 페이스: `duration / distance_km` (분/km), 구간별(1km 단위 split) 계산도 함께 제공하면 gamification/UI 양쪽에서 유용
- 칼로리: MET(Metabolic Equivalent) 기반 추정 — 정확한 값이 아니라 추정치임을 UI에서 명시 (심박수 데이터가 있으면 더 정교한 추정 가능)

## 7. 산출물

`RunRecord` 조립이 끝나면 세션 종료 이벤트를 발행한다 — gamification-designer의 뱃지 판정과 backend-engineer의 업로드 로직이 이 이벤트를 구독한다. 이벤트에는 최종 `RunRecord` 전체(또는 그 ID)를 포함해, 구독 측이 다시 계산할 필요가 없도록 한다.
