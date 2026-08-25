# Runnit UI 디자인 토큰

작성: flutter-ui-designer / 2026-08-20
구현 위치: `lib/core/theme/app_tokens.dart` (상수 토큰), `lib/core/theme/app_theme.dart` (ThemeData)

---

## 1. 두 파일의 역할 분담

| 파일 | 담당 | 수정 주체 |
|------|------|-----------|
| `app_theme.dart` | `ColorScheme.fromSeed(seed: #00C853)` 기반 M3 테마, AppBar 테마 | 기존 유지 — 이번 작업에서 **변경하지 않음** |
| `app_tokens.dart` | 테마로 표현되지 않는 상수(spacing/radius/브랜드색/등급색) | flutter-ui-designer |

색은 원칙적으로 `Theme.of(context).colorScheme`에서 가져온다. `AppTokens`의 색은
**테마 색으로 대체할 수 없는 것만** 담는다(카카오 브랜드색, 뱃지 등급색).

---

## 2. Spacing — 4pt 그리드

`AppTokens.s4 / s8 / s12 / s16 / s20 / s24 / s32 / s40`

| 용도 | 값 |
|------|-----|
| 아이콘↔텍스트 간격 | `s8` |
| 리스트 아이템 내부 패딩 | `s12` |
| 화면 좌우 여백 | `s16` (로그인처럼 여백이 중요한 화면은 `s24`) |
| 섹션 간 간격 | `s20` ~ `s24` |
| 브랜드 헤더 아래 | `s32` |

화면 코드에 매직 넘버(패딩 17, 13...)를 쓰지 않는다.

## 3. Radius

| 토큰 | 값 | 용도 |
|------|-----|------|
| `rSm` | 8 | 스켈레톤 바 |
| `rMd` | 12 | 버튼, 리스트 타일, 배너 |
| `rLg` | 16 | 카드, 유도 배너 |
| `rPill` | 999 | 진행률 바, StadiumBorder 대체 |

## 4. 레이아웃 상수

| 토큰 | 값 | 의미 |
|------|-----|------|
| `contentMaxWidth` | 480 | 폰보다 넓은 화면(폴더블/태블릿)에서 본문이 과하게 늘어나지 않게 제한 |
| `minTapTarget` | 48 | 터치 타겟 최소 높이(iOS 44 / Material 48 중 큰 값) |

반응형 규칙:
- 로그인 화면은 `LayoutBuilder` + `SingleChildScrollView` + `minHeight` 조합.
  SE급 소형 화면에서도 잘리지 않고, 큰 화면에서는 세로 중앙 정렬을 유지한다.
- 뱃지 그리드는 고정 열 수가 아니라 `SliverGridDelegateWithMaxCrossAxisExtent(132)`.
  화면 폭에 따라 3~5열로 자동 조정된다.

## 5. 브랜드 색

| 토큰 | 값 | 규칙 |
|------|-----|------|
| `AppTheme.seed` | `#00C853` | 앱 전체 ColorScheme 시드 (기존 유지) |
| `AppTokens.kakaoYellow` | `#FEE500` | 카카오 로그인 버튼 배경. **테마와 무관하게 고정** |
| `AppTokens.kakaoLabel` | `#191919` | 카카오 버튼 라벨/심볼 |

카카오 버튼은 앱에서 유일하게 테마 색을 쓰지 않는 버튼이다 — 소셜 로그인 버튼은
프로바이더 브랜드 색을 유지해야 사용자가 식별한다. 로고 이미지 에셋이 없으므로
말풍선 심볼은 `Icons.chat_bubble`로 대체했다(에셋 확보 시 교체).

## 6. 뱃지 등급 색

| 등급 | 토큰 | 값 |
|------|------|-----|
| bronze | `tierBronze` | `#B08D57` |
| silver | `tierSilver` | `#9AA5B1` |
| gold | `tierGold` | `#E0B23C` |
| platinum | `tierPlatinum` | `#5BC8DE` |

사용처: 뱃지 메달 테두리/아이콘, 랭킹 1~3위 순위 숫자(금·은·동).
획득한 뱃지만 등급 색을 쓰고, 미획득/게스트는 `onSurfaceVariant` 중립 톤이다.

## 7. 상태 UI 규칙 (로딩/에러/빈/게스트)

모든 데이터 화면은 4가지 상태를 함께 구현한다.

| 상태 | 표현 |
|------|------|
| 로딩 | 스켈레톤(회색 블록). 스피너 전체 화면은 리스트 화면에서 쓰지 않는다 |
| 에러 | `cloud_off` 아이콘 + 한 줄 메시지 + "다시 시도" 버튼(`ref.invalidate`) |
| 빈 | 중립 아이콘 + 원인 설명 문구 |
| 게스트 | 아래 §8 |

## 8. 게스트 유도 컴포넌트

`lib/features/auth/presentation/widgets/guest_login_prompt.dart`

| 위젯 | 언제 쓰나 | 표현 |
|------|-----------|------|
| `GuestLoginPromptCard` | 콘텐츠는 보이지만 **개인화 레이어만** 잠긴 경우 (전체 랭킹, 뱃지 카탈로그) | `primaryContainer` 배경 배너 + primary 채움 CTA |
| `GuestLoginGate` | 게스트에게 **콘텐츠 자체가 없는** 경우 (크루/친구 랭킹 탭) | 전면 중앙 안내 + CTA |

두 위젯 모두 `context.goToLogin()`을 호출한다 — 현재 경로가 `?from=`으로 실려
로그인 후 원래 화면으로 자동 복귀한다. **분기(로그인 여부 판정)는 호출부가**
`isAuthenticatedProvider`로 하고, 이 위젯들은 분기하지 않는다.

CTA 버튼은 `primaryContainer` 위에 얹히므로 tonal이 아닌 **primary 채움**을 쓴다
(tonal은 대비가 부족해 배경에 묻힌다).

## 9. 게스트 상태 표시 규칙

- 하단 탭바: **프로필 탭 아이콘에만** `Badge(label: '로그인')`. 탭마다 붙이면
  화면이 어지러워지므로 하나로 제한한다.
- 뱃지 카탈로그: 게스트에게 획득 여부를 **노출하지 않는다**. 전부 동일한
  중립 자물쇠 표현이라 "내가 못 얻은 뱃지"처럼 보이지 않는다.
- 로그인 화면: `?from=` 경로에 따라 "왜 로그인 화면에 왔는지" 안내 문구가 달라진다
  (`/tracking` → "러닝을 시작하려면...", `/history` → "내 러닝 기록을 보려면..." 등).

## 10. 게이미피케이션 연출

