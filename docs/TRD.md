# Runnit TRD (Technical Requirements Document)

| 항목 | 내용 |
|------|------|
| 문서 버전 | v0.2 (초안) |
| 작성일 | 2026-08-25 |
| 작성자 | jehyun (Claude Code 하네스 산출) |
| 상태 | Phase 0 초안 — 구현 착수 전 검토 필요 |
| 근거 문서 | [`docs/PRD.md`](./PRD.md) v1.3 (확정), [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) v0.1 |

**변경 이력**
| 버전 | 변경 내용 |
|------|----------|
| v0.1 | 최초 작성. `docs/ARCHITECTURE.md`의 구조 결정을 구현 가능한 스펙(데이터 모델 코드, DDL, API, 검증 규칙)으로 세분화 |
| v0.2 | 뱃지 카탈로그 확장(30종 → 158개 템플릿) 설계 반영. `Badge`에 `category`(16종)·`scope`(permanent/seasonal)·`description`·`seasonId` 필드 추가, `tierLabel`→`badgeGrade`로 개명(시즌 티어 시스템과 명칭 혼동 방지). 카탈로그 원본은 `docs/badge-catalog.csv` |
| v0.3 | 뱃지 판정 실제 구현 완료(§10.1) — `runs` 트리거 기반 `evaluate_badges`/`evaluate_badge_condition`, `condition_type` 44→40종 중 사실상 전량 판정 가능. 시즌 뱃지 인스턴스 발급을 실제로 구현(`{templateId}@{seasonId}`, `ensure_season_badge_instances()`, §3.6 상단 정정 노트). 티어 도달 시각 이력 테이블 `tier_change_history` 신규 추가. 2026-08-26 사용자 요청으로 `seasonCumulativeDistance`/`seasonFinisher` 카테고리와 소속 뱃지 9종 삭제(158→148 템플릿, 16→14 카테고리, `condition_type` 44→40종) |

> 📌 **원천 우선순위**: PRD > ARCHITECTURE.md > 이 문서. 요구사항 ID(TR-xx, HI-xx 등)는 `docs/PRD.md` §5 기준.

---

## 1. 목적 및 범위

이 문서는 `docs/ARCHITECTURE.md`에서 정의한 구조를 **실제로 구현 가능한 수준**까지 구체화한다. 대상 범위는 PRD §11 로드맵의 **Phase 0**(아키텍처·데이터 모델·Supabase 스키마 확정) 산출물이며, Phase 1 착수 시 이 문서의 스키마/모델을 기준으로 코드를 작성한다.

---

## 2. 확정 기술 스택

PRD §7의 확정 스택을 실제 패키지 단위로 구체화한다.

| 영역 | 선택 | 패키지 | 비고 |
|---|---|---|---|
| 앱 프레임워크 | Flutter | — | iOS/Android 동시 출시, iOS 15+ / Android 8.0(API 26)+ |
| 상태관리 | Riverpod | `flutter_riverpod`, `riverpod_generator` | `StreamProvider`/`NotifierProvider`/`FutureProvider` 구분은 ARCHITECTURE §3.2 |
| 불변 모델·직렬화 | freezed | `freezed`, `json_serializable`, `freezed_annotation` | 수동 `toJson`/`fromJson` 금지 — 필드 추가 시 누락 방지 |
| GPS | `geolocator` | 백그라운드 지원, 정확도 옵션(`LocationAccuracy`) |
| 웨어러블 센서 | `health` | HealthKit(iOS)/Health Connect(Android) 통합 래퍼 |
| 권한 | `permission_handler` | iOS/Android 권한 흐름 통합 |
| 라우팅 | `go_router` | 딥링크, 중첩 라우트 |
| 지도 | `flutter_naver_map` | PRD §7 확정 — 국내 지도 품질·무료 한도 우위 |
| 차트 | `fl_chart` | 페이스/거리 추이(HI-02) |
| 백엔드 클라이언트 | `supabase_flutter` | Auth/Postgres/Realtime/Edge Function 호출 |
| 푸시 | Firebase Cloud Messaging | `firebase_messaging` | NT-01~08 |
| 로컬 영속 저장소 | 🔴 미정 (Hive / Drift / Isar 중 선정) | ARCHITECTURE §12-#1 — Phase 1 착수 시 결정 |
| 백엔드 인프라 | Supabase | Postgres + Auth + Realtime + Edge Functions (Deno) | |

---

## 3. 데이터 모델 사양 (Dart)

모든 모델은 `lib/models/`에 위치하며 `freezed` + `json_serializable`로 생성한다.

### 3.1 `RunSample` — 단일 GPS/센서 포인트

```dart
enum RunSampleSource { phone, watchApple, watchGarmin, watchOther }

@freezed
class RunSample with _$RunSample {
  const factory RunSample({
    required double lat,
    required double lng,
    required DateTime timestamp,
    double? altitude,
    double? accuracy,          // 미터 단위, 스무딩 판단에 사용
    int? heartRate,            // 웨어러블 연동 시에만 존재
    required RunSampleSource source,
  }) = _RunSample;

  factory RunSample.fromJson(Map<String, dynamic> json) => _$RunSampleFromJson(json);
}
```

- `accuracy`는 GPS 스무딩(§8.2) 판정에 쓰인다.

#### 3.1.1 소스 축과 벤더 축의 분리 (2026-08-26 확정 · 구현 반영됨)

위 초안은 `source` **한 축**에 "어떤 경로로 들어왔나"와 "어느 기기가 만들었나"를 함께 담았다. 구현하면서 **직교하는 두 축으로 분리**했다.

| 축 | 타입 | 답하는 질문 | 값 | 위치 |
|---|---|---|---|---|
| 소스 | `RunSampleSource` / pg `run_sample_source` | 어떤 경로로 **언제** 들어왔나 | `phone` / `watch`(실시간) / `external`(사후 동기화) | 샘플 단위 + `runs.sources` |
| 벤더 | `DeviceVendor` / pg `device_vendor` | **어느 기기**가 만들었나 | `phone` / `watchApple` / `watchGarmin` / `watchOther` / `unknown` | **러닝 단위** `runs.device_vendors` |

**분리 사유**
- 한 축으로 접으면 `watchGarminLive` × `watchGarminImported` 식으로 값이 곱해진다. Garmin은 항상 동기화 경유(§8.4)라 벤더와 실시간성의 상관이 높지만 **동치는 아니다** — Apple Watch 워크아웃도 나중에 HealthKit에서 통째로 임포트하면 `external`이 된다.
- 실시간성 축은 이미 UI 계약("워치 데이터는 동기화 후 반영됩니다" 배너)이 소비 중이라 벤더로 덮어쓸 수 없다.

