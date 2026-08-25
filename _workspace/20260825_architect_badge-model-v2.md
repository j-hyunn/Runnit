# Badge 데이터 모델 v2 — 158종 카탈로그 마이그레이션 설계

작성: mobile-architect / 2026-08-25
기준 문서: `docs/PRD.md` §5.5(GM-01~09) · `docs/TRD.md` §3.6 · `docs/ARCHITECTURE.md` §7 · `docs/badge-catalog.csv`(158행)

> ⚠️ **이 문서는 설계 확정본이고, 코드 적용은 아직 되지 않았다.** 실행 환경 제약으로
> `lib/` 편집·`build_runner`·`flutter analyze`를 수행하지 못했다. 상세는 §8.
> 아래 §3의 Dart 코드는 그대로 붙여넣으면 되는 drop-in 형태로 작성했다.

---

## 1. 현재(v1) → 목표(v2) 격차

| 축 | v1 (라이브 코드 + 라이브 Supabase) | v2 (TRD §3.6 + 카탈로그) |
|----|----------------------------------|--------------------------|
| 판정 조건 | `criteriaType`(String) + `threshold`(double) — **단일 스칼라** | `conditionType`(String) + `condition`(jsonb) — **다중 파라미터** |
| 카테고리 | 7종 (distance/streak/pace/elevation/social/challenge/special) | **16종** (누적거리 … 시즌완주) |
| 등급 | `BadgeTier` enum 4단계 | `badgeGrade` String 6단계(+diamond, +special) |
| 스코프 | `isActive` bool로 시즌 종료를 표현 | `scope`(permanent/seasonal) + `seasonId` |
| 트리거 | 없음 (모두 누적 가정) | `triggerType`(session/cumulative) |
| 검증 | 없음 | `UserBadge.verified` |

카탈로그 실측: **permanent 117 / seasonal 41**, **cumulative 97 / session 61**,
등급 분포 special 48 · bronze 31 · silver 27 · gold 27 · platinum 19 · diamond 6.

---

## 2. 결정 사항 — TRD가 명시하지 않은 부분

### 2.1 `conditionType` — TRD 스펙의 누락. **필수 추가**

TRD §3.6의 `Badge`에는 `condition`(Map)만 있고 **판정 종류를 식별할 필드가 없다.**
그런데 카탈로그 CSV는 `condition_type`과 `condition_value`를 **별도 열**로 갖고 있고,
파라미터 키가 종류마다 완전히 다르다(`{"distanceKm":5}` vs `{"tier":"bronze","bucket":"top1"}`).
`condition` 맵만으로는 어느 판정 함수로 디스패치할지 결정할 수 없다.

→ **`required String conditionType`을 추가**한다. CSV 열과 1:1이고 DB 컬럼도 1:1이다.
대안(맵 안에 `type` 키를 밀어넣기)은 인덱싱·CHECK 제약·디스패치가 모두 불편해 기각했다.

**TRD §3.6 갱신 필요** — 이 필드가 없으면 판정 함수를 작성할 수 없다.

### 2.2 `iconAsset` — **삭제. 프로그램적 선택으로 대체**

TRD가 이 필드를 뺀 것은 의도로 판단하고 따랐다. 근거:

- 카탈로그 CSV에 아이콘 열이 **없다** → 158개 경로의 단일 진실 원천이 존재하지 않는다.
- v1의 갤러리도 실제로는 `iconAsset`을 렌더링하지 않았다. 이미
  `_categoryIcon(badge.category)`로 Material 아이콘을 고르고 있었고, 코드에
  `TODO(design): 에셋 준비되면 Image.asset(badge.iconAsset)로 교체` 주석만 남아 있었다.
  즉 이 필드는 **1년 가까이 죽은 필드**였다.
- 158개 PNG를 만들기 전까지 이 필드는 계속 죽은 채로 DB 용량만 차지한다.

→ 클라이언트 표시 계층에 `BadgeVisuals`(§3.4)를 두고
**`category` → `IconData`, `badgeGrade` → `Color`** 로 결정한다.
후일 실제 아트웍이 준비되면 `Badge`에 `String? iconAsset`을 **nullable로 추가**하고
`iconAsset ?? BadgeVisuals.iconFor(category)` 폴백을 쓰면 breaking change 없이 전환된다.

### 2.3 `points` — **삭제**