- 획득 뱃지 메달: `TweenAnimationBuilder` 0.85→1.0 스케일, 380ms `easeOutBack`.
- 획득 개수 진행률 바: 0→비율, 600ms `easeOutCubic`.
- 뱃지 획득 **순간**의 전체화면 오버레이 연출은 이번 범위 밖(러닝 종료 흐름과 함께 구현).

---

## 11. 트래킹 화면 규칙 (2026-08-20 추가)

구현: `lib/features/tracking/presentation/`

### 11.1 수치 표시 포맷 — `RunFormat` 단일 출처

`tracking_format.dart`가 모델 단위(m / s / s·km⁻¹)를 화면 단위로 바꾸는 유일한 곳이다.
위젯마다 `toStringAsFixed`를 부르면 화면별로 소수 자리가 어긋난다.

| 값 | 포맷 | 비고 |
|----|------|------|
| 거리 | `12.34` km, 소수 2자리 | `distanceMeters / 1000` |
| 시간 | `mm:ss`, 1시간↑ `h:mm:ss` | `elapsedSeconds`(벽시계) |
| 페이스 | `5'42"/km` | 분모는 **`movingSeconds`** — 정지 시간을 넣으면 신호등 하나에 페이스가 무너진다 |
| 없음 | `--'--"` | 0으로 표시하면 "0을 달성했다"로 읽힌다 |

페이스는 99분/km를 넘으면 숨긴다 — 출발 직후 몇 미터 구간에서 값이 요동친다.

### 11.2 타이포 위계

트래킹 통계는 **달리면서 읽는** 텍스트라 일반 화면보다 한 단계 크다.

| 역할 | 스타일 | 비고 |
|------|--------|------|
| 주 지표(거리) | `displayLarge` + w700 | `FittedBox`로 축소 허용 |
| 보조 지표(시간/페이스) | `headlineMedium` + w600 | |
| 3차 지표(심박/칼로리) | `titleMedium` (`compact: true`) | |
| 지표 라벨 | `labelMedium` / `onSurfaceVariant` | |

숫자는 전부 `FontFeature.tabularFigures()`. 고정폭이 아니면 매 초 숫자 폭이 바뀌어
값이 좌우로 흔들린다.

### 11.3 안내 배너 톤 (`TrackingBanner`)

권한·서비스·워치 안내가 **한 가지 모양**을 공유한다. 케이스마다 생김새가 다르면
사용자가 심각도를 가늠하지 못한다. 색은 `colorScheme`에서만 온다.

| 톤 | 색 | 쓰는 곳 |
|----|-----|---------|
| `info` | `surfaceContainerHighest` | Garmin 지연 동기화 안내 |
| `warning` | `tertiaryContainer` | 일시 권한 거부, 미완결 세션, GPS 품질 저하 |
| `error` | `errorContainer` | 영구 거부, 위치 서비스 꺼짐 |

### 11.4 액션 위계

| 동작 | 표현 | 근거 |
|------|------|------|
| 시작 | 120pt 원형 `FilledButton`, 배경 `#E9E9E9`(회색), 텍스트만(아이콘 없음) | 화면의 유일한 주 동작. **2026-08-20 Figma 반영**으로 168pt·브랜드 그린·재생 아이콘 조합을 대체 — §11.7 참고. 달리기 직전 상태에서도 눌린다 |
| 일시정지 | `FilledButton.tonal` 56pt | |
| 재개 | `FilledButton`(primary) 56pt | 일시정지 상태에서 가장 강조 |
| 종료 | `FilledButton`(error 배경) 56pt | + 확인 다이얼로그 |
| 버리기 | `TextButton`(error 전경) | **일시정지 상태에서만 노출** — 달리는 중 오탭이 이 화면 최악의 사고다 |

### 11.5 지도

- `flutter_map` + OSM 타일. 폴리라인 `strokeWidth: 6`, `colorScheme.primary`,
  `onPrimary` 테두리 2pt(밝은 타일 위에서도 경로가 보이도록).
- 현재 위치 마커 22pt 원 + 흰 테두리 3pt + primary 글로우.
- 상호작용은 **드래그/핀치줌만** 허용. 달리는 중 회전은 방향 감각을 무너뜨린다.
- 타일 소스는 `mapTileProviderOverride`로 주입 가능 —
  위젯 테스트가 네트워크 타일 재시도 루프에 걸리지 않게 하기 위한 접합부다.
- 실내 러닝(`ActivityType.indoorRun`)은 좌표가 없으므로 `RunMapUnavailable`로 대체.

### 11.6 상태 없음 표현

| 상황 | 표현 |
|------|------|
| GPS 첫 fix 이전 | 지도 위 "GPS 신호를 잡는 중" 칩 + 스피너. 아무 표시가 없으면 "기록이 안 된다"고 오해한다 |
| 진행 중 값 0 | `0.00 km / 00:00 / --'--"` |
| 러닝 중 위치 서비스 꺼짐 | error 배너 + **누적값 유지**(스트림 에러 시에도 마지막 값을 보여준다) |

### 11.7 대기 화면 목표 설정 (Figma 반영, 2026-08-20 개편)

Figma 파일 `97770fBbX9OAcPkEdZxiIP`(node `47:341`)을 기준으로 대기 화면을
다시 짰다 — **사용자가 직접 확정한 결정 2건**을 포함한다.

**변경 전 → 후**

| 항목 | 이전 | 지금 |
|------|------|------|
| 헤드라인 | "오늘도 달려볼까요?" + 오프라인 저장 안내 문구 | 제거 |
| 활동 유형 선택 | `_ActivityTypeSelector`(야외/실내/트레일/걷기 `ChoiceChip` 4개) | **제거.** `ActivityType`는 야외 러닝(`outdoorRun`)으로 코드에 고정(`_TrackingPageState._activityType`, `const`가 아니라 UI만 없앤 것 — 값은 그대로 `start()`에 전달된다) |
| 시작 버튼 | 168pt, `colorScheme.primary`(브랜드 그린), 재생 아이콘 + "시작" | 120pt, `#E9E9E9`(중립 회색), 아이콘 없이 "시작" 텍스트만 |
| 신규 요소 | 없음 | "거리 / 시간" 목표 지표 탭 + 큰 목표 숫자(탭하면 바텀시트로 편집) + "웨어러블 연동" 상태 칩 |

**목표(거리/시간) 값의 성격 — 2026-08-20 화면 레이어까지 연결 완료**

`RunTrackingService`/`RunRecord`는 건드리지 않고, **화면 레이어에서만**
목표를 실시간 진행률/달성 알림에 연결했다(`_RunGoal` 값 객체가 판정 기준을
한 곳에 모은다):