**벤더를 샘플이 아니라 러닝 단위에 두는 이유**
1. 뱃지 조건(`device_source_count_gte` = "애플워치로 누적 50회")이 전부 **러닝 단위 집계**다.
2. 폰 GPS + 워치 심박 세션에서 좌표는 전부 폰이 만든다. 샘플마다 벤더를 달면 3600개 샘플에 상수를 복제하는 셈이다.
3. 한 세션에 두 기기가 동시에 기여하는 것이 P1의 기본 경로이므로 **배열**이어야 한다. 스칼라 `device_vendor` 하나로는 그 세션을 폰 기록이라 부를지 워치 기록이라 부를지 손실 없이 표현할 수 없다.

**값 문자열 규약 — 이 목록이 최종 확정본이다.** `phone` / `watchApple` / `watchGarmin` / `watchOther` / `unknown`. 프로젝트의 snake_case 규약에 대한 **유일한 예외**이며, 사유는 이미 시드된 뱃지 카탈로그(`docs/badge-catalog.csv`, `badge_catalog.condition_value` jsonb, `device_watchApple_1` 같은 뱃지 id(PK))가 camelCase를 쓰고 있기 때문이다. 저장 라벨을 따로 두면 토큰↔라벨 매핑이 어긋날 때 **뱃지가 조용히 미지급**된다. 따라서 **뱃지 조건 토큰 / Postgres enum 라벨 / Dart `@JsonValue` / `wire_enums.dart` 네 곳을 같은 문자열로 통일**하고 매핑 테이블을 두지 않는다.

**벤더 판별 시점** — 폰 단독 러닝은 세션 시작 시점부터 `phone` 확정. 워치는 HealthKit `sourceRevision.source.bundleIdentifier`/Health Connect `dataOrigin.packageName`에서 **지표가 도착하는 즉시**(실시간 경로) 또는 **워크아웃 임포트 시점**(P1)에 확정한다. 판별 한계는 §8.4.1.

### 3.2 `RunRecord` — 완결된 러닝 세션

```dart
enum RunRecordType { outdoor, treadmill, manual }

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
    required RunRecordType type,
    int? avgHeartRate,
    double? estimatedCalories,
    String? title,
    String? memo,
    @Default(false) bool hasRouteSamples,  // PRD §5.7 반영 판정 기준 — 서버가 최종 확정
    @Default(false) bool flagged,          // 서버 재검증 결과, 클라이언트는 읽기 전용
  }) = _RunRecord;

  factory RunRecord.fromJson(Map<String, dynamic> json) => _$RunRecordFromJson(json);
}
```

- `deviceVendors: List<DeviceVendor>` (§3.1.1): 이 세션에 기여한 기기 벤더. 폰 단독 = `[phone]`, 폰+애플워치 = `[phone, watchApple]`, 워치 워크아웃 임포트 = `[watchApple]`, 수동 입력 = `[]`(빈 배열은 `[phone]`과 **다른 뜻**). 뱃지 `device_source_count_gte`/`device_source_diversity_gte`의 원천이며, "폰 단독 기록"은 `== [phone]`(정확히 일치), "워치 사용"은 `watchApple`/`watchGarmin` **포함** 여부로 판정한다. enum 선언 순서로 정렬해 payload를 결정적으로 유지한다.
- `hasRouteSamples`: 클라이언트가 잠정 세팅하지만 **서버가 업로드 시점에 재검증하여 최종값을 확정**한다(ARCHITECTURE §6.3). 이 필드가 `false`면 `type`과 무관하게 티어·랭킹 미반영.
- `flagged`: §8 서버 검증 실패 시 서버가 설정. 클라이언트에서 직접 쓰지 않는다.
- 랩 기록(TR-07, 1km 구간)은 `samples`로부터 파생 계산하며 별도 저장 필드를 두지 않는다(중복 저장 방지) — 필요 시 조회 시점에 계산하거나, 성능 이슈가 확인되면 `laps: List<LapSplit>` 캐시 필드를 추가한다.

### 3.3 `User` (`Profile`)

```dart
@freezed
class UserProfile with _$UserProfile {
  const factory UserProfile({
    required String id,               // == auth.uid()
    required String displayName,
    String? photoUrl,
    double? weightKg,                 // 칼로리 계산(TR-06)에 필요
    double? weeklyGoalKm,
    required double totalDistanceMeters,   // 캐시 필드, 서버 트리거로 갱신
    required int totalRunCount,
    required DateTime createdAt,
    @Default(ProfileVisibility.public) ProfileVisibility visibility,  // AC-05
  }) = _UserProfile;

  factory UserProfile.fromJson(Map<String, dynamic> json) => _$UserProfileFromJson(json);
}

enum ProfileVisibility { public, private }
```

### 3.4 `Season` / `UserSeasonTier`

```dart
enum Tier { bronze, silver, gold, platinum }

@freezed
class Season with _$Season {
  const factory Season({
    required String id,          // 예: '2026-Q3'
    required DateTime startsAt,
    required DateTime endsAt,
    @Default(false) bool isShortened,  // 첫 시즌/말 시즌 단축 여부 (PRD §8.5)
  }) = _Season;

  factory Season.fromJson(Map<String, dynamic> json) => _$SeasonFromJson(json);
}

@freezed
class UserSeasonTier with _$UserSeasonTier {
  const factory UserSeasonTier({
    required String userId,
    required String seasonId,
    required double cumulativeDistanceMeters,  // 절대평가 기준값
    required Tier currentTier,
    required DateTime tierUpdatedAt,
  }) = _UserSeasonTier;

  factory UserSeasonTier.fromJson(Map<String, dynamic> json) => _$UserSeasonTierFromJson(json);
}

/// 티어 기준선 (PRD §5.3.2 확정)
const Map<Tier, double> tierThresholdsMeters = {
  Tier.bronze: 0,
  Tier.silver: 25000,
  Tier.gold: 100000,
  Tier.platinum: 250000,
};
```

### 3.5 `RankingEntry` (`WeeklyRankingCache`)

```dart
@freezed
class RankingEntry with _$RankingEntry {
  const factory RankingEntry({
    required String userId,
    required Tier tier,                  // 랭킹 스코프 파티션 키 — PRD §5.4
    required String weekId,               // 예: '2026-W34' (KST 월~일)
    required double weeklyDistanceMeters,
    required int rank,
    required int tierParticipantCount,    // "상위 N%" 계산용 (PRD RK-04)
    required DateTime computedAt,
  }) = _RankingEntry;

  factory RankingEntry.fromJson(Map<String, dynamic> json) => _$RankingEntryFromJson(json);
}
```

동점 처리(PRD §8.2)는 서버 집계 쿼리에서 `(weeklyDistanceMeters desc, runCount asc, firstReachedAt asc, totalDuration asc)` 순서로 정렬해 `rank`를 확정한다 — 클라이언트는 산정하지 않는다.