PRD §5.6이 포인트 이코노미를 **Phase 4**로 못박았고 적립 기준이 미정이다.
카탈로그에도 points 열이 없다. 지금 값을 넣으면 158개 전부 임의값이 되고,
갤러리 상세가 `${badge.points}P`로 그 임의값을 사용자에게 노출한다(v1의 현재 동작).
→ 필드와 UI 표기를 함께 제거. 레벨/XP는 `level_gte` 뱃지가 별도로 다룬다(GM-04).

### 2.4 `sortOrder` — **삭제. 파생 정렬로 대체**

카탈로그에 sort_order 열이 없어 158개 값을 임의로 채워야 한다. 게다가 카탈로그는
이미 (카테고리, 등급, 임계값) 순으로 자연 정렬돼 있다.
→ 서버 컬럼/모델 필드를 없애고 클라이언트가
`(category.index, gradeOrder(badgeGrade), id)` 로 정렬한다(§3.4 `BadgeVisuals.gradeOrder`).
DB에 `order by sort_order`가 사라지므로 **레포지토리 쿼리 수정 필요**(§5).

### 2.5 `isSecret` — **삭제**

PRD **GM-03의 수용 기준이 "미획득 뱃지도 조건·진행률 노출"** 이다. 히든 뱃지는
이 요구와 정면으로 충돌하고, 카탈로그 158종 어디에도 히든 표시가 없다.
→ 제거. `BadgeProgress.isLocked`도 함께 제거.

### 2.6 `isActive` — **삭제. `scope`+`seasonId`가 대체**

v1은 "시즌 종료된 뱃지"를 `isActive=false`로 표현했다. v2에서는 시즌성이
`scope == seasonal` + `seasonId`로 1급 모델링되므로 플래그가 중복이다.
"현재 발급 중인 시즌 뱃지"는 `seasonId == 현재 시즌`으로 판별한다.
→ 제거. 레포지토리의 `.eq('is_active', true)` 필터 제거 필요(§5).

### 2.7 `UserBadge` 확장 필드 — `id` / `isSeen` / `badge`는 **유지**, `sourceRunId`는 삭제

TRD는 `userId/badgeId/earnedAt/verified` 4개만 명시하지만, 아래 3개는 실제 코드가 쓴다:

| 필드 | 판정 | 근거 |
|------|------|------|
| `id` (uuid) | **유지** | `markBadgesSeen()`이 `inFilter('id', userBadgeIds)`로 쓴다. PK 없이는 개별 업데이트 불가. |
| `isSeen` | **유지** | PRD **GM-02**(러닝 종료 시 획득 연출)의 미확인 큐. `watchUnseenBadges()`가 `.eq('is_seen', false)`로 구독한다. RLS상 클라이언트가 쓸 수 있는 **유일한** 컬럼이다. |
| `badge` (조인) | **유지** | `select('*, badge:badges(*)')` 임베드. 갤러리 왕복 절감. |
| `sourceRunId` | **삭제** | 정의만 있고 참조가 0곳. TRD에도 없다. 감사 추적이 필요해지면 서버 로그 테이블로 분리하는 편이 낫다. |

`verified`(TRD 신규)는 **`@Default(false)`** 로 둔다 — 서버 재검증 전 상태가 기본값이어야
클라이언트가 미검증 뱃지를 낙관적으로 "획득"으로 표시하지 않는다(ARCHITECTURE 원칙 3).

### 2.8 `condition`의 기본값 — TRD와 **의도적으로 다르게** 감

TRD는 `required Map<String, dynamic> condition`이지만,
카탈로그에는 `condition_value`가 `{}`인 행이 6개 있다(`season_first_run`,
`season_pb_achieved`, `season_weekly_attendance_full`, `season_best_week_distance_pb`,
`season_challenge_completed`, `season_final_week_active`, `season_first_and_last_week_active`).
jsonb 컬럼이 NULL로 오는 경우 `required`면 `fromJson`이 던진다.
→ **`@Default(<String, dynamic>{})`** 로 완화. 판정 로직상 빈 맵과 NULL은 동치다.

---

## 3. 확정 모델 (drop-in 코드)

### 3.1 `lib/models/enums.dart` — 교체/추가분