- `_GoalProgressPanel`이 `activeRunProvider`를 직접 구독해 진행 중 화면에
  "목표 5.00km까지 · 62%" 진행률 바를 그린다(목표를 넘기면 "목표 달성!" +
  100%에서 멈춤).
- 목표를 처음 넘기는 순간 스낵바로 한 번만 알린다(`_goalReachedNotified`
  플래그로 세션당 1회 제한 — 목표를 넘긴 채로 계속 달리는 게 정상 흐름이라
  매 초 다시 뜨면 안 된다). 새 세션을 시작하면 플래그가 초기화된다.

**여전히 안 된 것 — 화면 레이어 밖 연결이 필요하면 후속 작업**

목표는 여전히 `_TrackingPageState`의 **로컬 UI 상태일 뿐이다**(서버 미영속,
`RunTrackingService.start()`에도 전달되지 않음). 화면을 벗어나면 사라진다.
아래가 필요해지면 그때 엔진/모델 확장이 필요하다:

1. 목표를 서버에 저장하거나 다른 기기와 동기화 — `RunRecord`/트래킹 세션에
   목표 필드 추가 여부 결정(mobile-architect).
2. 목표 달성 시 자동 정지, 또는 엔진 자체가 목표를 알아야 하는 기능 — `RunTrackingService.start()`
   시그니처 확장 여부 결정(gps-tracking-engineer). 지금은 화면이 매초 스냅샷을
   비교하는 것만으로 충분해 엔진 변경 없이 구현했다.
3. 요약 화면에 "목표 달성 여부" 표시 — 이번 범위에는 없음(진행 중 화면까지만).

**활동 유형(걷기/트레일/실내 러닝)이 없어진 것에 대해**

사용자가 "일단 제거(야외 러닝 고정)"로 확정했다(2026-08-20). 다른 유형이
다시 필요해지면 이 화면이 아니라 별도 진입점(예: 설정 아이콘, 러닝 시작 전
바텀시트)에 추가하는 걸 권장한다 — Figma 디자인 자체가 이 화면에 그 자리를
할당하지 않았기 때문이다. `RunFormat.hasRoute()`/`RunMapUnavailable`(실내
러닝은 지도 대신 안내) 로직 자체는 코드에 그대로 남아 있으니, 진입점만
새로 만들면 바로 동작한다.

**웨어러블 연동 칩**

`GeolocatorRunTrackingService.wearableConnected`를 읽어 상태를 표시한다.
탭하면 짧은 안내 다이얼로그만 뜬다 — 별도 웨어러블 설정 화면이 아직 없어서다
(범위 밖). 실제 연동/해제 액션은 없다.

---

## 12. 미결 / 후속

- `assets/badges/*.png` 아이콘 에셋 없음 → 카테고리별 Material 아이콘으로 대체 중.
  에셋 확보 시 `_BadgeMedal`의 `Icon`을 `Image.asset(badge.iconAsset)`으로 교체.
- Runnit 로고 이미지 없음 → 타이포 + `Icons.directions_run` 원형 심볼로 대체.
- 다크 테마는 `AppTheme.dark()`로 정의되어 있으나 화면별 검증은 미실시
  (모든 색을 `colorScheme`/토큰으로만 썼으므로 구조적으로는 대응됨).
- **미완결 세션 "이어하기" 미구현.** `RunTrackingService`에 끊긴 세션을 이어받는
  계약이 없어(`start()`는 항상 새 세션) 배너는 "기록으로 저장 / 버리기"만 준다.
  진짜 이어하기가 필요하면 엔진에 `resume(RunRecord)` 계약 추가가 선행돼야 한다
  — gps-tracking-engineer 협의 필요.
- 트래킹 화면에 배터리↔정확도(`trackingProfileProvider`) 설정을 **넣지 않았다.**
  러닝 중 변경이 세션을 날리는 위험 대비 이득이 작아 프로필/설정 화면으로 미룬다.
  그 화면이 생기면 진행 중 세션 여부로 비활성화 처리가 필요하다.
- **러닝 목표(거리/시간)는 진행 중 화면의 진행률·달성 알림까지 연결됐다**
  (§11.7, 2026-08-20). 다만 여전히 화면 로컬 상태다 — 서버 영속화, 목표 기반
  자동 종료, 요약 화면 표시가 필요해지면 모델/엔진 확장이 후속 과제다.
- **활동 유형 선택 UI가 대기 화면에서 빠졌다** (2026-08-20, 사용자 확정 — Figma
  디자인에 자리가 없어 야외 러닝으로 고정). `ActivityType`/`RunFormat.hasRoute()`
  로직 자체는 남아 있으니, 다른 유형이 필요해지면 새 진입점만 추가하면 된다.

## 13. 4탭 개편 (2026-08-21, Figma 프레임 `48:872` 반영)

**바텀 네비게이션이 5탭(러닝/기록/랭킹/뱃지/프로필) → 4탭(홈/러닝/기록/마이)으로
바뀌었다.** 독립 라우트였던 랭킹·뱃지가 다른 화면 안으로 흡수됐다 — 사용자가
직접 확정한 구조("홈에는 랭킹과 티어, 기록에는 뱃지").

| 이전 | 지금 |
|------|------|
| `/ranking` (독립 탭, 전체/크루/친구) | **삭제.** 내용 그대로 `/home`으로 이동 — 티어 카드(TI-05) 아래에 동일한 전체/크루/친구 탭 |
| `/badges` (독립 탭) | **삭제.** `BadgeGalleryPage` → `BadgeGalleryBody`(Scaffold/AppBar 없는 위젯)로 추출해 `/history`의 "뱃지" 하위 탭에 임베드 |
| `/profile` | 라우트는 그대로, 탭 라벨만 "프로필"→"마이" |
| (신규) `/home` | 티어 카드(`_TierCard`, `AppUser.currentTier`/`tierProgress` 표시) + 랭킹. PRD TI-05·GM-06이 "홈 화면 상시 노출"을 요구하므로 화면을 새로 쪼개지 않고 여기 배치 |

### 게스트 정책 변경 (내용은 동일, 대상 라우트만 이동)

`RouteAccess.guestAllowedPrefixes`가 `[ranking, badges]` → `[home, history]`로 바뀌었다.
**`/history`는 하위 탭마다 정책이 다르다** — "기록" 탭은 로그인 필요(`GuestLoginGate`),
"뱃지" 탭은 카탈로그 공개(기존과 동일, 개인화만 위젯이 숨김). 로그인 게이트를
라우트가 아니라 탭 콘텐츠 단위로 거는 첫 사례다 — 이후 비슷한 "탭마다 다른 공개
범위" 화면을 만들 때 이 패턴(`_HistoryPageState`의 `TabBarView` + 탭별 개별 위젯)을
참고할 것.