> ⚠️ **구현 갱신(2026-08-25, 시즌 뱃지 활성화)**: 아래 §3/§4의 `seasons` / `user_season_tier` /
> `weekly_ranking_cache` 테이블 설계는 **실제로 만들어지지 않았다**. 실제 구현(마이그레이션
> 19~24, 31, 32)은 다음으로 대체됐다 — 이 문서가 실제 스키마와 어긋난 채 방치되지 않도록
> 여기 명시한다:
> - `seasons` → `season_id_at(ts)` / `season_start(id)` / `season_end(id)` 순수 계산 함수
>   (분기는 달력에서 결정론적으로 유도되고 운영자가 조정할 절차가 없어 테이블이 불필요하다는
>   판단, 마이그레이션 20).
> - `user_season_tier` → `profiles.current_tier` / `profiles.season_distance_meters` /
>   `profiles.tier_season_id` (마이그레이션 19, 22) + 시즌 마감 스냅샷은
>   `season_histories`(마이그레이션 21)에 남는다.
> - `weekly_ranking_cache` → 기존 `leaderboard_entries`를 그대로 재사용
>   (`period='weekly', metric='distance', scope='global', tier=<티어>`). 5분 주기로 티어별
>   4개 보드가 갱신되고(마이그레이션 23 `refresh_all_leaderboards`), 지난 주차 행은 삭제되지
>   않고 누적 보존된다.
> - `badges.season_id`는 `seasons` FK가 아니라 `season_id_at`과 같은 정규식(`^\d{4}-Q[1-4]$`)으로만
>   검증되는 text 컬럼이다(마이그레이션 25 `badges_season_id_scope`).
> - 시즌 뱃지 인스턴스 id는 `{templateId}_{season}` 이 아니라 **`{templateId}@{seasonId}`**
>   형식이다(예: `stier_platinum@2026-Q3`) — `badges_id_slug_format` CHECK가 `@`를 구분자로 허용.
>   인스턴스 발급은 `ensure_season_badge_instances()`가 담당하며 `evaluate_badges` /
>   `sync_my_season` / `reset_stale_seasons` 3개 진입점에서 멱등 호출된다(마이그레이션 31).
> - `evaluate_badge_condition`의 seasonal 19종은 마이그레이션 32에서 18종, 마이그레이션
>   33/34에서 나머지 1종(`season_max_tier_reached_before_pct`)까지 전부 실제 판정으로
>   구현됐다. 이 마지막 1종은 `profiles.current_tier`/`season_histories`만으로는 "시즌 중
>   특정 티어에 처음 도달한 시각"을 알 수 없어(전자는 현재 상태만, 후자는 시즌 마감
>   스냅샷만 보유) 신규 테이블 `public.tier_change_history(user_id, season_id, tier,
>   reached_at)`를 추가했다 — `recompute_season_tier`(마이그레이션 22)가 티어 판정 후
>   **직전보다 실제로 상승했을 때만**(enum 비교, 하드코딩 없음) 이 테이블에 최초 1행을
>   기록한다(UNIQUE(user_id, season_id, tier) + ON CONFLICT DO NOTHING이 동시성 안전망).
>   같은 시즌에 유지·강등 시에는 기록하지 않는다. `season_max_tier_reached_before_pct`는
>   `enum_range(null::public.tier)`에서 유도한 "최고 티어"(하드코딩 금지) 도달 시각을
>   `season_start + (season_end - season_start) * pct/100.0`과 비교한다.
>   ⚠️ **소급 불가**: 이 테이블은 2026-08-25(마이그레이션 33/34) 이후의 상승분만 담는다.
>   그 이전에 이미 어떤 티어에 도달해 있던 기존 유저는 도달 "시각"을 역산할 근거가
>   없어(season_histories는 마감 스냅샷뿐) 이력이 소급 생성되지 않는다 — 근사치도 만들지
>   않았다(false negative만 발생, 오지급 없음). 이후 실제로 다시 그 티어로 오르는 순간부터
>   (예: 다음 시즌, 또는 강등 후 재상승) 정확하게 기록된다.

### 3.6 `Badge` / `UserBadge`

뱃지 카탈로그(148개 템플릿, 14개 카테고리 — 2026-08-26 `seasonCumulativeDistance`/`seasonFinisher`
카테고리와 소속 뱃지 9종을 사용자 요청으로 삭제해 158/16에서 축소)의 확정 스펙은
[`docs/badge-catalog.csv`](./badge-catalog.csv) 참고. `category`·`scope`는 이 카탈로그에서 역산한 필드다.

```dart
enum BadgeTriggerType { session, cumulative }

/// 영구 뱃지(평생 누적 기준, 딱 한 번만 존재) vs 시즌 뱃지(시즌 스코프 판정,
/// 시즌마다 새 인스턴스 재발급 가능 — 획득한 인스턴스는 영구 보존).
enum BadgeScope { permanent, seasonal }

enum BadgeCategory {
  cumulativeDistance,        // 누적거리 (permanent)
  cumulativeCount,           // 누적횟수 (permanent)
  longestStreak,             // 최장스트릭 (permanent)
  personalBest,              // PB갱신 (permanent, 검증된 실외 기록만)
  singleSessionDistance,     // 단일세션거리 (permanent)
  timeOfDayWeekday,          // 시간대요일 (permanent)
  routeExploration,          // 경로탐험 (permanent, GPS 기반)
  specialDay,                // 특별한날 (permanent)
  paceSpeed,                 // 페이스속도 (permanent)
  deviceIntegration,         // 기기연동 (permanent)
  level,                     // 레벨 (permanent) — XP 공식 미정, 값은 GM-04 별도 설계 후 확정
  seasonTier,                // 시즌티어달성 (seasonal, GM-07)
  seasonWeeklyRank,          // 시즌주간랭킹 (seasonal, RK-06)
  seasonEvent,               // 시즌한정이벤트 (seasonal, GM-08 P1)
  // seasonCumulativeDistance/seasonFinisher는 2026-08-26 사용자 요청으로
  // 카테고리·소속 뱃지 9종(sdist_*/sfin_*, 마이그레이션 35)을 완전히 삭제했다.
}

@freezed
class Badge with _$Badge {
  const factory Badge({
    required String id,        // slug, 예: 'dist_cum_1000km'
    required String name,      // 표시명 (예: '천리길') — badge-catalog.csv의 display_name
    required String description, // 획득 조건 설명 — 뱃지 갤러리 상세(GM-03)에 노출
    required BadgeCategory category,
    required BadgeScope scope,
    required BadgeTriggerType triggerType,
    required String conditionType,             // 판정 함수 **디스패치 키**. badge-catalog.csv의
                                                 // condition_type 열과 1:1 (현재 40종).
                                                 // condition 맵만으로는 어느 판정 함수를 쓸지 알 수 없다.
    @Default(<String, dynamic>{})
    Map<String, dynamic> condition,            // 판정 함수 입력 파라미터. 키 집합은 conditionType마다
                                                 // 다르다 (예: cumulative_distance_gte → {"distanceKm": 1000},
                                                 // season_weekly_rank_lte → {"tier": "gold", "bucket": "top1"}).
                                                 // 파라미터가 없는 종류는 {} — NULL도 {}와 동치로 취급한다.
    required String badgeGrade,                // bronze/silver/gold/platinum/diamond/special — 뱃지 자체 표시 등급.
                                                 // ⚠️ scope=seasonal인 시즌티어달성(stier_*) 4종을 제외하면
                                                 // 실제 시즌 티어 시스템과 무관한 순수 장식용 값이다.
    String? seasonId,          // scope=seasonal 템플릿이 시즌 시작 시 실제 발급된 인스턴스일 때만 값 존재
                                 // (예: '2026-Q3'). 카탈로그의 템플릿 자체는 null.
  }) = _Badge;

  factory Badge.fromJson(Map<String, dynamic> json) => _$BadgeFromJson(json);
}

@freezed
class UserBadge with _$UserBadge {
  const factory UserBadge({
    required String id,              // UUID. 서버 생성 — markBadgesSeen()이 이 값으로 개별 행을 갱신한다.
    required String userId,
    required String badgeId,         // seasonal이면 템플릿이 아니라 인스턴스 id (`{templateId}@{seasonId}`)
    required DateTime earnedAt,
    @Default(false) bool verified,   // 서버 재검증 결과
    @Default(false) bool isSeen,     // 획득 연출(GM-02)을 봤는지. RLS상 클라이언트가 쓸 수 있는 유일한 컬럼.
    Badge? badge,                    // 조인 임베드(선택) — 갤러리 조회 왕복 절감
  }) = _UserBadge;

  factory UserBadge.fromJson(Map<String, dynamic> json) => _$UserBadgeFromJson(json);
}
```

