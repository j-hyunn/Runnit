# Android — 백그라운드 위치 + Health Connect

## 백그라운드 위치 추적

Android 10+ 부터 백그라운드 위치 권한(`ACCESS_BACKGROUND_LOCATION`)이 포그라운드 위치 권한과 분리되어 있다. 매니페스트에 별도로 선언하고, 런타임 요청도 별도 다이얼로그로 진행해야 한다.

러닝 세션 중 앱이 백그라운드로 가도 추적이 끊기지 않으려면 **Foreground Service**를 사용한다 (`flutter_foreground_task` 또는 `geolocator`의 백그라운드 모드 활용):
- 알림(notification)을 상시 표시해 사용자가 추적 중임을 인지하게 한다 (Android 정책상 필수)
- Doze 모드/앱 대기 최적화(App Standby Buckets)로 인해 서비스가 시스템에 의해 종료될 수 있으므로, 배터리 최적화 제외 요청(`requestIgnoreBatteryOptimizations`)을 러닝 시작 시 안내한다

## Health Connect 연동

Health Connect는 Android의 통합 헬스 데이터 저장소로, Wear OS 워치의 GPS/심박수 데이터를 읽어오는 표준 경로다.

```
1. Health Connect 앱 설치 여부 확인 (Android 14+는 OS 내장, 이전 버전은 별도 앱)
2. 권한 요청: READ_HEART_RATE, READ_DISTANCE, READ_EXERCISE 등
3. Wear OS 워치에서 운동을 기록하는 앱(Google Fit, 삼성 Health 등)이 Health Connect에 데이터를 쓰고 있어야 함
4. 러닝 세션 진행 중 실시간 스트리밍이 아니라, 세션 종료 후 해당 시간대의 심박수/거리 데이터를 조회해 RunRecord에 병합하는 방식이 안정적
   (Health Connect는 실시간 스트림 API가 제한적이므로, 실시간성이 필요한 위치는 geolocator로 별도 수집)
```

## Garmin 데이터도 이 경로로 들어온다

Garmin Connect 앱이 Health Connect 동기화를 지원하는 Android 버전에서는, 사용자가 Garmin Connect 설정에서 Health Connect 연동을 켜면 Garmin 워치의 운동 기록이 Health Connect에 그대로 쓰인다. 3번 항목의 조회 로직에서 데이터 출처 앱을 필터링하지 않으면 Wear OS 기기와 Garmin을 같은 코드로 함께 지원하게 된다. `ExerciseSessionRecord`의 메타데이터에서 기록을 생성한 앱(`dataOrigin`)을 확인하면 Garmin Connect 유래 데이터를 구분할 수 있다.

## 알려진 함정

- 제조사별 배터리 관리 정책(Xiaomi, Huawei 등)이 공격적으로 백그라운드 프로세스를 종료시키는 경우가 있다 — 완벽한 해결책은 없으므로, 세션 재개(앱 재실행 시 진행 중이던 세션 복구) 로직을 반드시 구현한다
- Health Connect 권한은 세밀하게 나뉘어 있어(데이터 타입별) 필요한 것만 요청 — 과도한 권한 요청은 사용자 거부율을 높인다