### 후속 필요

- 기록 탭 본문("기록 화면 (구현 예정)")은 여전히 미구현 — 다음 라운드.
- 홈 화면의 티어 카드는 TI-05 요구사항 중 "진행률 바 상시 노출"만 반영했다.
  TI-04(승급 즉시 연출 애니메이션)은 아직 없음 — 티어 시스템 2라운드 후보.
- **홈 화면의 "전체/크루/친구 탭" 구조는 §14에서 대체됐다** — 아래 참고.

## 14. 홈 화면 탭 제거 + 티어별 랭킹 섹션 (2026-08-21)

**사용자 지시**: "홈 화면에 탭은 필요없어. 크루 및 친구는 현재 구현 범위가
아니야. 홈화면에는 내 티어와 내 티어의 전체 유저 랭킹 및 티어별 유저 랭킹을
확인할 수 있어야해. 이건 탭으로 구분하지 말고 각각의 영역을 볼 수 있는
구조로 만들어줘." §13에서 옮겨온 전체/크루/친구 `TabBar`를 완전히 없애고,
크루·친구 랭킹은 삭제(현재 구현 범위 밖 — PRD도 CR-01~04/RK-11/12를 P2로
미룬다)했다.

### 구조

`HomePage`는 이제 `ConsumerWidget`(TabController 없음) + `CustomScrollView`
하나다. 위에서부터:

1. `_TierCard` — 그대로.
2. **"전체 유저 랭킹"** 섹션 — `tier: null`(티어 무관, RK-08 전체 보드).
3. **"티어별 유저 랭킹 · {내 티어}"** 섹션 — 로그인 사용자의 `AppUser.currentTier`로
   좁힌 보드(RK-02). 게스트는 이 섹션 대신 `GuestLoginGate`.

두 섹션 모두 **탭이 아니라 항상 같이 보이는 별개 영역**이다 — 세로로 계속
쌓이는 한 페이지. 중첩 `ListView`(무한 높이 제약 충돌)를 피하려고
`SliverMainAxisGroup`으로 섹션 하나(제목+목록)를 한 슬리버 단위로 묶어
`CustomScrollView.slivers`에 이어붙였다. `_LeaderboardSkeleton`도 슬리버
컨텍스트(무한 높이) 안에 들어가므로 `ListView` 대신 고정 개수 `Column`으로
바꿨다 — 이전 랭킹 화면 스켈레톤은 `ListView`였는데 그건 `Expanded` 밑이라
괜찮았지만 여기선 안 된다.

"내 순위" 표시는 화면 하단 고정 바(구 랭킹 화면 방식)를 버리고 각 섹션
목록의 두 번째 항목(`_MyRankInline`)으로 옮겼다 — 섹션이 두 개로 늘면서
고정 바를 두 개 동시에 띄우면 화면이 번잡해지기 때문.

### 데이터 계층 변경

- `RankingRepository`의 세 메서드(`fetchLeaderboard`/`fetchMyEntry`/
  `watchLeaderboard`) 모두 `Tier? tier` 파라미터 추가.
- `SupabaseRankingRepository._scoped()`: `tier == null`이면
  `.isFilter('tier', null)`(IS NULL), 아니면 `.eq('tier', tier.wire)`.
  ⚠️ `.eq('tier', null)`은 PostgREST에서 `IS NULL`이 아니라 **항상 빈 결과**를
  주므로 반드시 `isFilter`를 써야 한다(postgrest-dart 2.9.1 확인).
- `ranking_providers.dart`: 크루 조회 로직이 있던 `leaderboardProvider`
  (`FutureProvider.family<..., RankingScope>`)를 `Tier?` 키로 재정의.
  `myTierProvider`(내 현재 티어) → `myTierLeaderboardProvider`/
  `myTierRankProvider`(합성 provider, 티어를 먼저 구하고 그 티어로 재조회)
  추가. `RankingScope.crew`/`.friends` enum 값 자체와 백엔드 RLS/컬럼은
  건드리지 않았다 — PRD가 P2로 미룬 것이지 삭제 대상이 아니라서, UI에서만
  참조를 없앴다.

### 검증

`dart analyze` clean, `flutter test` 56/56 통과, 시뮬레이터에서 실기기
테스트 계정(`dev.tester@runnit.test`)으로 로그인 후 확인 — 탭 없이 티어
카드 + 두 섹션이 세로로 쌓여 보이고, 기록이 없는 정상 상태에서 각각
"아직 이번 주 기록이 없어요"/"아직 같은 티어에서 기록한 사람이 없어요"가
뜬다(에러가 아니라 정상 빈 상태).

## 15. 홈 화면 Figma 반영 — 필 토글로 복귀 (2026-08-21)

**Figma 파일 `97770fBbX9OAcPkEdZxiIP`, 노드 `55:1118`("Home" 프레임)를 그대로
반영.** §14에서 "탭 없이 두 섹션 항상 노출"로 정했던 "러너 랭킹" 구조를,
이번엔 사용자가 명시적으로 **"Figma 그대로(토글)"**를 선택해 다시 바꿨다 —
"내 티어"/"전체" 필 버튼 하나만 선택해 보여주는 방식(하나만 보이는 리스트,
로컬 위젯 상태로 전환). §14의 상시 노출 결정이 이번 요청으로 갱신된 것이라는
점을 이후 라운드에서 헷갈리지 않도록 여기 명시해 둔다.

### 신규 구성 (위→아래)

1. **커스텀 헤더** — 시스템 `AppBar` 대신 직접 그림. "Runnit" 로고(SVG) +
   검색/알림 아이콘. 둘 다 아직 목적지가 없어(검색은 범위 밖, 알림은 PRD
   NT-* 후속) 탭하면 "준비 중" 스낵바만 뜬다.
2. **"이번 주 기록" 카드** — 이번 주 누적 거리(`myRankProvider(null)?.score`,
   period=weekly/tier=null 조합 — 기존에 있던 값 재사용) + 현재 티어 배지 +
   시즌 티어 진행률 바. **진행률 바 색은 Figma 지정값(브랜드 그린 `#00F35A`)
   고정이며 티어 색과 무관하다** — 구 디자인(§13 이전)은 티어색으로 칠했었는데
   이번 Figma는 그린 하나로 통일했다.