### 3.7 판정 로직 — 순수 함수 시그니처 (클라이언트/서버 공유 규칙)

```dart
/// 클라이언트에서 잠정 판정, 서버(Edge Function/SQL)가 동일 규칙으로 재검증.
bool isTierPromotion({
  required Tier currentTier,
  required double cumulativeDistanceMeters,
}) {
  final next = Tier.values.elementAtOrNull(currentTier.index + 1);
  if (next == null) return false;
  return cumulativeDistanceMeters >= tierThresholdsMeters[next]!;
}

/// 뱃지 조건 판정 — 순수 함수. 부수효과 없음(gamification-designer 협약).
bool evaluateBadgeCondition(Badge badge, Map<String, num> context);
```

Edge Function은 Deno/TypeScript로 작성되므로 위 로직은 **동일한 임계값 상수**(`tierThresholdsMeters` 등)를 양쪽에 중복 정의하되, TRD가 단일 진실 원천 역할을 하도록 값 변경 시 이 문서를 함께 갱신한다.

---

## 4. Supabase 스키마 사양 (DDL)

```sql
-- ─────────────────────────────────────────────
-- 1. profiles (auth.users 확장)
-- ─────────────────────────────────────────────
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  photo_url text,
  weight_kg numeric,
  weekly_goal_km numeric,
  total_distance_m numeric not null default 0,   -- 캐시, 트리거로 갱신
  total_run_count integer not null default 0,    -- 캐시, 트리거로 갱신
  visibility text not null default 'public' check (visibility in ('public','private')),
  created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- 2. run_records / run_samples
-- ─────────────────────────────────────────────
create table public.run_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  distance_m numeric not null,
  duration_s integer not null,
  type text not null check (type in ('outdoor','treadmill','manual')),
  avg_heart_rate integer,
  estimated_calories numeric,
  title text,
  memo text,
  has_route_samples boolean not null default false,  -- 서버가 검증 후 확정 (PRD §5.7)
  flagged boolean not null default false,             -- 서버 재검증 실패 시 true
  flag_reason text,
  created_at timestamptz not null default now()
);

-- 초기엔 jsonb로 시작(ARCHITECTURE §12-#4). 샘플 수 증가 시 별도 테이블 분리 검토.
create table public.run_samples (
  run_record_id uuid not null references public.run_records(id) on delete cascade,
  seq integer not null,               -- 세션 내 순번
  lat double precision not null,
  lng double precision not null,
  ts timestamptz not null,
  altitude numeric,
  accuracy numeric,
  heart_rate integer,
  source text not null check (source in ('phone','watch_apple','watch_garmin','watch_other')),
  primary key (run_record_id, seq)
);

create index idx_run_records_user_started on public.run_records (user_id, started_at desc);

-- ─────────────────────────────────────────────
-- 3. seasons / user_season_tier  (절대평가, 시즌 단위)
-- ─────────────────────────────────────────────
create table public.seasons (
  id text primary key,              -- '2026-Q3'
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_shortened boolean not null default false
);

create table public.user_season_tier (
  user_id uuid not null references public.profiles(id) on delete cascade,
  season_id text not null references public.seasons(id),
  cumulative_distance_m numeric not null default 0,
  current_tier text not null default 'bronze'
    check (current_tier in ('bronze','silver','gold','platinum')),
  tier_updated_at timestamptz not null default now(),
  primary key (user_id, season_id)
);

create index idx_user_season_tier_season_tier on public.user_season_tier (season_id, current_tier);

-- ─────────────────────────────────────────────
-- 4. weekly_ranking_cache  (상대평가, 티어 내, 주 단위)
--    ⚠️ user_season_tier와 절대 병합하지 않는다 — 집계 주기·평가 방식이 다름 (ARCHITECTURE §4)
-- ─────────────────────────────────────────────
create table public.weekly_ranking_cache (
  user_id uuid not null references public.profiles(id) on delete cascade,
  season_id text not null references public.seasons(id),
  week_id text not null,             -- '2026-W34' (KST 월~일 기준)
  tier text not null check (tier in ('bronze','silver','gold','platinum')),
  weekly_distance_m numeric not null default 0,
  run_count integer not null default 0,
  rank integer,
  tier_participant_count integer,
  computed_at timestamptz not null default now(),
  primary key (user_id, week_id)
);

create index idx_weekly_ranking_tier_week on public.weekly_ranking_cache (season_id, week_id, tier, rank);

-- ─────────────────────────────────────────────
-- 5. badges / user_badges
-- ─────────────────────────────────────────────
create table public.badges (
  id text primary key,               -- 'dist_cum_1000km' 같은 slug. scope='seasonal' 인스턴스는 'stier_platinum_2026q3'처럼 season_id를 slug에 포함
  name text not null,                -- 표시명 (badge-catalog.csv의 display_name)
  description text not null,
  category text not null,            -- BadgeCategory 값 (예: 'cumulativeDistance')
  scope text not null check (scope in ('permanent','seasonal')),
  trigger_type text not null check (trigger_type in ('session','cumulative')),
  condition jsonb not null,
  badge_grade text not null default 'bronze',  -- 표시용 등급. 시즌티어달성 카테고리 제외 시즌 티어 시스템과 무관
  season_id text references public.seasons(id)  -- scope='seasonal' 템플릿이 실제 발급된 인스턴스일 때만 not null
);

create table public.user_badges (
  user_id uuid not null references public.profiles(id) on delete cascade,
  badge_id text not null references public.badges(id),
  earned_at timestamptz not null default now(),
  verified boolean not null default false,
  revoked boolean not null default false,   -- 부정 기록 판정 시 회수 (PRD §8.1)
  primary key (user_id, badge_id)
);
```

