# iOS — 백그라운드 위치 + HealthKit

## 백그라운드 위치 추적

`Info.plist`에 `NSLocationAlwaysAndWhenInUseUsageDescription`을 선언하고, Background Modes capability에서 `Location updates`를 활성화한다.

권한 요청은 반드시 단계적으로 진행한다:
1. 먼저 "앱 사용 중 허용"(`whenInUse`)만 요청
2. 러닝 시작 시점에 "항상 허용"으로 승격 요청 (`requestAlwaysAuthorization`) — 앱 최초 실행 시 바로 "항상 허용"을 요청하면 시스템이 거부 확률이 높은 것으로 간주해 다이얼로그 문구가 더 강경해진다

`CLLocationManager`의 `allowsBackgroundLocationUpdates = true`와 `pausesLocationUpdatesAutomatically = false`(러닝 중 정지 시 시스템이 자동으로 추적을 멈추지 않도록)를 함께 설정한다.

## HealthKit 연동 (Apple Watch)

```
1. Info.plist에 NSHealthShareUsageDescription, NSHealthUpdateUsageDescription 선언
2. HKHealthStore 권한 요청: HKQuantityType(.heartRate, .distanceWalkingRunning), HKWorkoutType
3. watchOS 컴패니언 앱이 있는 경우: WCSession으로 워치-폰 실시간 통신, 없는 경우 HKWorkoutSession으로 기록된 운동을 HealthKit에서 사후 조회
4. 워치 단독으로 운동을 기록하는 사용자를 위해, HKObserverQuery로 신규 워크아웃 저장을 구독해 자동으로 앱에 반영하는 것도 고려
```

## Garmin 데이터도 이 경로로 들어온다

Garmin Connect 앱에서 "Apple 건강" 동기화를 켠 사용자는 Garmin 워치의 운동 기록(거리, 심박수, GPS 경로)이 자동으로 HealthKit에 저장된다. 즉 3번 항목(HKWorkoutSession 사후 조회)의 쿼리 대상을 Apple Watch로 한정하지 않고 모든 워크아웃 소스를 포함하도록 구현하면, 별도 Garmin 전용 코드 없이 Apple Watch와 Garmin을 동시에 지원할 수 있다. `HKWorkout`의 `sourceRevision.source.name`으로 어느 앱이 기록했는지(Garmin Connect vs 자체 앱) 구분 가능하다.

## watchOS 컴패니언 앱 (선택적 고급 기능)

전용 watchOS 앱을 만들면 워치 화면에서 직접 러닝을 시작/종료하고, `WCSession`으로 실시간 데이터를 폰에 전송할 수 있다. 이는 별도 프로젝트 타겟이 필요한 큰 작업이므로, 초기 버전에서는 HealthKit을 통한 사후 데이터 조회(3번 항목)로 시작하고 컴패니언 앱은 후속 단계로 분리하는 것을 권장한다.

## 알려진 함정

- HealthKit 권한은 "거부됨"과 "아직 묻지 않음"을 앱이 구분할 수 없다(사생활 보호를 위한 iOS 설계) — 권한 상태에 의존한 UI 분기 대신, 실제 데이터 조회 결과가 비어있을 때의 폴백 UI를 항상 준비한다
- 시뮬레이터에서는 HealthKit이 일부 제한적으로 동작하므로 실기기 테스트가 필요하다