```dart
/// 뱃지 판정 **시점**. TRD §3.6.
/// - [session]: 러닝 1건이 끝나는 순간 그 세션만 보고 판정(PB, 단일 세션 거리 등).
/// - [cumulative]: 누적 통계/집계를 다시 계산해 판정(누적 거리, 스트릭, 랭킹 등).
/// 두 경로를 모두 구독해야 마일스톤형 뱃지가 누락되지 않는다(ARCHITECTURE §7).
enum BadgeTriggerType {
  @JsonValue('session')
  session,
  @JsonValue('cumulative')
  cumulative,
}

/// 뱃지의 생명주기 스코프. TRD §3.6.
/// - [permanent]: 평생 누적 기준. 카탈로그에 딱 한 번만 존재하고 재발급되지 않는다.
/// - [seasonal]: 시즌 스코프로 판정. 카탈로그 항목은 **템플릿**이고, 시즌 시작마다
///   `seasonId`가 채워진 **인스턴스**가 새로 발급된다. 획득 인스턴스는 시즌이 끝나도
///   영구 보존된다(PRD GM-07 — 티어 리셋의 상실감을 수집 동기로 전환하는 장치).
enum BadgeScope {
  @JsonValue('permanent')
  permanent,
  @JsonValue('seasonal')
  seasonal,
}

/// 뱃지 카탈로그 16개 카테고리. 정본은 `docs/badge-catalog.csv`(158종).
/// CSV의 `category` 열은 한국어 라벨(`누적거리` 등)이지만 DB/JSON 표현은 아래
/// snake_case 영문이다 — 시드 시 backend가 매핑한다(§4 매핑표).
enum BadgeCategory {
  @JsonValue('cumulative_distance')
  cumulativeDistance, // 누적거리 (permanent)
  @JsonValue('cumulative_count')
  cumulativeCount, // 누적횟수 (permanent)
  @JsonValue('longest_streak')
  longestStreak, // 최장스트릭 (permanent) — PRD GM-05에 따라 **주 단위**
  @JsonValue('personal_best')
  personalBest, // PB갱신 (permanent, 검증된 실외 기록만)
  @JsonValue('single_session_distance')
  singleSessionDistance, // 단일세션거리 (permanent)
  @JsonValue('time_of_day_weekday')
  timeOfDayWeekday, // 시간대요일 (permanent)
  @JsonValue('route_exploration')
  routeExploration, // 경로탐험 (permanent, GPS 기반)
  @JsonValue('special_day')
  specialDay, // 특별한날 (permanent)
  @JsonValue('pace_speed')
  paceSpeed, // 페이스속도 (permanent)
  @JsonValue('device_integration')
  deviceIntegration, // 기기연동 (permanent)
  @JsonValue('level')
  level, // 레벨 (permanent) — XP 공식 미정, GM-04 별도 설계 후 확정
  @JsonValue('season_tier')
  seasonTier, // 시즌티어달성 (seasonal, GM-07)
  @JsonValue('season_weekly_rank')
  seasonWeeklyRank, // 시즌주간랭킹 (seasonal, RK-06)
  @JsonValue('season_cumulative_distance')
  seasonCumulativeDistance, // 시즌누적거리 (seasonal, P1)
  @JsonValue('season_event')
  seasonEvent, // 시즌한정이벤트 (seasonal, GM-08 P1)
  @JsonValue('season_finisher')
  seasonFinisher, // 시즌완주 (seasonal)
}
```

**`enum BadgeTier`는 삭제한다.** 참조처는 `badge_gallery_page.dart`의
`_tierColor`/`_tierLabel` 두 함수뿐이고, `badgeGrade`(String, 6값)로 대체된다.
`enum Tier`(경쟁 티어)의 doc comment에서 `[BadgeTier]` 링크를 `Badge.badgeGrade`
설명으로 바꿔야 dartdoc 참조가 깨지지 않는다.

### 3.2 `lib/models/badge.dart` — 전문 교체

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

import 'enums.dart';

part 'badge.freezed.dart';
part 'badge.g.dart';