### 4.1 camelCase ↔ snake_case 매핑

| Dart 필드 | Postgres 컬럼 | 타입 | 비고 |
|---|---|---|---|
| `RunRecord.distanceMeters` | `run_records.distance_m` | numeric | |
| `RunRecord.duration` (`Duration`) | `run_records.duration_s` | integer | 초 단위 변환 |
| `RunRecord.avgHeartRate` | `run_records.avg_heart_rate` | integer nullable | |
| `RunRecord.hasRouteSamples` | `run_records.has_route_samples` | boolean | 서버가 최종 확정 |
| `RunSample.source` (`RunSampleSource`) | `run_samples.source` | text (enum check) | `watchApple` → `'watch_apple'` |
| `UserSeasonTier.cumulativeDistanceMeters` | `user_season_tier.cumulative_distance_m` | numeric | |
| `RankingEntry.weeklyDistanceMeters` | `weekly_ranking_cache.weekly_distance_m` | numeric | |
| `RankingEntry.tierParticipantCount` | `weekly_ranking_cache.tier_participant_count` | integer | |
| `UserProfile.totalDistanceMeters` | `profiles.total_distance_m` | numeric | 트리거 갱신 캐시 |
| `Badge.conditionType` | `badges.condition_type` | text (check, 40종) | 판정 함수 디스패치 키 |
| `Badge.condition` | `badges.condition` | jsonb | 키 집합은 `condition_type`마다 다름 |
| `Badge.badgeGrade` | `badges.badge_grade` | text (check, 6종) | 표시용 등급 — 경쟁 `Tier`와 무관 |
| `Badge.triggerType` | `badges.trigger_type` | text (enum check) | `session` / `cumulative` |
| `Badge.scope` | `badges.scope` | text (enum check) | `permanent` / `seasonal` |
| `Badge.category` | `badges.category` | text (enum check, 14종) | CSV의 한국어 라벨은 시드 시 snake_case 영문으로 매핑 |
| `Badge.seasonId` | `badges.season_id` | text nullable | seasonal **인스턴스**일 때만 값 존재 |
| `Badge.name` | `badges.name` | text | 시드 원천은 CSV `display_name` 열이다 (`functional_name` 열은 **시드하지 않는다** — Dart 모델에 대응 필드가 없고 `description`이 상위집합) |
| `UserBadge.id` | `user_badges.id` | uuid | 서버 생성. `markBadgesSeen()`이 이 값으로 개별 행을 갱신 |
| `UserBadge.userId` | `user_badges.user_id` | uuid | |
| `UserBadge.badgeId` | `user_badges.badge_id` | text FK → `badges.id` | seasonal이면 템플릿이 아니라 **인스턴스** id |
| `UserBadge.earnedAt` | `user_badges.earned_at` | timestamptz | 서버가 확정(클라이언트 시각 불신) |
| `UserBadge.verified` | `user_badges.verified` | boolean | 서버 재검증 결과 |
| `UserBadge.isSeen` | `user_badges.is_seen` | boolean | 클라이언트가 쓸 수 있는 유일한 컬럼 |
| *(대응 필드 없음)* | `user_badges.revoked` | boolean | **서버 전용.** 부정 기록 회수(PRD §8.1) — 행은 남기고 플래그만 세운다. 타인 조회 RLS 술어에 쓰인다 |
| *(대응 필드 없음)* | `user_badges.source_run_id` | uuid nullable | **서버 전용 감사 컬럼.** 회수 판정 시 "어느 기록 때문에 지급됐나" 추적용 |

> 서버 전용 컬럼(`revoked` / `source_run_id`)은 `select *`로 클라이언트에 내려가지만
> `json_serializable`이 미지 키를 무시하므로 무해하다. Dart 모델에 추가하지 않는다 —
> 클라이언트가 회수 여부를 렌더링할 이유가 없고(타인 것은 애초에 RLS가 가린다),
> 필드를 늘리면 서버 전용이라는 경계가 흐려진다.

이 표는 필드 추가 시마다 갱신한다 — 암묵적 매핑은 QA 단계에서 필드 불일치 버그로 드러난다(`backend-engineer` 작업 원칙).

---

## 5. RLS 정책 사양

| 테이블 | select | insert/update | 근거 |
|---|---|---|---|
| `profiles` | 본인 전체, 타인은 `visibility='public'` 필드만 (AC-03/AC-05) | 본인만 (`id = auth.uid()`) | |
| `run_records` / `run_samples` | 본인 것만 | 본인만, `user_id = auth.uid()` | 랭킹 공개는 캐시 테이블 경유 |
| `seasons` | 전체 공개 | service role만 | 시즌 정의는 공용 참조 데이터 |
| `user_season_tier` | 전체 공개(랭킹/프로필 노출용) | service role만 (Edge Function) | 클라이언트가 직접 갱신 불가 — 절대평가 신뢰성 |
| `weekly_ranking_cache` | 전체 공개 | service role만 | |
| `badges` | 전체 공개 | service role만(운영 도구) | 카탈로그는 정적 |
| `user_badges` | 본인 전체, 타인은 `revoked=false and verified=true`만 | insert는 service role만 | 클라이언트가 직접 뱃지를 확정할 수 없음(PRD §8.4 원칙) |

---

## 6. API / Edge Function 사양

### 6.1 `POST /functions/v1/upload-run-record`

**요청**
```json
{
  "runRecord": { "startedAt": "...", "endedAt": "...", "type": "outdoor", "...": "..." },
  "samples": [ { "lat": 37.5, "lng": 127.0, "ts": "...", "source": "phone" } ]
}
```

**처리 순서**
1. 원시 `samples`로 거리·페이스 재계산 (§7 검증 규칙 적용).
2. 검증 통과 시:
   - `run_records`/`run_samples` insert (`flagged=false`).
   - `type='outdoor'` 이고 경로 샘플 존재 시 → `user_season_tier.cumulative_distance_m` 즉시 갱신 → 승급 판정(§3.7 규칙과 동일 임계값) → 승급 시 전용 뱃지 지급.
   - `weekly_ranking_cache`에 해당 주 누적 거리 증분 반영(동기 갱신 or 다음 배치 사이클에 반영 — ARCHITECTURE §5.3 2단계 이후 결정).
3. 검증 실패/의심 시: `flagged=true`, `flag_reason` 기록, 티어·랭킹 미반영. 업로드 자체는 `2xx`로 성공 응답(기록은 보존).
4. 뱃지 판정 함수 재실행(세션형 + 누적형 모두).