3. **"오늘의 Top 러너"** — `RankingPeriod.daily` 글로벌 리더보드 상위 10명
   가로 스크롤 카드. `daily` 기간은 `refresh_all_leaderboards()`가 이미 모든
   (period, metric) 조합 × scope=global을 5분마다 갱신해 두므로 **백엔드
   변경 없이** 바로 썼다(`leaderboard_entries` 실측으로 확인).
4. **"러너 랭킹"** — "내 티어"(기본 선택)/"전체" 필 토글 + "전체 보기"(목록을
   미리보기 5개 ↔ 전체로 펼치는 인앱 토글, 별도 화면 없음).

### 알려진 데이터 제약 — 티어 배지를 일부러 생략한 곳

`leaderboard_entries.tier`는 **조회 조건**(스코프)이지 각 행 소유자의 개인
티어가 아니다(마이그레이션 23, §14 참고). 그래서 "전체"로 조회한 결과나
"오늘의 Top 러너"(둘 다 tier=null 조회)에서는 각 유저가 실제로 무슨 티어인지
알 수 없다 — Figma 목업은 모든 카드에 Bronze 배지를 그려 뒀지만 그건 목업
데이터가 전부 Bronze라서 그렇게 보일 뿐이다. **"내 티어" 필을 선택했을 때만
티어 배지를 그린다**(그 리스트의 모든 행이 이미 알고 있는 같은 티어이므로
공짜로 정확하다). "전체"/"오늘의 Top 러너"에 실제 개인 티어를 채우려면
`leaderboard_entries`에 유저별 `profiles.current_tier`를 조인해 내려주는
백엔드 작업이 별도로 필요하다 — 지금은 의도적으로 범위 밖으로 남겼다.

### 자산 반입

Figma가 내려준 아이콘을 벡터 그대로 썼다(직접 그리지 않음) — 사용자가 미리
`/Users/jehyun/Downloads/Icon/`에 준비해 둔 lucide SVG 세트 + `Logo.svg`를
`assets/icons/`로 복사하고 `flutter_svg` 의존성을 추가해 렌더링한다.
`tier_shield.svg`는 브론즈 색(`#A47300`)이 벡터에 하드코딩돼 있어서, 실제
티어 색으로 다시 칠하려고 `colorFilter: ColorFilter.mode(tierColor,
BlendMode.srcIn)`으로 강제 틴트한다(`_TierPill` 위젯). 바텀 네비게이션 바
아이콘도 이번에 Material 아이콘 → 같은 lucide SVG 세트로 교체했고, 3번째
탭 라벨을 Figma에 맞춰 "기록"→"활동"으로 바꿨다(라우트 자체는 `/history`로
동일 — 표시 라벨만 변경).

### 검증

`dart analyze` clean, `flutter test` 56/56 통과, 시뮬레이터에서 실기기
테스트 계정으로 로그인 후 확인 — 헤더/카드/Top러너/랭킹 필 토글까지 전부
Figma와 시각적으로 일치, 필 토글 탭 시 "내 티어"↔"전체" 전환도 정상 동작.

### 후속 필요 (§15 작성 시점 — 아래 §16에서 전부 해소됨)

- ~~"전체"/"오늘의 Top 러너"에 실제 개인 티어 배지 채우기 — 백엔드 조인 필요.~~
- 검색/알림 아이콘 — 실제 기능 없음(자리표시자). (여전히 미해결)
- ~~"전체 보기" — 별도 랭킹 전체 화면이 아니라 인앱 펼치기로 임시 처리.~~

## 16. §15 후속 피드백 4건 반영 (2026-08-21)

가상 유저 8명(브론즈4/실버2/골드1/플래티넘1)으로 실데이터를 채워 §15 결과물을
직접 확인한 뒤 받은 피드백. 이 라운드에서 §15의 "후속 필요" 항목 두 개가
실제로 해소됐다.

1. **"내 티어" 카드의 티어 표시는 뱃지가 아니라 아이콘+텍스트만.**
   `TierPill`에 `background: bool` 파라미터를 명시적으로 추가했다(이전에는
   `iconSize >= 24`로 배경 유무를 암묵적으로 추측했는데, 그 추측 규칙을
   없애고 호출부가 직접 지정하도록 바꿨다). `_WeeklyTierCard`는
   `background: false`.
2. **"오늘의 Top 러너"는 5명만.** `dailyTopRunnersProvider`의 `limit`을
   서버 조회 단계에서 10→5로 낮췄다(클라이언트에서 자르지 않고 애초에 5개만
   가져온다).
3. **"러너 랭킹"의 "전체 보기"가 별도 화면으로 이동한다.** 기존 인앱
   펼치기(`_expanded` 토글)를 없애고, `Navigator.push`로
   [FullRankingPage](../lib/features/home/presentation/full_ranking_page.dart)를
   띄운다 — 리포지토리가 주는 만큼(최대 50명) 전부 보여주고, 내 순위 행을
   `RunnerListTile(highlighted: true)`로 강조 표시한다(primaryContainer 배경 +
   테두리, 이름 뒤에 "(나)" 붙임 — 기존 랭킹 화면의 "내 순위" 강조 스타일
   재사용). 홈 화면 미리보기는 내 티어/전체 각각 10명(`_previewCount = 10`).
4. **"전체" 랭킹에도 실제 티어 배지를 보여준다.** 이게 §15에서 "데이터 제약으로
   생략"이라고 적어뒀던 바로 그 항목이다 — 이번에 실제로 채웠다:
   - **마이그레이션 24**(`20260821180000_24_leaderboard_owner_tier.sql`):
     `leaderboard_entries`에 `owner_tier public.tier` 컬럼 추가. 기존 `tier`는
     "이 보드가 어느 티어로 필터링됐는지"(조회 조건)라 "전체" 보드에서는 항상
     null이었던 것과 달리, `owner_tier`는 `refresh_leaderboard()`가 각 행을
     쓸 때 `profiles.current_tier`를 조인해 **보드 종류와 무관하게 항상**
     채워 넣는다.
   - `RankingEntry.ownerTier` 필드 추가(freezed/json_serializable 재생성).
   - `RunnerListTile`(공용 위젯)이 이제 `entry.tier` 대신 `entry.ownerTier`로
     배지를 그린다 — "내 티어"/"전체"/"오늘의 Top 러너"/전체 랭킹 화면 어디서든
     항상 정확하다. 예전의 "showTierPill && tier != null" 같은 조건부 로직은
     전부 제거했다(더 이상 필요 없음).

### 공용 위젯으로 추출