/// 뱃지 **카탈로그** 항목 — 정의이지 획득 기록이 아니다.
/// 서버 테이블 `badges`는 사실상 읽기 전용 마스터 데이터다.
///
/// 정본은 `docs/badge-catalog.csv`(158종 / 16카테고리), 스펙은 TRD §3.6.
///
/// 판정 조건은 [conditionType](어떤 판정 함수를 쓸지) + [condition](그 함수의 입력
/// 파라미터) 조합으로 **데이터화**한다. 조건을 코드에 하드코딩하면 뱃지를 추가할
/// 때마다 앱 배포가 필요해진다.
@freezed
abstract class Badge with _$Badge {
  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory Badge({
    /// 안정적인 슬러그(예: `dist_cum_1000km`). UUID 대신 슬러그를 쓴다 —
    /// 게이미피케이션 규칙/테스트에서 사람이 읽을 수 있어야 하기 때문.
    ///
    /// `scope == seasonal`인 **인스턴스**는 `{templateId}@{seasonId}` 형태로
    /// 발급한다(예: `stier_platinum@2026-Q3`) — 시즌마다 재발급되므로 템플릿 id를
    /// 그대로 쓰면 PK가 충돌한다.
    required String id,

    /// 표시명. CSV `display_name` (예: '천리길').
    required String name,

    /// 획득 조건 설명 — 뱃지 갤러리 상세(PRD GM-03)에 그대로 노출된다.
    required String description,

    required BadgeCategory category,
    required BadgeScope scope,
    required BadgeTriggerType triggerType,

    /// 판정 함수 **디스패치 키**. CSV `condition_type`과 1:1 (현재 44종).
    /// 상수 목록과 클라이언트 판정 가능 여부는
    /// `features/gamification/domain/badge_condition.dart` 참조.
    ///
    /// String인 이유: 새 판정 종류가 추가돼도 앱 배포 없이 카탈로그가 확장되어야 한다.
    /// 클라이언트가 모르는 값이 내려오면 진행률 없이 조건 텍스트만 표시한다.
    required String conditionType,

    /// 판정 함수 입력 파라미터. CSV `condition_value`(jsonb).
    /// 키 집합은 [conditionType]마다 다르다 — 예:
    /// `cumulative_distance_gte` → `{"distanceKm": 1000}`,
    /// `season_weekly_rank_lte` → `{"tier": "gold", "bucket": "top1"}`.
    ///
    /// 파라미터가 없는 종류(`season_first_run` 등)는 `{}`다. NULL도 `{}`와 동치로
    /// 취급하기 위해 required가 아니라 기본값을 준다(TRD와 의도적 차이 — 설계문서 §2.8).
    @Default(<String, dynamic>{}) Map<String, dynamic> condition,

    /// 뱃지 자체의 표시 등급: bronze/silver/gold/platinum/diamond/special.
    ///
    /// ⚠️ `scope == seasonal`인 시즌티어달성(`stier_*`) 4종을 제외하면
    /// **실제 시즌 티어 시스템(`Tier`)과 무관한 순수 장식용 값**이다. 섞지 말 것.
    ///
    /// enum이 아니라 String인 이유: 등급 라벨은 카탈로그 운영 중 늘어날 수 있고
    /// (예: 이벤트 전용 등급), 판정 로직이 이 값을 읽지 않는다.
    required String badgeGrade,

    /// `scope == seasonal` 템플릿이 시즌 시작 시 **실제 발급된 인스턴스**일 때만 값이
    /// 있다(예: `'2026-Q3'`). 카탈로그의 템플릿 자체와 permanent 뱃지는 null.
    String? seasonId,
  }) = _Badge;

  factory Badge.fromJson(Map<String, dynamic> json) => _$BadgeFromJson(json);
}

/// 사용자의 뱃지 **획득 기록**. 카탈로그([Badge])와 분리한다 —
/// 합치면 사용자 수 × 뱃지 수만큼 정의가 중복 저장된다.
@freezed
abstract class UserBadge with _$UserBadge {
  @JsonSerializable(fieldRename: FieldRename.snake, explicitToJson: true)
  const factory UserBadge({
    /// UUID. 서버 생성. `markBadgesSeen()`이 이 값으로 개별 행을 업데이트한다.
    required String id,
    required String userId,

    /// [Badge.id]. seasonal이면 템플릿이 아니라 **인스턴스** id다.
    required String badgeId,

    /// 획득 시각(UTC). 서버가 확정한다(클라이언트 시각은 신뢰 불가).
    required DateTime earnedAt,

    /// 서버 재검증 통과 여부(TRD §3.6). 기본값 false —
    /// 미검증 뱃지를 낙관적으로 "확정 획득"으로 표시하지 않기 위해서다.
    @Default(false) bool verified,

    /// 사용자가 획득 연출(PRD GM-02)을 이미 봤는지. 미확인 큐 처리에 쓴다.
    /// RLS상 클라이언트가 쓸 수 있는 **유일한** 컬럼이다.
    @Default(false) bool isSeen,

    /// 조인해서 함께 내려온 카탈로그 정보(선택). 별도 조회 왕복을 줄인다.
    Badge? badge,
  }) = _UserBadge;

