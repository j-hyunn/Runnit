---
name: flutter-architecture-setup
description: "Flutter 러닝 앱의 프로젝트 구조, 상태관리(Riverpod), 핵심 데이터 모델(freezed) 설계 워크플로우를 제공. RunRecord/RunSample/User/Badge/RankingEntry 등 엔티티 설계, feature-first 폴더 컨벤션, 패키지 선정 기준을 다룬다. '프로젝트 구조 잡아줘', '상태관리 뭐 쓸지', '데이터 모델 설계' 같은 요청 시 반드시 사용."
---

# Flutter 아키텍처 셋업

Flutter 러닝 앱의 뼈대(폴더 구조, 상태관리, 데이터 모델)를 설계하는 절차.

## 1. 폴더 구조 — feature-first

레이어 우선(전체를 `models/`, `screens/`, `services/`로 나누는 방식)보다 기능 우선 구조를 쓴다. 러닝 앱처럼 기능 영역(트래킹/게이미피케이션/백엔드/UI)을 여러 전문가가 병렬로 작업할 때, 레이어 우선 구조는 서로 다른 기능의 코드가 같은 폴더에서 충돌하기 쉽다.

```
lib/
  core/                    # 공통 유틸, 라우터, 테마, DI
  models/                  # 공유 데이터 모델 (mobile-architect 담당)
    run_sample.dart
    run_record.dart
    user.dart
    badge.dart
    ranking_entry.dart
  features/
    tracking/               # gps-tracking-engineer
      data/ domain/ presentation/
    gamification/           # gamification-designer
      data/ domain/ presentation/
    ranking/
    profile/
  core/api/                 # backend-engineer가 만드는 Supabase 클라이언트
```

각 `features/{name}/` 하위는 `data`(외부 연동) / `domain`(비즈니스 로직) / `presentation`(위젯)으로 나눈다. 이렇게 나누면 flutter-ui-designer가 `presentation/`만, backend-engineer가 `data/`만 건드리게 되어 파일 충돌이 줄어든다.

## 2. 상태관리 — Riverpod을 기본값으로

컴파일 타임 안전성(Provider 오타를 빌드 시점에 잡음), 테스트 용이성(Provider override로 목킹이 쉬움), 그리고 GPS 스트림처럼 백그라운드에서 갱신되는 상태를 여러 화면이 구독해야 하는 이 앱의 특성과 잘 맞는다.

- `StreamProvider`: GPS 위치 스트림, 실시간 랭킹 구독
- `NotifierProvider`: 러닝 세션 상태(진행중/일시정지/종료), 뱃지 획득 큐
- `FutureProvider`: 히스토리 조회, 리더보드 조회 등 1회성 비동기 데이터

사용자가 이미 다른 상태관리(Bloc, Provider 등)를 지정했다면 그것을 따른다 — Riverpod은 근거가 있는 기본값이지, 강제 사항이 아니다.

## 3. 핵심 데이터 모델

freezed + json_serializable로 불변 모델과 직렬화를 자동 생성한다. 수동 `toJson`/`fromJson`은 필드 추가 시 누락되기 쉽다.

```dart
@freezed
class RunSample with _$RunSample {
  const factory RunSample({
    required double lat,
    required double lng,
    required DateTime timestamp,
    double? altitude,
    int? heartRate,       // 웨어러블 연동 시에만 존재
    required RunSampleSource source, // phone | watch
  }) = _RunSample;
}

@freezed
class RunRecord with _$RunRecord {
  const factory RunRecord({
    required String id,
    required String userId,
    required DateTime startedAt,
    required DateTime endedAt,
    required double distanceMeters,
    required Duration duration,
    required List<RunSample> samples,
    int? avgHeartRate,
  }) = _RunRecord;
}
```

**핵심 원칙: 폰 GPS와 워치 센서 데이터를 하나의 `RunSample`로 통합한다.** `source` 필드로만 구분한다. 소스별로 별도 모델(`PhoneRunSample`, `WatchRunSample`)을 만들면 게이미피케이션·백엔드·UI 세 곳 모두에서 소스 분기 처리가 중복된다.

다른 핵심 모델:
- `User` — 프로필, 누적 통계(총 거리, 총 러닝 횟수) 캐시 필드 포함 여부는 배치 재계산 비용과 트레이드오프
- `Badge` (카탈로그) / `UserBadge` (획득 기록, 획득 시각 포함)
- `RankingEntry` — 기간(period), 순위, 점수, tie-break 기준값

## 4. 패키지 선정 기준

| 목적 | 권장 패키지 | 비고 |
|------|-----------|------|
| GPS | `geolocator` | 백그라운드 지원, 정확도 옵션 |
| 웨어러블 센서 | `health` | HealthKit/Health Connect 통합 래퍼 |
| 권한 | `permission_handler` | iOS/Android 권한 흐름 통합 |
| 상태관리 | `flutter_riverpod` + `riverpod_generator` | §2 참조 |
| 불변 모델 | `freezed` + `json_serializable` | §3 참조 |
| 라우팅 | `go_router` | 딥링크, 중첩 라우트 |
| 지도 | `flutter_map`(오픈소스, 비용 없음) 또는 `google_maps_flutter`(더 정교한 UX, API 키 필요) | 예산/UX 요구사항에 따라 선택 |
| 차트 | `fl_chart` | 페이스/거리 추이 시각화 |
| 백엔드 | Supabase (`supabase_flutter`) | 이 환경에 Supabase MCP가 연결되어 있으므로 backend-engineer와 합의 |

## 5. 모듈 인터페이스 원칙

GPS 트래킹 모듈은 백엔드/게이미피케이션 모듈에 직접 의존하지 않고, `RunRecord`를 스트림/콜백으로 방출하는 형태로 추상화한다. 이렇게 하면 트래킹 로직을 게이미피케이션 로직과 독립적으로 테스트할 수 있고, 향후 트래킹 소스가 늘어나도(예: 러닝머신 연동) 하위 모듈 수정이 필요 없다.
