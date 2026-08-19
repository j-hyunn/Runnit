---
name: flutter-ui-patterns
description: "Flutter 러닝 앱의 화면 구현 패턴 — 실시간 트래킹 화면 성능 최적화, 지도/차트 위젯, 뱃지 획득 연출, 디자인 토큰, 빈/로딩/에러 상태 처리. '트래킹 화면 만들어줘', '랭킹 UI', '뱃지 갤러리', '지도에 경로 그리기' 요청 시 사용."
---

# Flutter UI 패턴 — 러닝 앱

러닝 앱의 화면을 구현할 때 따르는 패턴.

## 1. 실시간 트래킹 화면 — 리빌드 범위 좁히기

GPS는 초 단위로 갱신되므로, 화면 전체를 하나의 `Consumer`로 감싸면 매 업데이트마다 지도까지 다시 그려져 프레임이 드랍된다. 갱신 빈도가 다른 영역을 분리한다:

```dart
Column(
  children: [
    Consumer(builder: (_, ref, __) {
      final position = ref.watch(currentPositionProvider); // 초 단위 갱신
      return MapWidget(position: position);
    }),
    Consumer(builder: (_, ref, __) {
      final stats = ref.watch(runStatsProvider); // 거리/페이스, 마찬가지로 자주 갱신되지만 지도와 별도 위젯이므로 지도 리페인트와 분리됨
      return StatsPanel(stats: stats);
    }),
  ],
)
```

지도 위젯 자체도 매 프레임 전체 폴리라인을 재계산하지 않도록, 신규 포인트만 추가하는 방식(`addLatLng`류 API)을 우선 사용한다.

## 2. 지도 경로 시각화

- `flutter_map`: 오픈소스, API 키 불필요, 폴리라인 레이어로 경로 표시
- `google_maps_flutter`: 더 정교한 UX(3D, 실내지도)가 필요하면 선택, API 키 및 비용 발생

경로 폴리라인은 gps-tracking-engineer가 스무딩한 `RunSample` 리스트를 그대로 사용한다 — 원시 GPS 포인트를 다시 그리면 지도에 지그재그가 나타난다.

## 3. 차트/통계 시각화

`fl_chart`로 페이스/거리 추이를 표현할 때:
- 축 라벨은 세션 수가 많아질수록 겹치므로 동적으로 간격을 조정한다
- 빈 데이터(첫 러닝 이전)에는 빈 상태 UI를 먼저 보여주고 차트를 렌더링하지 않는다

## 4. 뱃지 획득 연출

뱃지는 게이미피케이션의 핵심 보상 지점이므로 단순 토스트로 처리하지 않는다:
- 전체 화면 오버레이 + 스케일 애니메이션으로 "성취"를 명확히 표현
- 여러 뱃지가 동시에 획득되면 큐에 넣어 순차적으로 보여준다 (동시에 여러 다이얼로그가 겹치지 않도록)
- 획득한 뱃지 데이터는 gamification-designer가 정의한 `UserBadge` 모델의 실제 필드명(`earnedAt` 등)을 그대로 사용 — 임의로 필드를 재정의하지 않는다

## 5. 랭킹/리더보드 화면

- 본인 순위는 리스트 상단에 고정 노출(스크롤 없이 항상 보이도록) — 사용자가 자신의 순위를 확인하기 위해 스크롤하게 만들지 않는다
- 순위 변동(상승/하락)을 화살표/색상으로 표시하려면 이전 랭킹 스냅샷과 비교가 필요함을 backend-engineer와 사전 협의
- 데이터 갱신 시각(리더보드 캐시가 몇 분 전 데이터인지)을 명시해 사용자 혼란을 줄인다

## 6. 디자인 토큰

`_workspace/{date}_ui_design_tokens.md`에 색상/타이포/spacing을 정의하고 `ThemeData`/`ThemeExtension`으로 앱 전체에 적용한다. 게이미피케이션 요소(뱃지 등급별 색상: bronze/silver/gold)는 토큰에 포함시켜 일관성을 유지한다.

## 7. 상태 처리 원칙

모든 데이터 기반 화면은 로딩/에러/빈 상태를 정상 상태와 함께 구현한다:

```dart
data.when(
  data: (records) => records.isEmpty
      ? const EmptyRunHistoryView()
      : RunHistoryList(records: records),
  loading: () => const RunHistorySkeleton(),
  error: (e, _) => RunHistoryErrorView(onRetry: () => ref.refresh(...)),
)
```