  factory UserBadge.fromJson(Map<String, dynamic> json) =>
      _$UserBadgeFromJson(json);
}
```

### 3.3 `badge_criteria.dart` → `badge_condition.dart`로 대체

v1의 `BadgeCriteria`(12종 스칼라 지표)는 v2에서 성립하지 않는다. 새 파일이 갖는 것:

- 44개 `conditionType` **문자열 상수**
- 각 종류의 **판정 주체 분류**(`BadgeEvaluability`) — §4 표가 근거
- 진행률 표시용 **목표값 추출**(`targetOf`) 과 **비교 방향**(`BadgeCompareDirection`)

`BadgeCompareDirection`(atLeast/atMost)은 그대로 유지한다 — `pb_time_lte`,
`pace_avg_lte`, `pace_variance_lte`, `season_weekly_rank_lte`가 "작을수록 좋음"이라
진행률 비율을 뒤집어야 하는 v1의 문제가 v2에도 그대로 존재한다.

```dart
/// 판정을 누가 할 수 있는가.
enum BadgeEvaluability {
  /// 클라이언트가 로컬 기록만으로 **진행률을 추정**할 수 있다.
  /// (획득 확정은 여전히 서버 전용 — ARCHITECTURE 원칙 3)
  clientEstimable,

  /// 로컬 데이터가 부분적으로만 있어 추정이 크게 빗나갈 수 있다.
  /// 진행률 바를 그리지 말고 조건 텍스트만 보여준다.
  clientPartial,

