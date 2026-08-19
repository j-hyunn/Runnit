# Garmin 연동

Garmin은 이 앱의 웨어러블 우선 지원 대상(Apple Watch와 동급)이지만, Apple Watch와 달리 **기기와 직접 통신하지 않는다**. 연동 방식을 단계별로 나눠 접근한다.

## 1단계 (MVP 권장): Garmin Connect 동기화 경유

Garmin 워치는 러닝을 기록하면 Garmin Connect 앱(사용자가 이미 설치했을 가능성이 높음)으로 데이터를 보낸다. Garmin Connect는 설정에서 아래 동기화를 켤 수 있다:
- iOS: "Apple 건강"(Apple Health) 동기화 → HealthKit에 기록됨 → [ios-healthkit.md](ios-healthkit.md)의 "Garmin 데이터도 이 경로로 들어온다" 참조
- Android: Health Connect 동기화 → [android-health-connect.md](android-health-connect.md)의 동일 섹션 참조

**장점:** 별도 Garmin SDK 통합이나 개발자 승인 없이, 이미 구현한 HealthKit/Health Connect 경로만으로 Garmin을 지원할 수 있다.
**단점:** 실시간이 아니다 — Garmin 워치가 Garmin Connect 앱과 블루투스 동기화를 마쳐야 데이터가 넘어온다(보통 러닝 종료 후 수 분 이내). 러닝 도중 실시간 지도 표시는 여전히 폰 GPS(§ SKILL.md 본문)에 의존해야 한다.
**사용자 안내:** "워치 심박수/거리 데이터는 Garmin Connect 동기화 후 반영됩니다" 같은 문구를 기록 상세 화면에 노출해, 데이터가 늦게 채워지는 것을 버그로 오인하지 않게 한다.

## 2단계 (고급, MVP 이후 검토): Garmin Health API 직접 연동

실시간성이 꼭 필요해지면 Garmin Health API(구 Garmin Health SDK)를 통해 Garmin 서버로부터 활동 데이터를 웹훅/폴링으로 직접 받을 수 있다.
- Garmin Developer Program 가입 및 앱 승인이 필요하다 (즉시 사용 불가, 심사 기간 소요)
- OAuth 기반 사용자 연동 플로우 별도 구현 필요
- 실시간 스트리밍이 아니라 "활동 종료 후 웹훅 푸시" 방식에 가까워, 완전한 실시간(러닝 중 초 단위) 연동을 기대한다면 여전히 폰 GPS가 주 데이터 소스여야 한다

**권장:** 1단계로 시작하고, 실제 사용자 피드백에서 동기화 지연이 문제가 될 때 2단계를 검토한다. 초기부터 Garmin Health API 심사를 기다리며 개발을 지연시키지 않는다.

## Apple Watch와의 소스 구분

`RunSample.source`에 `watch` 단일 값 대신 워치 브랜드를 구분해야 하는지는 게이미피케이션(기기별 뱃지 등) 요구가 있을 때만 고려한다. HealthKit/Health Connect 경로에서는 `sourceRevision`/`dataOrigin`으로 기록 출처(Apple Watch 자체 vs Garmin Connect 경유)를 이미 구분할 수 있으므로, 모델 확장이 필요하면 mobile-architect에게 이 구분 정보를 전달한다.