**응답**
```json
{
  "runRecordId": "...",
  "flagged": false,
  "tierPromotion": { "from": "bronze", "to": "silver" },
  "newBadges": ["cumulative_100km"]
}
```

### 6.2 `GET /functions/v1/weekly-ranking?tier=silver&weekId=2026-W34`

`weekly_ranking_cache`에서 조회. 배치 갱신 주기를 벗어나지 않는 한 Postgres 직접 select로도 충분 — 별도 Edge Function 없이 PostgREST(Supabase 자동 API)로 대체 가능(§9 참고).

### 6.3 배치 함수 — 랭킹 캐시 갱신 (`pg_cron` 트리거)

5분 주기로 실행되는 스케줄 함수. 활성 시즌·주(week)에 대해 티어별로 파티션하여 `rank`를 재계산한다(§7 동점 규칙 적용). 초기 구현은 SQL 윈도우 함수(`rank() over (partition by season_id, week_id, tier order by ...)`)로 충분하며, 별도 배치 엔진 없이 Edge Function + `pg_cron`으로 처리한다.

### 6.4 시즌 경계 배치 (`season-rollover`)

역년 분기 시작 시각(1/4/7/10월 1일 00:00 KST)에 실행:
1. 종료된 시즌의 `user_season_tier.current_tier`를 이력 테이블(HI-06, 별도 `season_history` 또는 `user_season_tier` 자체를 이력으로 유지)로 보존.
2. 신규 `seasons` row 생성.
3. 신규 시즌의 `user_season_tier`는 필요 시점(첫 기록 업로드)에 지연 생성(lazy insert)하거나, 활성 사용자 전원에 대해 `bronze`/`0`으로 미리 생성 — 운영 부하 대비 후자를 권장(랭킹 조회 시 NULL 분기 처리를 피함).
4. D-14/D-3 알림(NT-03)은 이 배치가 아니라 별도 스케줄(시즌 종료 14일/3일 전) 함수에서 발행.

---

## 7. 서버 검증 규칙 (PRD §8.4 기술 스펙화)

| 검사 | 기준값 | 구현 |
|---|---|---|
| 비현실적 평균 페이스 | 평균 3:00/km 미만(= 20km/h 초과 평균 속도) | `distance_m / duration_s` 재계산 후 판정 |
| 순간 속도 이상 | 인접 샘플 간 구간 속도 25km/h 초과 | 샘플 페어별 Haversine 거리 / 시간차. 초과 구간은 제거 후 총거리 재계산 |
| 시간 대비 거리 불일치 | 샘플 타임스탬프 역행, 또는 `ended_at - started_at`과 샘플 시간 범위 모순 | 기록 거부(422) |
| 중복 업로드 | 동일 `user_id` + 시간대 겹침 기존 `run_record` 존재 | 기존 기록과 병합 제안 또는 거부 |
| GPS 샘플 부재 | `samples.length == 0` 이면서 `distance_m > 0` | `has_route_samples=false` → 수동 기록 분류 |
| 경로 비현실성 | 연속 3개 이상 샘플이 완전 직선 + 등간격(순간이동 패턴) | 플래그, 수동 검토 큐(운영 콘솔, Phase 1 이후) |
| 다계정 의심 | 동일 기기 식별자로 다수 계정의 유사 경로 반복 | Phase 4 대상 — 현재는 로깅만, 포인트 없음 |

**동점 처리 정렬 규칙 (PRD §8.2, `weekly_ranking_cache` 계산 쿼리에 반영)**
```sql
order by weekly_distance_m desc, run_count asc, first_reached_at asc, total_duration_s asc
```

---

## 8. GPS/웨어러블 기술 사양

### 8.1 권한 요청 순서

1. `permission_handler`로 `whenInUse` 위치 권한 요청 (앱 최초 진입 시, 왜 필요한지 설명 화면 선행).
2. 러닝 시작(`[START]`) 시점에 `always` 권한 승격 요청 — Android는 포그라운드/백그라운드 위치 권한이 분리되어 있으므로 별도 요청.
3. 웨어러블 연동은 `health` 패키지의 HealthKit/Health Connect 권한을 **독립된 플로우**로 요청(위치 권한과 섞지 않음).

### 8.2 백그라운드 트래킹

- **Android**: Foreground Service(`type=location`) 사용. 알림 상시 노출로 OS의 강제 종료 방지.
- **iOS**: Background Modes `location` 활성화. `CLLocationManager`의 `allowsBackgroundLocationUpdates=true`.
- 권한 거부 시 백그라운드 트래킹 없이 포그라운드 트래킹만으로 우아하게 저하(degrade)한다 — 트래킹 자체를 막지 않는다.

### 8.3 GPS 스무딩 파라미터

- 알고리즘: 이동평균 또는 Kalman filter(구현 난이도 대비 이동평균으로 시작, 정확도 이슈 발생 시 Kalman으로 승격).
- 이상치 판정: `accuracy > 20m`인 샘플은 거리 계산에서 제외. 순간 속도 25km/h 초과 구간은 제거(§7과 동일 기준 클라이언트 1차 필터).
- 거리 계산: 스무딩된 연속 포인트 간 Haversine 공식 누적.
- 페이스: `duration / distance_km`(분/km), 1km 구간별 split 별도 계산(TR-07).
- 칼로리: MET 기반 추정 — `weightKg`, 평균 페이스 활용. 심박수 있으면 정교화(P1, WR-05 연동 후).

### 8.4 웨어러블 연동 경로 (재확인)

| 기기 | 연동 경로 | 실시간성 | Runnit 지원 우선순위 |
|---|---|---|---|
| Apple Watch | HealthKit 네이티브(`HKWorkoutSession`) | 높음 | 1순위 |
| Garmin | Garmin Connect → HealthKit(iOS)/Health Connect(Android) 동기화 | 낮음(지연) | 1순위 (경로는 다르나 지원 등급 동일) |
| 기타 Wear OS | Health Connect | 중간 | 2순위 |
| 워치 미연동 | 폰 GPS 단독 | — | 기본 폴백(에러 아님) |

#### 8.4.1 벤더 판별 (`DeviceVendor`, §3.1.1)

판별 입력은 `health` 패키지(11.1.1)가 주는 `sourceId`/`sourceName`이다. **플랫폼별로 형태가 다르다** — 소스 코드로 직접 확인한 사실이다:

| 플랫폼 | `sourceId` | `sourceName` |
|---|---|---|
| iOS (`SwiftHealthPlugin.swift`) | `sourceRevision.source.bundleIdentifier` | `sourceRevision.source.name` (사용자에게 보이는 기기/앱 이름) |
| Android (`HealthPlugin.kt`) | **항상 빈 문자열** | `metadata.dataOrigin.packageName` |