  /// 서버 집계 없이는 값 자체를 알 수 없다(랭킹·티어·시즌 전역 집계·역지오코딩).
  serverOnly,
}
```

### 3.4 `BadgeVisuals` (신규, presentation 계층)

`iconAsset`/`sortOrder` 삭제를 메우는 표시 전용 헬퍼. 순수 함수만 둔다.

```dart
IconData iconFor(BadgeCategory c);   // 16종 → Material 아이콘
Color colorFor(String badgeGrade);   // 6종 → AppTokens 색 (미지값은 outline 폴백)
String labelFor(String badgeGrade);  // '브론즈' … '다이아몬드' / '스페셜'
int gradeOrder(String badgeGrade);   // 정렬 키: bronze0 … diamond4, special5
```

`AppTokens`에 `tierDiamond` / `tierSpecial` 색 토큰 2개 추가가 필요하다
(현재 bronze/silver/gold/platinum 4개뿐) — **flutter-ui-designer 확인 필요**.

---

## 4. 44개 `condition_type` 분류표

> 작업 지시서는 46개로 적혀 있었으나 `docs/badge-catalog.csv` 158행 실측 결과
> **distinct `condition_type`은 44개**다. (카테고리는 지시서대로 16개가 맞다.)

카테고리 한국어 라벨 → `BadgeCategory` 매핑도 함께 싣는다(backend 시드용).

| # | condition_type | n | CSV 카테고리 → enum | scope | trigger | 파라미터 키 | 판정 주체 | 비고 |
|---|---|---|---|---|---|---|---|---|
| 1 | `cumulative_distance_gte` | 14 | 누적거리 → `cumulativeDistance` | perm | cum | `distanceKm` | **client** | `AppUser.totalDistanceMeters` |
| 2 | `cumulative_count_gte` | 9 | 누적횟수 → `cumulativeCount` | perm | cum | `count` | **client** | `AppUser.totalRunCount` |
| 3 | `streak_weeks_gte` | 9 | 최장스트릭 → `longestStreak` | perm | cum | `weeks` | **client** | ⚠️ v1은 **일** 단위 스트릭만 계산한다. GM-05가 주 단위 확정이므로 `computeLongestStreakWeeks` 신규 필요 |
| 4 | `pb_first_achieved` | 6 | PB갱신 → `personalBest` | perm | ses | `distanceKm` | **client** | 해당 거리 최초 완주 |
| 5 | `pb_time_lte` | 14 | PB갱신 → `personalBest` | perm | ses | `distanceKm`,`seconds` | **client** | ⚠️ atMost |
| 6 | `session_distance_gte` | 5 | 단일세션거리 → `singleSessionDistance` | perm | ses | `distanceKm` | **client** | |
| 7 | `session_duration_gte` | 2 | 단일세션거리 → `singleSessionDistance` | perm | ses | `seconds` | **client** | |
| 8 | `session_start_hour_count_gte` | 9 | 시간대요일 → `timeOfDayWeekday` | perm | ses | `before`,`after`,`between`,`count`,`weekdayOnly` | **client** | KST 기준. 파라미터 조합이 가장 복잡 |
| 9 | `weekday_full_week_count_gte` | 2 | 시간대요일 → `timeOfDayWeekday` | perm | cum | `count` | **client** | 평일 5일 전부 |
| 10 | `weekend_both_days_count_gte` | 2 | 시간대요일 → `timeOfDayWeekday` | perm | cum | `count` | **client** | 토·일 모두 |
| 11 | `day_of_week_count_gte` | 1 | 시간대요일 → `timeOfDayWeekday` | perm | cum | `day`,`count` | **client** | `day`는 `MON` 등 |
| 12 | `day_of_week_diversity_gte` | 1 | 시간대요일 → `timeOfDayWeekday` | perm | cum | `distinctDays` | **client** | |
| 13 | `route_diversity_count_gte` | 3 | 경로탐험 → `routeExploration` | perm | cum | `distinctStartPoints` | *partial* | 시작점 클러스터링. 로컬에 전체 이력이 있어야 정확 |
| 14 | `elevation_gain_cumulative_gte` | 3 | 경로탐험 → `routeExploration` | perm | cum | `meters` | **client** | |
| 15 | `district_diversity_gte` | 2 | 경로탐험 → `routeExploration` | perm | cum | `distinctDistricts` | **SERVER** | 행정구역 **역지오코딩** 필요 |
| 16 | `loop_course_count_gte` | 1 | 경로탐험 → `routeExploration` | perm | cum | `count` | **client** | 출발·도착 근접 판정 |
| 17 | `calendar_date_match` | 9 | 특별한날 → `specialDay` | perm | ses | `type`,`date` | *partial* | `type=birthday`는 프로필 생일 필요 |
| 18 | `membership_anniversary_run` | 3 | 특별한날 → `specialDay` | perm | ses | `years` | **client** | 가입일 기준 |
| 19 | `pace_avg_lte` | 4 | 페이스속도 → `paceSpeed` | perm | ses | `secPerKm` | **client** | ⚠️ atMost |
| 20 | `pace_negative_split_count_gte` | 2 | 페이스속도 → `paceSpeed` | perm | ses | `count` | **client** | `RunSample` 필요 |
| 21 | `pace_final_km_faster_pct_gte` | 1 | 페이스속도 → `paceSpeed` | perm | ses | `pct` | **client** | `RunSample` 필요 |
| 22 | `pace_variance_lte` | 1 | 페이스속도 → `paceSpeed` | perm | ses | `pct` | **client** | ⚠️ atMost, `RunSample` 필요 |
| 23 | `device_source_count_gte` | 4 | 기기연동 → `deviceIntegration` | perm | ses | `source`,`count` | **client** | `source`는 `watchApple` 등 |
| 24 | `device_source_diversity_gte` | 1 | 기기연동 → `deviceIntegration` | perm | cum | `sources`(배열) | **client** | 값이 `watchApple_or_watchGarmin` 같은 **OR 표현식 문자열**이다 — 파서 규약 합의 필요 |
| 25 | `level_gte` | 9 | 레벨 → `level` | perm | cum | `level` | **SERVER** | GM-04 XP 공식 **미정**. 확정 전까지 판정 불가 |
| 26 | `season_tier_reached` | 4 | 시즌티어달성 → `seasonTier` | seas | cum | `tier` | **SERVER** | 티어는 서버가 단일 진실 원천(PRD §6) |
| 27 | `season_weekly_rank_lte` | 12 | 시즌주간랭킹 → `seasonWeeklyRank` | seas | cum | `tier`,`bucket` | **SERVER** | **상대평가 집계** — 티어 내 전체 사용자 필요. ⚠️ atMost |
| 28 | `season_cumulative_distance_gte` | 6 | 시즌누적거리 → `seasonCumulativeDistance` | seas | cum | `distanceKm` | *partial* | 시즌 경계 + 검증 통과 실외 기록만 합산 |
| 29 | `season_first_run` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | ses | — | *partial* | 시즌 컨텍스트 필요 |
| 30 | `season_weekly_attendance_full` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | cum | — | **SERVER** | 시즌 전 주차 집계 |
| 31 | `season_weekly_attendance_gte_pct` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | cum | `pct` | **SERVER** | 동상 |
| 32 | `season_first_run_within_days` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | ses | `days` | *partial* | 시즌 시작일 필요 |
| 33 | `season_pb_achieved` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | ses | — | *partial* | 시즌 내 PB |
| 34 | `season_best_week_distance_pb` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | cum | — | **SERVER** | 주간 집계 이력 필요 |
| 35 | `season_challenge_completed` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | cum | — | **SERVER** | 챌린지 완주 판정은 서버(P1) |
| 36 | `season_weekly_rank_rising_streak_gte` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | cum | `weeks` | **SERVER** | 랭킹 이력 |
| 37 | `season_max_tier_reached_before_pct` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | cum | `pct` | **SERVER** | 티어 + 시즌 진행률 |
| 38 | `season_comeback_run` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | ses | `gapWeeks` | *partial* | 공백 주 계산 |
| 39 | `season_first_long_distance` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | ses | `distanceKm` | *partial* | |
| 40 | `season_start_streak_weeks_gte` | 1 | 시즌한정이벤트 → `seasonEvent` | seas | cum | `weeks` | **SERVER** | 시즌 주차 경계 |
| 41 | `season_streak_weeks_gte` | 3 | 시즌한정이벤트 → `seasonEvent` | seas | cum | `weeks` | **SERVER** | 동상 |
| 42 | `season_final_week_active` | 1 | 시즌완주 → `seasonFinisher` | seas | cum | — | **SERVER** | 시즌 종료 주 판정 |
| 43 | `season_first_and_last_week_active` | 1 | 시즌완주 → `seasonFinisher` | seas | cum | — | **SERVER** | 동상 |
| 44 | `consecutive_seasons_participated_gte` | 2 | 시즌완주 → `seasonFinisher` | seas | cum | `seasons` | **SERVER** | 시즌 이력 전체 |

**집계: client 18 · partial 8 · SERVER 18.**

분류 기준:
- **client** = `GamificationStats` + 로컬 `RunRecord`/`RunSample` + `AppUser` 프로필만으로 값이 나온다.
- **partial** = 원리상 가능하지만 시즌 경계·검증 필터·전체 이력 중 하나가 로컬에 없어
  추정 오차가 크다. 진행률 바를 **그리지 않는다**.
- **SERVER** = 다른 사용자 집계(랭킹), 서버 확정 상태(티어), 외부 데이터(역지오코딩),
  미정 공식(레벨) 때문에 클라이언트가 원천적으로 계산할 수 없다.

⚠️ 어느 분류든 **획득 확정은 100% 서버다.** client 분류는 "진행률 바를 그려도 되는가"에
대한 답일 뿐이며, `UserBadge` 행이 생기기 전에는 미획득이다(ARCHITECTURE 원칙 3).

---

## 5. 파급 범위 — 수정이 필요한 파일

| 파일 | 조치 |
|------|------|
| `lib/models/enums.dart` | `BadgeCategory` 16종 교체, `BadgeTriggerType`/`BadgeScope` 추가, `BadgeTier` 삭제, `Tier` doc의 `[BadgeTier]` 참조 정리 |
| `lib/models/badge.dart` | §3.2로 전문 교체 |
| `lib/models/*.g.dart`, `*.freezed.dart` | `dart run build_runner build --delete-conflicting-outputs` 재생성 |
| `.../domain/badge_criteria.dart` | **삭제** → `badge_condition.dart` 신규(§3.3) |
| `.../domain/badge_progress.dart` | `criteriaType`/`threshold` → `conditionType`/`condition` 기반으로 재작성. `isLocked`(isSecret) 제거, `isActive` 필터 제거, 정렬을 `BadgeVisuals.gradeOrder` 기반으로 교체 |
| `.../data/supabase_gamification_repository.dart` | `.eq('is_active', true)` 삭제, `.order('sort_order')` → `.order('id')` (정렬은 클라이언트) |
| `.../presentation/badge_gallery_page.dart` | `_tierColor`/`_tierLabel`(BadgeTier) → `BadgeVisuals.colorFor/labelFor(String)`, `_categoryIcon` 16종 확장, 상세 시트의 `${badge.points}P` 제거 |
| `test/gamification/level_curve_test.dart` | `BadgeCriteria.*` 상수와 `all.length == 12` 단언이 전부 깨진다 → 새 `BadgeConditionType`으로 갱신 |
| `lib/core/theme/app_tokens.dart` | `tierDiamond`/`tierSpecial` 색 토큰 추가 |

`gamification_providers.dart`와 `core/repositories/gamification_repository.dart`는
`Badge`/`UserBadge`를 타입으로만 참조하므로 **수정 불필요**.

---

## 6. backend-engineer 인계 사항

1. **라이브 DB가 구식이다.** `badges`/`user_badges`는 아직
   `criteria_type`/`threshold`/`tier`/`icon_asset`/`points`/`sort_order`/`is_secret`/`is_active`
   컬럼을 갖고 있다. TRD의 `create table public.badges (...)`는 미배포 설계도다.
   → v2 마이그레이션 + 158종 시드가 필요하다. 기존 뱃지 데이터는 폐기 대상인지
   사용자 확인을 받는 편이 안전하다(획득 기록이 이미 있다면 badge_id 매핑 문제).
2. **`condition_type` CHECK 제약**은 §4의 44개 값으로 건다.
3. **`condition`은 jsonb.** 자주 쓰는 파라미터에 표현식 인덱스를 검토
   (`(condition->>'distanceKm')`).
4. **seasonal 인스턴스 발급 잡**이 필요하다 — 시즌 시작 시 41개 seasonal 템플릿을
   `{templateId}@{seasonId}` id로 복제하고 `season_id`를 채운다.
5. **판정 함수 구현은 backend가 이어받는다.** §4에서 SERVER로 분류된 18종은
   Postgres 집계로만 가능하다. client 18종도 서버가 **동일 규칙으로 재검증**해야 한다
   (ARCHITECTURE §7 — 순수 함수 규약).
6. **`camelCase ↔ snake_case` 매핑표(TRD §4.1) 갱신 필요**:
   `conditionType↔condition_type`, `badgeGrade↔badge_grade`, `triggerType↔trigger_type`,
   `seasonId↔season_id`, `isSeen↔is_seen`, `verified↔verified`.

---

## 7. 미해결 / 타 에이전트 확인 필요

| # | 항목 | 담당 |
|---|------|------|
| 1 | `level_gte` 9종 — **XP/레벨 공식 미정**(GM-04). 확정 전까지 판정 불가 | gamification-designer |
| 2 | `device_source_diversity_gte`의 `"watchApple_or_watchGarmin"` **OR 표현식 문자열** 파싱 규약 | gamification-designer + gps-tracking-engineer |
| 3 | `season_weekly_rank_lte`의 `bucket`(`top1` 등) 값 도메인 정의 | gamification-designer |
| 4 | 주 단위 스트릭(`computeLongestStreakWeeks`) — v1엔 일 단위만 있음. 1회 유예(freeze) 규칙(GM-05) 반영 필요 | gamification-designer |
| 5 | `district_diversity_gte` 역지오코딩 소스(어떤 행정구역 데이터?) | backend-engineer |
| 6 | 158개 뱃지 아트웍 — 준비되면 `String? iconAsset` nullable 추가로 무중단 전환 | flutter-ui-designer |
| 7 | `AppTokens.tierDiamond` / `tierSpecial` 색 토큰 | flutter-ui-designer |
| 8 | TRD §3.6에 `conditionType` 추가 반영 (현 스펙으로는 판정 디스패치 불가) | mobile-architect |

---

## 8. 이번 작업에서 코드가 적용되지 않은 이유

이 세션의 에이전트는 격리된 git worktree(`agent-a5a72fb811c1d4120`)에서 실행됐는데,
**Flutter 프로젝트 소스(`lib/`, `pubspec.yaml`, `test/`)는 그 worktree에 존재하지 않는다** —
공유 체크아웃(`phase-0-start-0f9ff3`)에 untracked 상태로만 있다.

- 공유 체크아웃의 파일 편집: worktree 격리 정책이 차단
- 소스를 이 worktree로 복사: 샌드박스 정책이 차단

따라서 §5의 편집, `build_runner` 재생성, `flutter analyze` 검증은 **수행되지 못했다.**
설계·분류·drop-in 코드는 이 문서에 전부 담았으므로, 공유 체크아웃에 접근 가능한
세션에서 §5 표대로 적용하면 된다.