`TierPill`/`ProfileCircle`/`RunnerListTile`/`RunnerListSkeleton`을
`home_page.dart`의 private 클래스에서 꺼내
[widgets/ranking_widgets.dart](../lib/features/home/presentation/widgets/ranking_widgets.dart)
공개 클래스로 옮겼다 — `home_page.dart`와 `full_ranking_page.dart` 양쪽에서
같은 시각 언어를 쓰기 위해서다(Dart는 프라이버시가 파일 단위라 private
클래스는 다른 파일에서 재사용 불가).

### 검증

`dart analyze` clean, `flutter test` 56/56 통과. 마이그레이션 24를 실제
원격 프로젝트에 적용하고 `refresh_all_leaderboards()`로 기존 캐시를
재계산해 `owner_tier`가 정확히 채워지는지 SQL로 직접 확인. 시뮬레이터에서
"전체" 필 선택 시 각 유저 실제 티어(Bronze/Silver/Gold/Platinum)가 정확히
표시되고, "전체 보기" → 전체 랭킹 화면 이동 → 8명 전부 티어 배지와 함께
표시되는 것까지 확인.

### 후속 필요

- 검색/알림 아이콘 — 여전히 자리표시자(실제 기능 없음).
- `FullRankingPage`에서 내 순위 행으로 자동 스크롤하는 건 아직 안 함(강조
  표시만 함 — 목록이 길고 내 순위가 아래쪽이면 스크롤해서 찾아야 함).

## 17. Figma 재확인 — 폰트/컬러/타이포 사이즈 정정 (2026-08-23)

Home 프레임을 다시 열어보니(§15/§16 이후 디자이너가 일부 값을 갱신한 것으로
보인다) 실제 지정값이 그동안 구현과 몇 군데 어긋나 있었다. "컬러와 타이포
사이즈를 다시 확인해서 수정"이라는 요청으로 하나씩 대조해 바로잡았다.

### 폰트 — Pretendard Variable 전체 적용

Figma의 모든 텍스트 노드가 `Pretendard_Variable:Weight` 폰트를 쓰고 있었는데
지금까지 시스템 기본 폰트(San Francisco/Roboto)로 렌더링되고 있었다. 사용자가
이미 `/Users/jehyun/Downloads/Pretendard-1.3.9/public/variable/PretendardVariable.ttf`
를 준비해 둬서 그걸 그대로 반입했다:

- `assets/fonts/PretendardVariable.ttf` 추가, `pubspec.yaml`에 `Pretendard
  Variable` 폰트 패밀리로 등록.
- [app_theme.dart](../lib/core/theme/app_theme.dart)의 `ThemeData`에
  `fontFamily: 'Pretendard Variable'`을 한 번만 지정 — 개별 `TextStyle`이
  `fontFamily`를 명시하지 않으면 전부 이걸 상속받으므로 화면마다 따로
  지정할 필요가 없다. 가변 폰트 파일 하나가 Regular~Bold 전 굵기를
  커버해서 굵기별 정적 파일을 따로 등록하지 않아도 `fontWeight`가 자동으로
  가장 가까운 축에 매핑된다.

### 컬러 정정

- **"내 티어"/"전체" 필 토글**: 선택된 쪽이 연한 초록 톤 필(`rgba(0,231,86,
  0.3)` 배경 + 진초록 텍스트)이었는데, 실제 Figma는 **`#00C84B` 단색 배경 +
  흰 텍스트**였다. 미선택 쪽 텍스트 색도 `#616161` → `#9B9B9B`로 정정.
- **바텀 네비게이션 미선택 탭**: §13/§15에서 "선택 여부와 무관하게 항상
  검정"이라고 명시했던 규칙이 이번에 다시 보니 틀렸다 — 실제로는 미선택
  탭(아이콘+라벨)이 `#9B9B9B` 회색이고 선택된 탭만 검정이다. 디자인이 그
  사이 갱신된 것으로 보인다(과거 규칙을 신뢰하지 말고 재확인이 필요했던
  사례).
- **바텀 네비 배경**: Figma의 "Nav bar" 노드가 아래(흰색)→위(투명)로
  옅어지는 그라디언트 스크림을 깔고 있었다 — 이전엔 생략했는데 이번에
  추가했다(`AppShell`에 `DecoratedBox` + `LinearGradient`, `extendBody:
  true`로 스크롤 콘텐츠가 그 밑을 지나가게 함).

### 타이포 사이즈 정정

Material 기본 텍스트 스타일(`titleMedium`=16px 등)에 기대지 않고 Figma
지정값을 그대로 하드코딩하는 쪽으로 정리했다 — 특히 아래 두 곳이
`titleMedium`(16px)을 썼는데 실제로는 20px이 필요했다:
- "오늘의 Top 러너"/"러너 랭킹" 섹션 제목: 20px SemiBold(이전엔 16px로
  렌더링되고 있었음).
- 랭킹 행/Top 러너 카드의 거리 숫자("20.1"): 20px Medium(이전엔 16px).
- Top 러너 카드 폭: 160px → **141px**, 카드 간격: 8px → **12px**.
- 그 외 "이번 주 기록" 라벨(12px Regular)/"km" 단위(16px Medium)/"다음
  티어까지"(14px Medium) 등도 테마 기본값에 기대지 않고 명시적 `TextStyle`로
  고정 — 테마의 `textTheme` 기본 크기가 나중에 바뀌어도 이 화면의 Figma
  대응이 깨지지 않도록.

### 검증

`dart analyze` clean, `flutter test` 56/56 통과. 시뮬레이터에서 가상 유저
데이터로 확인 — Pretendard 폰트가 실제로 렌더링되고, 섹션 제목이 커지고,
필 토글이 단색 초록+흰 글자로 바뀌고, 바텀 네비 미선택 탭이 회색으로,
Top 러너 카드가 더 좁아진 것까지 전부 확인.

### §17 후속 — 간격(gap/padding)도 놓쳤던 것 바로잡음

§17에서 컬러/타이포만 대조하고 **간격은 다시 확인하지 않아** 실제로 몇 군데
어긋나 있었다(사용자 지적으로 재작업). Figma JSX를 처음부터 다시 훑어
아래를 고쳤다:

- **섹션 좌우 여백 16→24**: "오늘의 Top 러너"/"러너 랭킹" 두 섹션은 바깥
  컨테이너 여백(16) **위에 자체 `px-8`이 추가**로 붙어 있어 실제 좌우
  여백은 24였다. 지금까지 16만 적용해서 "이번 주 기록" 카드보다 두 섹션이
  덜 들어가 보였다(카드는 16 마진 + 16 내부 패딩 = 32, 섹션은 24 — 이
  8px 차이 자체가 Figma의 의도된 비대칭). 제목/가로 스크롤 카드열/랭킹
  목록의 좌우 패딩을 전부 24로 고쳤다.