→ 두 필드를 합쳐 매칭해야 한다. 한쪽만 보면 Android가 통째로 샌다.

| 벤더 | 판별 근거 | 신뢰도 |
|---|---|---|
| `watchGarmin` | `garmin` 부분 문자열 — iOS `com.garmin.connect.mobile`, Android `com.garmin.android.apps.connectmobile`, 표시명 `Garmin Connect`가 모두 포함 | 높음 |
| `watchApple` | `com.apple.*` 번들 + 기기명에 `watch` | **중간 — 아래 한계 참조** |
| `watchOther` | Samsung Health / Google Fit / Polar / Coros / Suunto / Fitbit 등 힌트 목록 | 낮음(뱃지 무관) |
| `unknown` | 위 어디에도 안 걸림. 단, 러닝 중 심박 폴링 경로는 `watchOther`로 저하한다 — 폰은 러닝 중 심박을 연속 측정하지 못하므로 연속 심박의 존재 자체가 웨어러블의 증거다 | — |

⚠️ **Apple Watch 판별의 알려진 한계.** HealthKit에서 Apple Watch가 쓴 데이터의 bundleIdentifier는 `com.apple.health.<기기 UUID>`인데 **iPhone이 쓴 데이터도 같은 형태**라 번들 id만으로는 구분되지 않는다. 기본 기기 이름("○○의 Apple Watch")에 `Watch`가 들어가는 것에 의존하므로 **사용자가 워치 이름을 바꾸면 판별에 실패**해 `watchOther`로 떨어진다. 방향은 안전하다 — 애플워치 뱃지가 **안 붙을 뿐 잘못 붙지는 않는다**. 정확한 판별에는 `HKDevice.manufacturer`/`model`(iOS)과 `Metadata.device`(Health Connect)가 필요한데 `health` 패키지가 노출하지 않는다(§14 #8).

### 8.5 배터리 모드

| 모드 | `LocationAccuracy` | 폴링 주기 |
|---|---|---|
| 고정밀 | `best` | 1~2초 |
| 표준(기본값) | `high` | 5초 |
| 절전 | `medium` | 10초+ |

---

## 9. 티어·랭킹 집계 기술 사양

- **티어 판정**: `upload-run-record` Edge Function 트랜잭션 내에서 동기 처리. 배치 지연 없음(PRD TI-03).
- **주간 랭킹 집계**: 초기 구현은 `pg_cron` 5분 주기 배치(§6.3). 조회는 Supabase 자동 생성 REST(PostgREST) 또는 별도 Edge Function.
- **시즌/주간 경계**: `seasons.starts_at/ends_at`는 역년 분기 KST 기준. `week_id` 산출은 KST 월요일 00:00 ~ 일요일 23:59 기준 ISO 주차 문자열(`YYYY-'W'WW`). 러닝 **시작 시각** 기준으로 시즌/주간에 귀속(PRD §8.5).
- **주중 승급 시 랭킹 이관**: `weekly_ranking_cache`의 `tier` 컬럼만 갱신하고 `weekly_distance_m`은 유지 — **row를 재생성하지 않는다**(PRD §8.6).
- **기록 삭제 시 재계산**: `run_records` soft delete(또는 hard delete) 시 트리거로 `user_season_tier.cumulative_distance_m` 재계산 → 기준선 미달 시 `current_tier` 하향. 이때 이미 지급된 뱃지는 **회수하지 않음**(자발적 삭제, PRD §8.1). 부정 기록 무효화로 인한 삭제는 별도 플래그로 구분해 뱃지 `revoked=true` 처리.

---

## 10. 뱃지 판정 기술 사양

- 트리거: (1) 세션 종료 이벤트 → 세션형 뱃지 판정, (2) `profiles.total_distance_m`/`user_season_tier` 갱신 이벤트 → 누적형 뱃지 판정. 두 트리거를 **모두** Edge Function에서 재실행한다.
- 판정 함수는 `condition jsonb`를 입력으로 받는 범용 평가기로 구현(예: `{"type": "cumulative_distance_gte", "value": 100000}`) — 뱃지 추가 시 코드 배포 없이 데이터로 확장 가능하게 한다.
- 클라이언트 잠정 판정 → 서버 확정 결과 Realtime 반영까지의 사이, UI는 "확인 중" 상태를 명시(연출 자체는 잠정치로 먼저 보여주되 최종 확정 실패 시 취소 애니메이션 없이 조용히 `verified=false`로 유지 — 게이미피케이션 원칙: 설명 없이 박탈하지 않음).
- **카탈로그 시딩**: [`docs/badge-catalog.csv`](./badge-catalog.csv)의 158개 행을 `badges` 시드 데이터로 적재한다. `scope='permanent'`(117개)는 그대로 1행 = 1뱃지. `scope='seasonal'`(41개 템플릿)은 시즌 시작 배치 작업이 시즌마다 `id`에 `season_id`를 붙여 실제 인스턴스로 복제 발급한다(예: 템플릿 `stier_platinum` → 인스턴스 `stier_platinum_2026q3`). 템플릿 자체는 `badges`에 유저에게 노출되지 않는 참조용 행으로 유지하거나, 시즌 인스턴스 생성 로직의 입력 메타데이터로만 별도 관리한다 — 어느 쪽으로 할지는 `backend-engineer`가 시딩 스크립트 작성 시 확정.

### 10.1 실제 구현 노트 (v2, 2026-08-25 · 마이그레이션 27_badge_evaluation_logic)

위 §10 서술은 Edge Function 트리거를 전제로 썼으나, **실제 구현은 Postgres 트리거**다
(`runs` 테이블의 `runs_03_evaluate_badges` AFTER 트리거 → `evaluate_badges(user_id, run_id)` →
`evaluate_badge_condition(user_id, condition_type, condition)` 디스패치). 세션형/누적형을
따로 구분하지 않고 매 `runs` INSERT/UPDATE/DELETE마다 미획득 permanent 뱃지 전체를
재평가한다 — 카탈로그가 158행 규모라 전체 스캔 비용이 낮기 때문(§6.4 근거와 동일 판단).

44개 `condition_type` 중 21종을 이번에 구현했고, 23종(레벨/시즌 19종/역지오코딩/기기판별 2종)은
선행 의존성 미해결로 `false` 스텁을 유지한다. 상세는 `_workspace/{날짜}_backend_badge-evaluation-logic.md` 참조.

> **이후 진행 상황(2026-08-25~26)**: 시즌 조건 19종은 이후 라운드(마이그레이션 31~34)에서
> 전부 실제 판정 로직으로 교체됐다(§3.6 상단 정정 노트 참고). 2026-08-26에는 사용자 요청으로
> `seasonCumulativeDistance`/`seasonFinisher` 카테고리와 그 조건 타입 4종
> (`season_cumulative_distance_gte`/`consecutive_seasons_participated_gte`/
> `season_first_and_last_week_active`/`season_final_week_active`)이 카탈로그에서 완전히
> 삭제됐다(마이그레이션 35) — 현재 `condition_type`은 40종, 그중 `district_diversity_gte`/
> `device_source_diversity_gte`/`level_gte` 등 일부만 여전히 스텁이다.

구현 시 판정 규칙에 넣은 **문서화되지 않은 가정**(카탈로그/PRD에 명시 없음, 가장 단순한 해석으로 채움 — 추후 gamification-designer 확인 필요):

| 조건 | 가정 |
|---|---|
| `pb_first_achieved`/`pb_time_lte` | 목표 거리의 98~115% 구간에 든 완주 세션만 해당 거리의 기록으로 인정(실외만, `activity_type <> 'indoor_run'`) |
| `route_diversity_count_gte` | 시작점을 위경도 소수 3자리(~100m)로 반올림해 클러스터링(정식 클러스터링 아님) |
| `loop_course_count_gte` | 출발-도착 직선거리 200m 이내 + 총 거리 1km 이상 |
| `streak_weeks_gte` | KST ISO 주(월~일) 단위, 유예(freeze) 없음, "최장 기록"(daily 스트릭과 동일 철학 — 한 번 달성하면 이후 끊겨도 유지) |
| `pace_negative_split_count_gte`/`pace_final_km_faster_pct_gte`/`pace_variance_lte` | `RunSample.cumulative_distance_meters`+`timestamp`로 1km 스플릿을 보간 없이 근사(`_run_km_split_seconds`) |
| `calendar_date_match` | 음력 날짜(`chuseok`/`lunar_newyear`)는 미구현. 양력 고정일 + `birthday`만 구현 |



## 11. 비기능 요구사항 → 기술 목표치 매핑

| 요구사항 | 목표 | 검증 방법 | 담당 계층 |
|---|---|---|---|
| GPS 거리 오차 | ±3% 이내 | 실측 1km 코스 반복 측정 | `tracking` 모듈(§8.3) |
| 배터리 소모 | 1시간 10% 이하 | 실기기 배터리 로그 측정(표준 모드) | `tracking` 모듈(§8.5) |
| 콜드 스타트 | 3초 이내 | 프로파일링(cold start trace) | `core/router` 초기 의존성 최소화 |
| 랭킹 조회 | 1초 이내 | API 응답 시간 측정(p95) | `weekly_ranking_cache` 배치(§9) |
| 기록 손실 | 0건 | 강제 종료/크래시 재현 테스트 | 로컬 영속 저장(ARCHITECTURE §9) |
| 오프라인 동기화 | 100% 업로드 | 비행기 모드 테스트 | 업로드 큐(ARCHITECTURE §9) |
| 티어·랭킹 정합성 | 서버 단일 진실 원천 | 클라이언트 잠정치 vs 서버 확정치 비교 로그 | Edge Function(§6, §7) |
| 접근성(러닝 중 화면) | 최소 24sp, 명암비 4.5:1 | 디자인 QA | `presentation/` (flutter-ui-designer 영역) |

---

## 12. 보안 요구사항

- **인증**: Supabase Auth, Apple/Google/Kakao 소셜 로그인. iOS는 Apple 로그인 필수 제공(App Store 심사 요건).
- **RLS**: §5 전 테이블 적용. service role 키는 Edge Function 환경변수로만 보관, 클라이언트 번들에 절대 포함하지 않는다.
- **데이터 삭제(AC-04)**: 계정 삭제 시 `profiles` cascade로 `run_records`/`run_samples`/`user_badges`/`user_season_tier` 전량 삭제. 삭제 후 `weekly_ranking_cache`/집계 캐시는 다음 배치 사이클에 자동 반영(즉시 반영 필요 시 삭제 트랜잭션에서 직접 갱신).
- **GPX 내보내기(HI-09, P1)**: `run_samples`를 GPX XML로 직렬화하는 Edge Function 또는 클라이언트 로컬 변환 — 서버 부하가 크지 않으므로 클라이언트 변환을 우선 검토.
- **부정 기록 데이터 보존**: `flagged=true` 기록은 삭제하지 않고 보존(§7 원칙) — 이의 제기 대응 근거.

---

## 13. Phase 0 완료 기준 (Definition of Done)

PRD §11 "Phase 0 — 아키텍처·데이터 모델·Supabase 스키마 확정"의 완료 조건:

- [ ] `docs/ARCHITECTURE.md`, `docs/TRD.md` 사용자 검토·승인
- [ ] `lib/models/*.dart` — 본 문서 §3 모델을 freezed 클래스로 실제 생성 (`mobile-architect`)
- [ ] Supabase 프로젝트에 §4 DDL 마이그레이션 적용 + `get_advisors` 보안/성능 권고 확인 (`backend-engineer`)
- [ ] §5 RLS 정책 적용 및 최소 1개 계정으로 본인/타인 접근 범위 수동 검증
- [ ] §4.1 camelCase↔snake_case 매핑표가 실제 스키마와 100% 일치
- [ ] `upload-run-record` Edge Function 스켈레톤(§6.1) 배포 — 로직은 Phase 2에서 완성해도 되나, 요청/응답 shape는 Phase 1의 클라이언트 업로드 코드가 이를 기준으로 작성될 수 있어야 함

---

## 14. 미확정 기술 이슈 (Open Items)

| # | 이슈 | 확정 필요 시점 |
|---|---|---|
| 1 | 로컬 영속 저장소 패키지(Hive/Drift/Isar) | Phase 1 트래킹 모듈 착수 시 |
| 2 | `run_samples` jsonb → 별도 테이블 전환 임계 규모 | Phase 1 실측 후 |
| 3 | 공유 카드(HI-08) 이미지 렌더링 방식(클라이언트 위젯 캡처 vs 서버 렌더링) | Phase 2 |
| 4 | 시즌 롤오버 시 `user_season_tier` 신규 row를 lazy insert할지 전원 일괄 생성할지 | Phase 2, 실제 사용자 수 확인 후 |
| 5 | 이상치 판정 임계값(가속도, accuracy 등)의 실측 튜닝 | Phase 1 실기기 테스트 후 |
| 6 | GPX 내보내기 클라이언트 vs 서버 처리 | Phase 1 이후(P1) |
| 7 | 포인트 이코노미(Phase 4) 테이블 설계 | Phase 4 착수 전 — PRD §10.2 |
| 8 | Apple Watch 벤더 판별의 기기명 의존(§8.4.1) — `HKDevice`/`Metadata.device`를 얻는 얇은 platform channel이 필요한지 | P1 웨어러블 실기기 테스트에서 오분류가 실제로 확인되면 |
| 9 | `device_source_diversity_gte`의 `"watchApple_or_watchGarmin"` **OR 표현식 파싱 규약** — 토큰 목록은 §3.1.1에서 확정됐고, 표현식 문법은 gamification-designer 소관 | 뱃지 판정 로직 다음 라운드 |