- **필 버튼 사이 간격 8→9**: Figma `gap-[9px]` 그대로.
- **필 버튼 줄 ↔ 목록 사이 간격 0→16**: "Ranking" 컨테이너 자체가
  `flex-col gap-16`이라 Pill Buttons와 Lists 사이에도 16 간격이 있었는데
  이전엔 붙어 있었다.
- **랭킹 목록 행간 간격 0→8**: Figma `Lists`(`flex-col gap-8`) — 각 행이
  자체 `py-8`을 갖는 것과는 별개로 행 사이에 추가 8px 간격이 있다.
  `SliverList.builder`는 항목 사이에 구분자를 넣을 수 없어서, 미리보기가
  최대 10개인 점을 이용해 `Column` + `SizedBox(height: 8)` 구조로 바꿨다.
- **"이번 주 기록" 카드의 거리↔티어 배지 간격**: `Spacer()`로 양 끝에
  붙이고 있었는데, Figma는 거리 블록이 `w-230` **고정 너비**이고 그 뒤에
  `gap-16`로 티어가 붙는 구조였다 — `Spacer` 대신 `SizedBox(width: 230)` +
  `SizedBox(width: 16)`으로 정확히 맞췄다.
- **헤더 상하 패딩 16→15**: Figma `py-15`.

### 검증 (재)

`dart analyze` clean, `flutter test` 56/56 통과, 시뮬레이터 재확인 — 섹션
제목이 카드보다 살짝 덜 들어간(24 vs 32) Figma의 비대칭이 재현되고, 필
버튼 아래 목록까지 여백이 생기고, 목록 행 사이 간격도 더 뚜렷해졌다.

## 18. 플로팅 네비게이션 바에 콘텐츠가 가려지는 문제 (2026-08-23)

`AppShell`은 `extendBody: true`(§16 그라디언트 스크림을 넣으려고)라 body가
바텀 네비게이션 바 뒤까지 전체 화면을 채운다 — 즉 body는 네비바가 거기
떠 있다는 걸 전혀 모른다. 그 결과 각 탭의 스크롤 콘텐츠 마지막 줄이 알약
뒤로 들어가 실제로는 안 보이는 문제가 있었다(홈의 "러너 랭킹" 목록에서
발견, 뱃지 갤러리 그리드도 같은 구조라 동일하게 영향받음).

**수정**: [app_shell.dart](../lib/core/widgets/app_shell.dart)에
`AppShell.bottomClearance(BuildContext)` 정적 메서드를 추가했다 — 알약
자체 높이(61, 유일한 출처) + 그라디언트 페이드 존(24) + 기기별 하단
세이프에어리어(`MediaQuery.padding.bottom`, 최소 12)를 더한 값을
반환한다. 스크롤 콘텐츠 끝에 이 값만큼 여백을 넣으면 마지막 항목이 알약
뒤에 가려지지 않는다. 적용한 곳:
- [home_page.dart](../lib/features/home/presentation/home_page.dart)의
  "러너 랭킹" 목록 뒤.
- [badge_gallery_page.dart](../lib/features/gamification/presentation/badge_gallery_page.dart)의
  뱃지 그리드 뒤(같은 문제라 같이 고쳤다).

바텀 시트로 새로 스크롤 화면을 추가할 때는 항상 이 헬퍼로 마지막 여백을
잡을 것 — 하드코딩된 상수(24 등)로 끝내면 이 문제가 재발한다.

### 검증

`dart analyze` clean, `flutter test` 56/56 통과, 시뮬레이터에서 "러너
랭킹" 목록을 끝까지 스크롤해 마지막 유저 행(정러닝)이 알약 뒤에 가리지
않고 완전히 보이는 것 확인.

### §18 후속 — 여백이 과했음(사용자 피드백)

처음엔 클리어런스에 그라디언트 페이드존(24)까지 통째로 더해서(24+61+34
≈ 119) 마지막 행 아래 여백이 눈에 띄게 넓었다. 그런데 페이드존은 원래
"콘텐츠가 다 가려지는 게 아니라 점점 옅게 비쳐 보이며 사라지는" 연출로
넣은 구간이라, 그것까지 완전히 비워둘 필요가 없었다 — `bottomClearance`
계산에서 페이드존을 빼고 작은 여백만 더하도록 줄였다. 알약 자체와 기기
세이프에어리어만 확실히 피하고, 그 위 페이드존은 원래 의도대로 콘텐츠가
자연스럽게 스크롤돼 들어가도록 남겨뒀다. 이후 "더 줄여도 된다"(12→4) →
"네비게이션 영역 바로 위까지만 세이프티 에리어로"(4→0) 두 차례 더 줄였는데,
그래도 실기기 스크린샷에서는 여전히 여백이 크게 남아 있었다.

**원인**: `_pillHeight = 61`처럼 알약 높이를 상수로 어림하고 있었는데,
실제 렌더 높이는 폰트 메트릭(라벨 11px 텍스트의 실제 줄높이는 폰트마다
다르다)·접근성 텍스트 크기 설정·기기별 세이프에어리어에 따라 상수 어림과
어긋난다. 계산을 아무리 다시 맞춰도 "상수 대 실측"의 근본적인 불일치가
남는 구조였다.

**최종 수정**: 상수 어림을 완전히 버리고 **`AppShell`이 자기 자신의
렌더 높이를 매 프레임 실측**하도록 바꿨다 — `AppShell`을
`ConsumerStatefulWidget`으로 바꾸고 바텀 네비바 위젯에 `GlobalKey`를 달아
`addPostFrameCallback`에서 `RenderBox.size.height`를 읽어
`AppShell.measuredHeight`(`ValueNotifier<double>`)에 반영한다. 각 탭의
스크롤 콘텐츠는 이제 고정 상수 대신
```dart
ValueListenableBuilder<double>(
  valueListenable: AppShell.measuredHeight,
  builder: (context, height, _) => SizedBox(height: height),
)
```
로 항상 실제 렌더 높이만큼만 여백을 더한다 — 기기가 바뀌든 접근성 설정이
바뀌든 항상 정확하다. 적용한 곳은 §18과 동일(홈 러너 랭킹, 뱃지 그리드).

## 19. 전체 랭킹 화면(`FullRankingPage`) Figma 반영 (2026-08-23)

Figma 파일 `97770fBbX9OAcPkEdZxiIP`, 노드 `65:84`("Home"이라는 레이어 이름이지만
실제로는 "러너 랭킹" 전체 화면)를 반영해 [full_ranking_page.dart](../lib/features/home/presentation/full_ranking_page.dart)를
다시 짰다.

### 구조 변경

- **타이틀이 고정 "러너 랭킹"으로 바뀌었다.** 이전엔 홈에서 어느 필을 눌렀는지에
  따라 "내 티어 랭킹"/"전체 랭킹"으로 동적으로 바뀌었는데, Figma는 이 화면
  **안에도 홈과 똑같은 "내 티어"/"전체" 필 토글을 다시 두고** 있어서 타이틀이
  그 상태를 반영할 필요가 없어졌다. `FullRankingPage`는 이제 `initialTier`만
  받고(홈에서 넘어올 때의 필 상태를 시작값으로만 씀), 화면 안에서 독립적으로
  전환 가능한 로컬 상태(`_myTierSelected`)를 갖는다.
- **커스텀 헤더**로 교체 — `<` 뒤로가기(24px, `chevron_right.svg`를
  `Transform.flip`으로 좌우 반전해 재사용 — 별도 `chevron-left` 에셋은
  안 받아서) + "러너 랭킹"(20px SemiBold), px16 py15 gap16.
- **시즌 선택 필**(`시즌 n ⌄`)을 새로 추가했다. `PopupMenuButton`으로 구현 —
  현재 시즌(`Season.currentId()`, 예: `2026 Q3`)만 체크 표시로 선택 가능하고,
  이전 두 시즌(`Season.previousId` 체이닝)은 목록엔 보이지만 전부 "준비 중"
  으로 비활성 처리했다.

### 왜 지난 시즌은 실제로 못 보여주나

`leaderboard_entries`는 **항상 "현재 기간" 행만** 캐시한다 —
`refresh_leaderboard()`가 갱신마다 이전 기간 행을 지운다(§5 문서, 마이그레이션
10 이후 계속 유지된 설계). 다른 유저 전체의 과거 시즌 랭킹을 담아두는 테이블
자체가 없다. `season_histories`(마이그레이션 21, HI-06)는 **로그인한 사용자
본인**의 시즌별 최종 결과만 기록하지, 그 시즌의 전체 리더보드 스냅샷이
아니라서 이걸로 "지난 시즌 전체 랭킹"을 만들 수 없다. 실제로 지원하려면
시즌 종료 시점에 리더보드 전체를 스냅샷하는 백엔드 작업이 별도로 필요하다
(범위 밖 — 후속 후보).

### 검증

`dart analyze` clean, `flutter test` 56/56 통과. 시뮬레이터에서 확인 —
"전체 보기"로 진입 → 헤더/필 토글/시즌 필 모두 Figma와 일치, "전체" 필에서
8명 전원의 실제 티어 배지까지 정상 표시, 시즌 필 탭하면 현재 시즌 체크+
지난 시즌 "준비 중" 메뉴가 정확히 뜬다.

### §19 후속 — 시즌 선택을 바텀시트로 (2026-08-23)

처음엔 시즌 필을 `PopupMenuButton`(작은 팝업 메뉴)으로 구현했는데, Figma를
다시 확인하니(노드 `71:714` "Dimmed") 실제로는 화면 전체를 `rgba(0,0,0,0.6)`로
덮고 아래에서 흰 카드가 올라오는 **바텀시트**였다. `showModalBottomSheet`로
교체 — 선택된 시즌 행은 `rgba(0,200,75,0.1)` 초록 톤 배경 + 체크 아이콘,
나머지는 배경 없이 텍스트만(기존처럼 지난 시즌은 회색 처리 + "준비 중" 유지).

**한 가지 더 발견**: 처음 바텀시트를 띄웠더니 `AppShell`의 플로팅 알약
네비바 밑에 시트가 깔려서 잘려 보였다 — `FullRankingPage`는 셸의 중첩 탭
Navigator 안에 있고, 알약은 그 바깥쪽 Scaffold에 붙어 있어서 생기는 문제다
(§18에서 다룬 것과 같은 구조적 원인). `showModalBottomSheet(useRootNavigator:
true)`로 루트 Navigator를 지정해 알약보다 위(전체 화면 오버레이)에 뜨도록
고쳤다.

### 검증 (재)

`dart analyze` clean, `flutter test` 56/56 통과, 시뮬레이터로 시즌 필 탭 →
바텀시트가 알약 위로 정상적으로 올라오고 다이밍/카드 스타일이 Figma와
일치하는 것 확인.

### §19 후속 2 — 좌우 여백 제거(엣지-투-엣지) (2026-08-23)

Figma의 `p-[8px]`(화면 가장자리에서 8px 띄움)를 그대로 따라했었는데,
"기기 곡률에 맞춰 라운딩을 계산해야 하지 않냐"는 질문이 나와서 짚어보니—
**기기 물리 베젤 곡률은 공개 API로 얻을 수 없고**(private API로 우회하는
`_displayCornerRadius` 류 방법은 있지만 공식 지원 아님), 애초에 **카드가
가장자리에서 8px 띄워져 있으면 베젤 곡률과 시각적으로 이어질 일이 없어서
이 계산 자체가 불필요**했다. 사용자가 "그럼 패딩 띄우지 말자"고 정리해서
좌우 패딩을 없애고 위쪽 모서리만 둥근(`BorderRadius.vertical(top:
Radius.circular(20))`) 엣지-투-엣지 시트로 바꿨다 — `showModalBottomSheet`의
`shape`/`backgroundColor`로 처리(내부에 별도 `Container` 불필요, 시트
자체의 배경/모양을 쓴다).

## 20. "이번 주 기록" → "이번 시즌 기록" (2026-08-23)

홈 카드의 큰 숫자를 주간 랭킹 점수(`myRankProvider(null)`)가 아니라 시즌
누적 거리(`AppUser.seasonDistanceMeters`)로 바꿨다 — 바로 아래 티어 진행률
바가 이미 이 값을 쓰고 있어서, 카드 안에서 위(거리)와 아래(티어 진행률)가
서로 다른 기간(주간 vs 시즌)을 가리키던 게 헷갈렸다. 이제 라벨도 "이번 시즌
기록"으로 통일했고, `myRankProvider(null)` 구독 자체를 이 카드에서 제거했다
(다른 곳에서 안 쓰길래 죽은 코드가 되지 않게 확인 후 지움). "러너 랭킹"
섹션의 "이번 주 기록이 없어요" 빈 상태 문구는 그대로 뒀다 — 그 섹션은
여전히 주간 랭킹(`leaderboardProvider`)을 보여주므로 문구가 맞다.

### 검증

`dart analyze` clean, `flutter test` 56/56 통과, 시뮬레이터로 카드가 "이번
시즌 기록"으로 바뀌고 시즌 누적 거리를 보여주는 것 확인.
