# Runnit TRD (Technical Requirements Document)

| 항목 | 내용 |
|------|------|
| 문서 버전 | v0.7 (초안) |
| 작성일 | 2026-08-26 |
| 작성자 | jehyun (Claude Code 하네스 산출) |
| 상태 | Phase 0 초안 — 구현 착수 전 검토 필요 |
| 근거 문서 | [`docs/PRD.md`](./PRD.md) v1.3 (확정), [`docs/ARCHITECTURE.md`](./ARCHITECTURE.md) v0.1 |

**변경 이력**
| 버전 | 변경 내용 |
|------|----------|
| v0.1 | 최초 작성. `docs/ARCHITECTURE.md`의 구조 결정을 구현 가능한 스펙(데이터 모델 코드, DDL, API, 검증 규칙)으로 세분화 |
| v0.2 | 뱃지 카탈로그 확장(30종 → 158개 템플릿) 설계 반영. `Badge`에 `category`(16종)·`scope`(permanent/seasonal)·`description`·`seasonId` 필드 추가, `tierLabel`→`badgeGrade`로 개명(시즌 티어 시스템과 명칭 혼동 방지). 카탈로그 원본은 `docs/badge-catalog.csv` |
| v0.3 | 뱃지 판정 실제 구현 완료(§10.1) — `runs` 트리거 기반 `evaluate_badges`/`evaluate_badge_condition`, `condition_type` 44→40종 중 사실상 전량 판정 가능. 시즌 뱃지 인스턴스 발급을 실제로 구현(`{templateId}@{seasonId}`, `ensure_season_badge_instances()`, §3.6 상단 정정 노트). 티어 도달 시각 이력 테이블 `tier_change_history` 신규 추가. 2026-08-26 사용자 요청으로 `seasonCumulativeDistance`/`seasonFinisher` 카테고리와 소속 뱃지 9종 삭제(158→148 템플릿, 16→14 카테고리, `condition_type` 44→40종) |
| v0.4 | 뱃지 백로그 설계 결정 7건 반영(`_workspace/20260826_000340_gamification_badge-backlog-decisions.md`) — **XP/레벨 공식 확정**(§3.8 신설, `total_points`→`total_xp` 개명·만렙 60), **주 단위 스트릭 + 1회 유예 규칙 확정**, `season_weekly_rank_lte`의 `bucket` 도메인 확정, device source 토큰 7종·OR 표현식 문법 확정, §10.1의 미문서화 가정표를 §10.2 정본 규칙으로 교체, 음력 룩업 테이블 채택. `district_diversity_gte`(`route_district_3`/`route_district_10`) 사용자 요청으로 삭제(148→146 템플릿, `condition_type` 40→39종) |
| v0.5 | **기기 벤더 모델 중재 확정**(`_workspace/20260826_012000_architect_device-vendor-arbitration.md`) — 병렬 워크트리의 두 상충 설계(배열 `runs.device_vendors` vs 스칼라 `runs.device_source`) 중 **배열 안 채택**, 스칼라 안의 OR 문법(`_or_`)·판정 대상 규칙은 흡수. 토큰 **5종 확정**(`watchWearOS`/`external`/`manual` 불채택). §3.1.2 뱃지 매칭 시맨틱 신설(배열 겹침 `&&` 단일 규칙), §4.0 벤더 DDL 신설, §3.1 `RunSampleSource` 초안 코드블록을 구현값(`phone`/`watch`/`external`)으로 정정, §4.1 매핑표의 잘못된 `watchApple → watch_apple` 행 교체, §14 #9 해소·#10 신설. `device_both_used` 설명문에서 "단독" 제거 |
| v0.6 | **뱃지 백로그 7건 실제 구현·적용 완료**(마이그레이션 36~41, Supabase `xwtbwexcofcgmbvktwdo`). §3.8·§10.2가 설계 확정 문서였던 것을 라이브 스키마 사실로 갱신 — `device_vendor` enum + `runs.device_vendors`(36), `district_diversity_gte` 삭제 + `condition_type` CHECK 39종·`category` CHECK 14종·`bucket` 도메인 CHECK(37), `lunar_holidays` 테이블 2026~2040(38), `total_points`→`total_xp`/`awarded_points`→`awarded_xp` 개명 + XP 4원천 + 60레벨 정수 배열 + 주간 스트릭 4컬럼 + XP 갱신 트리거 2개 + `evaluate_badges` 3패스 수렴 루프(39), `leaderboard_entries.reached_at` + PRD §8.2 3단계 타이브레이크(40), 판정 스텁 5종 전량 해제 + §5 임계값 정본화 + 스플릿 선형 보간(41). **`evaluate_badge_condition`의 `raise notice … 보류` 스텁이 0개가 됐다.** §4.2 신설(음력 룩업), §4.3 신설(랭킹 캐시 실제 테이블명) |
| v0.7 | **거리 허용오차 통일**(마이그레이션 42) — `session_first_long_distance`(고정 98%)와 `session_distance_gte` 5종(허용오차 없음)을 `pb_first_achieved`/`pb_time_lte`와 동일한 `목표 − min(목표×2%, 300m)`로 통일. gamification-designer 확인 완료(§14 #13·#15 해소). 완화 방향이라 소급 회수 없음, `evaluate_badges` 재실행으로 미지급분 즉시 채움 |

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
enum RunSampleSource { phone, watch, external }   // 초안의 watchApple/watchGarmin은 §3.1.1에서 벤더 축으로 분리됨

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

> 📌 **이 절은 2026-08-26 mobile-architect 중재의 결과다.** gps-tracking-engineer(러닝 단위 **배열** `runs.device_vendors`, 토큰 5종)와 gamification-designer(러닝 단위 **스칼라** `runs.device_source`, 토큰 7종)가 병렬 워크트리에서 양립 불가능한 두 설계를 냈고, **배열 안을 정본으로 채택**하되 스칼라 안의 OR 표현식 문법(`_or_`)과 판정 대상 세션 규칙을 흡수했다. 결정 근거·폐기 사유는 `_workspace/20260826_012000_architect_device-vendor-arbitration.md`.

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

**빈 배열 `{}`의 의미** — `{phone}`과 **다르다**. 수동 입력, 기기 정보 없는 임포트, 마이그레이션 이전 레거시 행이 `{}`다. `unknown`은 "외부 기여가 있었으나 기기를 식별하지 못함"이라는 또 다른 상태다.

**채택하지 않은 토큰과 사유** — 대안 설계가 제안한 `watchWearOS` / `external` / `manual` 3종은 넣지 않았다.

| 토큰 | 불채택 사유 |
|---|---|
| `watchWearOS` | 이 토큰을 요구하는 뱃지가 없고, Health Connect 패키지명만으로 "Wear OS 워치"와 "그 외 안드로이드 웨어러블"을 신뢰성 있게 가를 방법이 없다(§8.4.1). 판별할 수 없는 값을 enum에 두면 실제로는 전부 `watchOther`로 떨어지면서 스키마만 커진다. `watchOther`가 이미 Wear OS·Samsung·Polar·Coros·Suunto를 포괄한다 |
| `external` | **소스 축의 값이다**(`RunSampleSource.external` = 사후 동기화 경로). 벤더 enum에 넣으면 §3.1.1이 방금 분리한 두 축이 다시 섞인다 |
| `manual` | 수동 입력은 기여한 기기가 **없는** 상태이고 `device_vendors = {}`로 이미 표현된다. 활동 유형은 `RunRecordType.manual`이 따로 들고 있어 세 번째 이름이 된다 |

#### 3.1.2 뱃지 조건 매칭 시맨틱 (정본)

`device_source_count_gte` / `device_source_diversity_gte` 두 `condition_type`이 `runs.device_vendors`를 읽는 방식이다. **규칙은 하나뿐이다.**

**표현식 문법** (대안 설계에서 흡수 — 배열/스칼라와 무관하게 유효하다)

```
expr  := token ( "_or_" token )*
token := §3.1.1의 5개 값 중 하나 (대소문자 구분, exact match)
```

| 규칙 | 확정 |
|---|---|
| 구분자 | **`_or_`** — 소문자, 앞뒤 밑줄 포함 |
| AND 연산자 / 괄호 / 공백 | **없다.** 1단계 평면 OR만 |
| 미지 토큰 | 파싱 오류. 그 뱃지는 `false`로 두고 **로그를 남긴다**. 조용히 무시 금지 |
| 검증 정규식 | `^[a-z][A-Za-z0-9]*(_or_[a-z][A-Za-z0-9]*)*$` |

**매칭 규칙 (단일)** — 러닝 1건이 `expr`에 매칭되는 조건은 **배열 겹침**이다. 두 `condition_type` 모두 같은 규칙을 쓴다.

```sql
run.device_vendors && ARRAY[tokens(expr)]::public.device_vendor[]
```

`_or_`의 OR가 배열 겹침으로 그대로 떨어진다 — 표현식마다 다른 연산자를 쓰지 않는다.

**판정 대상 세션 (공통)**: `status = 'completed' AND NOT is_flagged`. 카탈로그 설명이 "기록한 러닝이 처음 **검증**될 때"이므로 플래그된 기록은 제외한다.

**`device_source_count_gte`** — `{"source": "<expr>", "count": N}`
→ 대상 세션 중 매칭되는 건수 `>= N`.
예: `device_watchApple_50` = `device_vendors && '{watchApple}'`인 세션 50건. 폰 GPS + 애플워치 심박 하이브리드 세션도 **포함된다** — 카탈로그 설명 "애플워치로 기록한 러닝"이 곧 그 뜻이다.

**`device_source_diversity_gte`** — `{"sources": ["<expr1>", "<expr2>", …]}`
→ **모든** i에 대해 매칭 세션이 1건 이상 (원소 간 AND, 원소 내부 OR).
예: `device_both_used` = `{"sources": ["phone", "watchApple_or_watchGarmin"]}`
→ `device_vendors && '{phone}'` 세션 ≥1건 **그리고** `device_vendors && '{watchApple,watchGarmin}'` 세션 ≥1건.

⚠️ **"서로 다른 세션" 요구는 두지 않는다.** 폰 GPS + 애플워치 심박 세션 1건(`{phone, watchApple}`)이 두 원소를 동시에 충족하면 `device_both_used`가 지급된다. 대안 설계는 이 원소를 "폰 **단독** 기록"으로 서술했으나, 그 서술은 스칼라 모델에서 `phone`이 필연적으로 "폰만"을 뜻했던 **모델의 한계를 옮겨 적은 것**이지 독립적인 제품 요구가 아니다. 뱃지의 짧은 설명은 원래 "폰 + 워치 모두 사용"이고, 하이브리드 세션은 그 문장을 그대로 만족한다. 올라운더를 받으려고 워치를 두고 나가야 하는 규칙은 제품으로서 더 나쁘다. **`docs/badge-catalog.csv`의 `device_both_used` 설명문에서 "단독"을 제거해 코드와 문구를 일치시켰다.**

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

뱃지 카탈로그(**146개 템플릿, 14개 카테고리** — 2026-08-26 `seasonCumulativeDistance`/`seasonFinisher`
카테고리와 소속 뱃지 9종, 그리고 `district_diversity_gte` 2종(`route_district_3`/`route_district_10`,
역지오코딩 인프라 부담 대비 가치 부족)을 사용자 요청으로 삭제해 158/16에서 축소)의 확정 스펙은
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
                                                 // condition_type 열과 1:1 (현재 39종).
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
    String? sourceRunId,             // 이 뱃지를 촉발한 러닝. 2026-08-26 공유 카드(HI-08)를 위해
                                     // 모델에 노출 — 카드에 그 러닝의 경로/거리를 얹어야 한다(§3.9).
                                     // cumulative 뱃지·원본 삭제 시 null.
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

### 3.8 XP / 레벨 사양 (PRD GM-04) — 2026-08-26 확정

정본: [`_workspace/20260826_000340_gamification_badge-backlog-decisions.md`](../_workspace/20260826_000340_gamification_badge-backlog-decisions.md) §1.

#### 3.8.1 이름 규약 — `points`는 XP가 아니다

PRD §5.6이 "포인트"를 **Phase 4의 상품 교환 화폐**(거리 비연동 적립)로 확정했으므로,
레벨용 재화는 **XP**로 개명하고 `points`라는 이름을 Phase 4에 반납한다.

| 현재 | 변경 후 |
|---|---|
| `profiles.total_points` | `profiles.total_xp` |
| `runs.awarded_points` | `runs.awarded_xp` |
| `compute_awarded_points(...)` | `compute_run_xp(...)` |
| `compute_level(p_total_points)` | `compute_level(p_total_xp)` |
| `AppUser.totalPoints` | `AppUser.totalXp` |

#### 3.8.2 XP 4원천 (전부 원본 데이터에서 재계산 가능 — 증분 가산 금지)

```
total_xp = XP_run + XP_streak + XP_badge + XP_tier
```

| 원천 | 규칙 |
|---|---|
| **XP_run** | `compute_run_xp(status, is_flagged, distance_m, moving_s, elev_gain_m, **activity_type**)`. 완주·비플래그·≥500m 세션마다. **실외**: `min(20 + floor(m/100) + floor(floor(m/100)×pace_mult) + min(floor(max(elev,0)/10),100), 1000)`, `pace_mult` = 0.30(≤300s/km) / 0.20(≤360) / 0.10(≤420) / 0(그 외·거리<2km). **실내·수동**: `min(20 + floor(m/100), 300)` — 보너스 없음(검증 불가 입력의 어뷰징 차단) |
| **XP_streak** | §10.2 활동 주 1개마다 `30 × min(n, 5)` (n = 스트릭 내 순번). **유예로 메운 주는 0** |
| **XP_badge** | `verified AND NOT revoked` 뱃지의 `badge_grade`별: bronze 100 / silver 250 / gold 600 / platinum 1,500 / diamond 4,000 / special 200. **⚠️ `category='level'` 뱃지 9종은 0** (XP↔레벨 순환 차단) |
| **XP_tier** | `tier_change_history`의 distinct `(season_id, tier)`마다: silver 300 / gold 800 / platinum 2,000 (bronze 0). 시즌마다 재지급 |

#### 3.8.3 레벨 임계값 — **정본은 아래 60개 정수 배열**

유도식은 `XP_required(L) = ceil(50 × (L−1)^2.2)`, **만렙 60**. 다만 지수 역함수의
부동소수 오차가 "레벨업까지 1pt 남음" 고착 버그를 실제로 일으킨 전례가 있으므로
(`_workspace/20260819_210450_badge_rules.md` §4.3), **양쪽에 정수 배열을 그대로 심고
역함수를 계산하지 않는다.** `level(xp) = max{L : XP_LEVEL_THRESHOLDS[L] <= xp}`.

```
L1..L10   0, 50, 230, 561, 1056, 1725, 2576, 3616, 4851, 6285
L11..L20  7925, 9774, 11836, 14114, 16614, 19337, 22287, 25466, 28879, 32526
L21..L30  36412, 40538, 44906, 49519, 54380, 59490, 64851, 70465, 76334, 82461
L31..L40  88846, 95492, 102401, 109573, 117011, 124716, 132690, 140934, 149450, 158239
L41..L50  167303, 176643, 186260, 196156, 206332, 216790, 227530, 238554, 249863, 261458
L51..L60  273341, 285513, 297974, 310726, 323770, 337108, 350739, 364666, 378889, 393410
```

**구현(2026-08-26)**: 서버는 `public.xp_level_thresholds() returns integer[]`(immutable)에 60개 정수를 담고, `compute_level(p_total_xp)`이 `generate_subscripts` 로 `max{i : thresholds[i] <= xp}` 를 찾는다 — **정수 비교만** 하므로 부동소수 경계 버그가 원천적으로 없다. 클라이언트는 `LevelCurve.thresholds`(같은 60개 정수) + 이진 탐색이며, `test/gamification/level_curve_test.dart` 가 L=2..60 전수 경계를 잠근다.

`profiles.level` CHECK를 `between 1 and 60`으로(제약명 `profiles_level_range`, 구 `profiles_level_positive` 대체). `LevelCurve.maxLevel = 60`
(현행 100은 구 포인트 곡선의 잔재이고, 카탈로그 `lvl_60` 표시명이 이미 "만렙"이다).

#### 3.8.4 저장·갱신 (뷰가 아니라 저장 컬럼)

`profiles.total_xp`(int, default 0) / `profiles.level`(int, default 1) 저장 컬럼을 유지하고
`recompute_profile_stats(p_user_id)`가 4원천을 재집계해 갱신한다. 뷰로 두지 않는 이유:
① `level_gte` 판정이 프로필 1행 읽기로 끝나야 한다(뱃지 146행 루프) ② GM-04의 "레벨업 시 알림"이
old→new 전이 감지를 요구한다 ③ 원천이 3개 테이블에 흩어져 있다.

호출 트리거 3곳(**전부 적용됨 — 마이그레이션 39**):

| 트리거 | 테이블 | 담당 XP |
|---|---|---|
| `runs_01_recompute_stats` (기존) | `runs` INSERT/UPDATE/DELETE | XP-1, XP-2 |
| `user_badges_02_recompute_xp` (신규) | `user_badges` AFTER INSERT/DELETE/UPDATE OF (verified, revoked) | XP-3 |
| `tier_change_history_01_recompute_xp` (신규) | `tier_change_history` AFTER INSERT | XP-4 |

뒤의 둘은 공통 함수 `trg_recompute_xp_source()` 를 쓰며 `pg_trigger_depth() > 8` 가드가 있다.

**재진입 수렴**: 레벨 뱃지 XP=0 덕분에 2패스에서 수렴한다. `evaluate_badges` 를 "새 뱃지가 생겼으면
다시 한 번, 최대 3회" 루프로 감쌌고, 패스 끝에서만 `recompute_profile_stats` 를 한 번 호출한다.
그 사이 `user_badges` 트리거는 세션 변수 `runnit.badge_eval='on'` 을 보고 스킵한다 —
켜둔 채로 두면 한 번의 평가에서 지급된 뱃지 N개마다 전체 재집계가 N번 돌기 때문이다(결과는 동일, 비용만 N배).

⚠️ **`challenges.reward_points` 는 `total_xp` 에 들어가지 않는다.** XP 4원천에 챌린지가 없고
`reward_points` 는 Phase 4 포인트 이름이다 — 구 `recompute_profile_stats` 가 이 항을 더하던 것을 39번에서 제거했다.

### 3.9 공유 카드 뷰모델 (PRD HI-08 / HI-10) — 2026-08-26 확정

구현: `lib/features/sharing/domain/share_card_data.dart` (유니온) ·
`share_card_builder.dart` (조합 규칙) · 설계 근거는
[`_workspace/20260826_050000_architect_sharing-cards.md`](../_workspace/20260826_050000_architect_sharing-cards.md).

**신규 테이블·컬럼은 없다.** 카드 4종(성취 3종 + 러닝 기록 1종)이 필요한 값은 전부 이미 저장돼 있다:

| 카드 | 데이터 출처 |
|---|---|
| 티어 승급 | `profiles.current_tier` / `season_distance_meters` / `tier_season_id`, `user_badges`의 `stier_{tier}@{seasonId}` 인스턴스, `leaderboard_entries`(순위·모집단) |
| 뱃지 획득 | `badges` + `user_badges` (+ `source_run_id` → `runs`의 경로) |
| PB 갱신 | `badges.condition->>'distanceKm'` + `user_badges.source_run_id` → `runs` |
| 러닝 기록(`runRecap`) | `runs`(거리·시간·페이스·칼로리·경로) — 뱃지를 터뜨리지 않은 대부분의 러닝을 위한 4번째 카드. 서버 확정 성취(뱃지·PB·티어)를 주장하지 않으므로 `AchievementGate`를 적용하지 않고 `isFlagged=true`만 제외한다(2026-08-26 UI 라운드, §7.4.1) |

공유 **행위**를 기록하는 테이블(`share_events` 등)도 두지 않는다 — OS 공유 시트는 사용자가
실제로 게시했는지 앱에 돌려주지 않으므로(iOS는 취소 여부만, 대상 앱은 미공개) 게시 여부를
모르는 행은 분석에도 쓸 수 없다. 전환율이 필요해지면 도메인 테이블이 아니라 텔레메트리 이벤트로 붙인다.

```dart
enum ShareCardKind { tierPromotion, badgeEarned, personalBest, runRecap }

sealed class ShareCardData {
  ShareAthlete get athlete;      // displayName / tier / level / avatarUrl (신체 정보는 넘기지 않는다)
  DateTime get achievedAt;       // 서버 확정 시각 (UserBadge.earnedAt)
  ShareRoute? get route;         // 좌표 ≤240점. samples 우선, 없으면 routePolyline 해독
  ShareCardKind get kind;
  String get headline;           // 카드 큰 글씨
  String? get subhead;
  String get shareText;          // 공유 시트에 곁들이는 텍스트
}

final class TierPromotionCardData extends ShareCardData { Tier tier; String seasonId;
  double seasonDistanceMeters; int? rank; int? participantCount; /* topPercent 파생 */ }
final class BadgeEarnedCardData  extends ShareCardData { Badge badge; String badgeAssetPath; }
final class PersonalBestCardData extends ShareCardData { double targetKm; int? certifiedSeconds;
  double? runDistanceMeters; String badgeAssetPath; }
final class RunRecapCardData     extends ShareCardData { double distanceMeters; int movingSeconds;
  int elapsedSeconds; double? avgPaceSecPerKm; int? caloriesKcal; }
```

`RunRecapCardData`는 2026-08-26 UI 구현에서 추가됐다. HI-08은 "**기록**·성취 이미지 공유 카드"이고
대부분의 러닝은 뱃지를 터뜨리지 않으므로, 성취 카드 3종만으로는 요약 화면의 공유 버튼이 열 번 중
아홉 번 아무것도 만들지 못한다. 이 카드는 서버가 확정한 성취를 **주장하지 않는다** — 사용자가 방금
기록한 자기 러닝의 거리·시간·경로만 그리므로 PRD §8.4에 걸리지 않는다(반대로 이 카드에 뱃지·PB
문구를 얹으면 그 순간 위반이 된다). 그림은 `presentation/widgets/share_card_body.dart`가 4종을
`switch` 하나로 그리며, `sealed` union이라 카드가 늘면 컴파일 에러로 알려준다.

`freezed`를 쓰지 않는다 — 직렬화되지 않고 `copyWith`도 필요 없어 코드 생성이 순수 비용이다
(같은 계층의 `GamificationStats`/`BadgeProgress`와 동일한 판단).

#### 3.9.1 PB 카드의 `certifiedSeconds`가 null일 수 있는 이유

§10.2 `pb_time_lte`는 세션 거리가 목표의 **102%를 넘으면 GPS 샘플 선형 보간으로 목표 거리 통과
시각**을 쓴다. 그 보간값은 현재 **어디에도 저장되지 않는다**(`user_badges`에 값 컬럼이 없음).
따라서 클라이언트 규칙은:

- 세션 거리 ≤ 목표×102% → `runs.moving_seconds`. 이 구간에서는 그것이 **서버 규칙 그 자체**라 값이 정확히 일치한다.
- 초과 → **null**. 카드는 시간 없이 "5km PB 갱신"만 말한다.

클라이언트가 보간을 흉내 내지 않는 이유: 서버 확정값을 클라이언트가 재유도하면 정본이 둘이 되고,
어긋나는 순간 사용자가 인스타에 올린 기록이 앱 화면과 다른 값이 된다.

🔵 **해소 방법(P1, backend-engineer)**: `user_badges.achieved_value numeric null` 한 컬럼.
서버가 판정 시점에 확정한 값(PB 초, 스트릭 주, 주간 순위 …)을 그대로 적으면 위 폴백이 사라지고
모든 뱃지 카드가 서버 값만 그린다. §14 #18 참조.

#### 3.9.2 렌더링 방식 — 클라이언트 위젯 캡처 (확정)

`RenderRepaintBoundary.toImage()`. 출력은 항상 **1080×1920 (9:16)** 이며,
`pixelRatio = 1080 / 카드논리폭`으로 역산해 기기 DPI와 무관하게 같은 결과를 낸다.
별도 캡처 패키지(`screenshot` 등)는 추가하지 않는다 — 그 래퍼는 우리가 직접 계산해야 하는
경계 크기를 감춘다. 공유 시트만 `share_plus: ^10.1.4`. 근거는 §14 #3 해소 항목.

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

> ⚠️ 위 DDL은 Phase 0 초안이고 **라이브 스키마의 테이블명은 `public.runs`**(마이그레이션 01)다. 아래 §4.0 이후의 추가 DDL은 라이브 이름을 기준으로 적는다.

#### 4.0 기기 벤더 (§3.1.1 확정 — ✅ **적용 완료**, 마이그레이션 36)

```sql
-- ─────────────────────────────────────────────
-- 라벨이 camelCase인 것은 의도적이다. badge_catalog.condition_value 와
-- device_watchApple_1 같은 뱃지 id(PK)가 이미 이 문자열로 시드돼 있고,
-- 별도 매핑을 두면 어긋날 때 뱃지가 조용히 미지급된다. TRD §3.1.1 참조.
-- ─────────────────────────────────────────────
create type public.device_vendor as enum (
  'phone', 'watchApple', 'watchGarmin', 'watchOther', 'unknown'
);

-- runs.sources(run_sample_source[])와 **직교하는 축**이다. 합치지 말 것.
--   sources        = 어떤 경로로 언제 들어왔나 (phone/watch/external)
--   device_vendors = 어느 기기가 만들었나
alter table public.runs
  add column device_vendors public.device_vendor[] not null default '{}';

comment on column public.runs.device_vendors is
  '이 세션에 기여한 기기 벤더 집합. {} 는 {phone} 과 다른 뜻(정보 없음/수동 입력). TRD §3.1.1';

-- device_source_count_gte 가 사용자별로 겹침(&&) 필터를 돈다.
create index runs_device_vendors_gin on public.runs using gin (device_vendors);

-- 백필: {}(정보 없음)과 {phone}(폰 단독 확정)은 의미가 다르므로
-- 무조건 채우지 말고 sources 를 근거로만 채운다.
update public.runs
   set device_vendors = '{phone}'::public.device_vendor[]
 where device_vendors = '{}'
   and sources @> '{phone}'::public.run_sample_source[];
```

- **RLS**: `runs`의 기존 정책을 그대로 상속한다. 새 정책 불필요.
- **쓰기 주체**: 클라이언트가 `RunRecord.toJson()`으로 함께 올린다(`_serverOwnedKeys` 아님). P1에서 워크아웃 임포트가 서버 경유로 바뀌면 그때 서버가 재확정한다.
- **판정 헬퍼**: `_device_vendor_tokens(text) returns device_vendor[]` 가 `_or_` 표현식을 파싱한다. 문법 오류·미지 토큰이면 `null` + `raise notice` 를 내고 해당 뱃지는 `false` — 조용히 무시하지 않는다(§3.1.2).

#### 4.2 음력 명절 룩업 (✅ **적용 완료**, 마이그레이션 38)

`calendar_date_match` 의 `date='chuseok'` / `'lunar_newyear'` 판정 원천. **음력 변환 함수를 구현하지 않는다** —
정확한 한국 음력은 한국천문연구원의 삭(朔) 계산을 **동경 135°E(KST)** 기준으로 따라야 하고, 중국 음력(120°E)과
날짜가 갈리는 해가 실제로 있다(삭이 KST 자정 직후에 들면 한국은 하루 뒤가 초하루다).

```sql
create table public.lunar_holidays (
  holiday_key text    not null,   -- 'lunar_newyear' | 'chuseok'
  year        integer not null,
  solar_date  date    not null,   -- KST 양력 날짜
  primary key (holiday_key, year),
  check (holiday_key in ('lunar_newyear','chuseok')),
  check (extract(year from solar_date)::integer = year)
);
```

- `holiday_key` 는 `badges.condition ->> 'date'` 값과 **같은 문자열**이다 — 매핑 계층을 두지 않는다.
- **RLS**: `anon`/`authenticated` SELECT 허용(공개 상수), 쓰기 정책 없음 + write 권한 revoke.
- 2026~2040 15년치(30행) 시드 완료. **미등재 연도는 `false` + `raise notice`** — 조용히 넘어가지 않는다.
- ⚠️ 회귀 테스트 대상: **2027 설날 한국 2/7(중국 2/6)**, **2028 설날 한국 1/27(중국 1/26)**.
  중국 음력 라이브러리를 참조 구현으로 쓰면 이 두 해가 하루 틀린다.
- §6.4 연휴 3일(전날·당일·다음날) 확대는 **채택하지 않았다** — 같은 카테고리 다른 8종이 전부 당일 기준이라
  설날·추석만 3일로 하면 규칙이 불균질해진다. 넓히려면 `solar_date` 를 `start_date`/`end_date` 로 확장해
  **데이터만** 고치면 되고 판정식은 그대로다.

#### 4.3 주간 랭킹 캐시의 실제 테이블명 (⚠️ 문서 ↔ 라이브 스키마)

위 §4 초안 DDL과 여러 설계 문서가 이 캐시를 **`weekly_ranking_cache`** 라고 부르지만,
**라이브 스키마의 실제 이름은 `public.leaderboard_entries`**(마이그레이션 03)이고 §2.5가 요구한 컬럼이
이미 전부 들어 있다. 새 테이블을 만들지 않고 이 테이블을 쓴다 — 마이그레이션 32/33의
`season_weekly_rank_*` 판정도 이미 이 테이블을 읽고 있다.

| 설계 문서의 이름 | 라이브 컬럼 |
|---|---|
| `week_id` | `period_start` (+ `period='weekly'`) |
| `season_id` | `period_start` 이 속한 시즌(`season_id_at()`) |
| `weekly_distance_m` | `score` (`metric='distance'`) |
| `weekly_run_count` | `run_count` |
| `weekly_moving_sec` | `total_moving_seconds` |
| `rank` | `rank` — **배치가 확정해 기록**하며 조회 시 재계산하지 않는다 |
| `tier` | `tier` (주 종료 시점 확정 티어) |
| `N`(모집단) | `participant_count` |
| `reached_at` | **`reached_at` — 마이그레이션 40에서 신설.** 유일하게 없던 컬럼이고, 이것 없이는 PRD §8.2 ②를 구현할 수 없었다 |

**순위 정렬(마이그레이션 40, `metric='distance'` 한정)** — PRD §8.2 3단계 + 결정성 폴백:
`score desc → run_count asc → reached_at asc → total_moving_seconds asc → user_id asc`.
공동 순위를 만들지 않는다. `duration`/`run_count` 지표는 §8.2의 적용 대상이 아니므로 기존 `tie_break_value` 순서를 유지한다.
`reached_at` = 그 기간의 마지막 집계 대상 러닝의 `started_at`(= 누적 거리가 최종값에 도달하는 시점).

### 4.1 camelCase ↔ snake_case 매핑

| Dart 필드 | Postgres 컬럼 | 타입 | 비고 |
|---|---|---|---|
| `RunRecord.distanceMeters` | `run_records.distance_m` | numeric | |
| `RunRecord.duration` (`Duration`) | `run_records.duration_s` | integer | 초 단위 변환 |
| `RunRecord.avgHeartRate` | `run_records.avg_heart_rate` | integer nullable | |
| `RunRecord.hasRouteSamples` | `run_records.has_route_samples` | boolean | 서버가 최종 확정 |
| `RunSample.source` (`RunSampleSource`) | `run_samples.source` / `runs.sources[]` | `public.run_sample_source` | `phone` / `watch` / `external` — snake_case 규약 대상이 아닌 단어들이라 변환 없음 |
| `RunRecord.deviceVendors` (`List<DeviceVendor>`) | `runs.device_vendors` | `public.device_vendor[]` | ⚠️ **값 문자열은 camelCase 그대로**(`watchApple`). 프로젝트 유일한 규약 예외 — §3.1.1 |
| `UserSeasonTier.cumulativeDistanceMeters` | `user_season_tier.cumulative_distance_m` | numeric | |
| `RankingEntry.score` | `leaderboard_entries.score` | numeric | 단위는 `metric`에 종속(distance→미터). ⚠️ 정본 테이블명은 `leaderboard_entries`다 — `weekly_ranking_cache`는 초기 설계 문서에만 있던 이름이고 실제로 생성된 적이 없다(§4.3) |
| `RankingEntry.participantCount` | `leaderboard_entries.participant_count` | integer nullable | |
| `UserProfile.totalDistanceMeters` | `profiles.total_distance_m` | numeric | 트리거 갱신 캐시 |
| `AppUser.totalXp` | `profiles.total_xp` | integer | ⚠️ 구 `totalPoints`/`total_points` 개명(2026-08-26). **PRD §5.6 Phase 4 포인트와 다른 개념** |
| `AppUser.level` | `profiles.level` | integer | CHECK `between 1 and 60` |
| `RunRecord.awardedXp` | `runs.awarded_xp` | integer nullable | ⚠️ 구 `awardedPoints`/`awarded_points` 개명. 서버 전용 쓰기(`_serverOwnedKeys`) |
| `RunRecord.isFlagged` | `runs.is_flagged` | boolean nullable | 2026-08-26 읽기 전용 노출(공유 게이트). **`@Default(false)`가 아니라 nullable** — `null`(아직 모름) / `false`(서버가 정상 확정) / `true`(플래그) 세 상태를 구분해야 미검증 기록을 축하·공유해 버리는 사고를 막는다. 업로드 payload에서 제거(`_serverOwnedKeys`), 로컬 `summaryJson`에는 보존. **채워지는 유일한 경로는 업로드 응답**(`_push()`의 `.upsert(payload).select(...).single()`) — `trg_runs_guard`가 BEFORE 트리거에서 동기 확정하므로 재조회·realtime 없이 그 응답에 이미 들어 있다 |
| `RunRecord.flagReason` | `runs.flag_reason` | text nullable | 위와 동일 규칙. 내부 코드성 문구라 사용자에게 그대로 노출하지 않는다 |
| *(대응 필드 없음)* | `profiles.current_streak_weeks` | integer | 리플레이 결과 캐시 |
| *(대응 필드 없음)* | `profiles.longest_streak_weeks` | integer | 리플레이 결과 캐시 · **`streak_weeks_gte` 판정의 유일한 소스** |
| *(대응 필드 없음)* | `profiles.streak_freeze_credits` | smallint | 리플레이 파생값 캐시(표시용, 0 또는 1) |
| *(대응 필드 없음)* | `profiles.streak_last_active_week` | text | KST ISO 주 키 `YYYY-Www`. 알림 판단용 |
| *(대응 필드 없음)* | `leaderboard_entries.reached_at` | timestamptz | PRD §8.2 ② 타이브레이크 근거(§4.3) |
| `Badge.conditionType` | `badges.condition_type` | text (check, 39종) | 판정 함수 디스패치 키 |
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
| `UserBadge.sourceRunId` | `user_badges.source_run_id` | uuid nullable | **쓰기는 여전히 서버 전용**(가드 트리거가 되돌린다). 2026-08-26 읽기 전용으로 Dart 모델에 노출 — 공유 카드가 "이 뱃지를 만든 러닝"의 경로를 그려야 한다(§3.9) |

> **`source_run_id` 노출 이력 (2026-08-26)**: 이 표는 원래 "Dart 모델에 추가하지 않는다"고
> 못 박고 있었다. 당시엔 소비자가 회수 판정(서버) 하나뿐이었기 때문이다. 공유 카드(HI-08)가
> 두 번째 소비자로 등장하면서 뒤집었다 — 카드에 그 러닝의 경로·거리를 얹으려면 "어느 러닝인가"를
> 알아야 하고, 이 값이 없으면 클라이언트가 `earned_at` 근처 러닝을 **시간으로 추측**하게 되는데
> 같은 날 두 번 뛴 사용자에게서 조용히 틀린다. 노출은 **읽기뿐**이고 쓰기 경계는 그대로다.
>
> `revoked`는 여전히 서버 전용이며 Dart 모델에 없다 — `select *`로 내려가도
> `json_serializable`이 미지 키를 무시하므로 무해하다. 클라이언트가 회수 여부를 렌더링할
> 이유가 없다(타인 것은 애초에 RLS가 가린다).

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
- **카탈로그 시딩**: [`docs/badge-catalog.csv`](./badge-catalog.csv)의 146개 행을 `badges` 시드 데이터로 적재한다. `scope='permanent'`(115개)는 그대로 1행 = 1뱃지. `scope='seasonal'`(31개 템플릿)은 시즌 시작 배치 작업이 시즌마다 `id`에 `season_id`를 붙여 실제 인스턴스로 복제 발급한다(예: 템플릿 `stier_platinum` → 인스턴스 `stier_platinum_2026q3`). 템플릿 자체는 `badges`에 유저에게 노출되지 않는 참조용 행으로 유지하거나, 시즌 인스턴스 생성 로직의 입력 메타데이터로만 별도 관리한다 — 어느 쪽으로 할지는 `backend-engineer`가 시딩 스크립트 작성 시 확정.

### 10.1 실제 구현 노트 (v2, 2026-08-25 · 마이그레이션 27_badge_evaluation_logic)

위 §10 서술은 Edge Function 트리거를 전제로 썼으나, **실제 구현은 Postgres 트리거**다
(`runs` 테이블의 `runs_03_evaluate_badges` AFTER 트리거 → `evaluate_badges(user_id, run_id)` →
`evaluate_badge_condition(user_id, condition_type, condition)` 디스패치). 세션형/누적형을
따로 구분하지 않고 매 `runs` INSERT/UPDATE/DELETE마다 미획득 permanent 뱃지 전체를
재평가한다 — 카탈로그가 146행 규모라 전체 스캔 비용이 낮기 때문(§6.4 근거와 동일 판단).

44개 `condition_type` 중 21종을 이번에 구현했고, 23종(레벨/시즌 19종/역지오코딩/기기판별 2종)은
선행 의존성 미해결로 `false` 스텁을 유지한다. 상세는 `_workspace/{날짜}_backend_badge-evaluation-logic.md` 참조.

> ✅ **2026-08-26 완료(마이그레이션 41)**: **`evaluate_badge_condition` 의 `raise notice … 보류` 스텁이 0개가 됐다.**
> 해제된 5종 — `level_gte`(→ `profiles.level`, 39번), `device_source_count_gte`/`device_source_diversity_gte`
> (→ `runs.device_vendors` 배열 겹침, 36번), `calendar_date_match` 음력 2건(→ `lunar_holidays`, 38번).
> `district_diversity_gte` 는 분기 자체를 삭제했다(37번에서 뱃지 2종·CHECK 제거).
> 현재 `condition_type` **39종 전량이 실제 판정**이며, `false` 가 나오는 경우는 스텁이 아니라 조건 미충족이다.

> **이후 진행 상황(2026-08-25~26)**: 시즌 조건 19종은 이후 라운드(마이그레이션 31~34)에서
> 전부 실제 판정 로직으로 교체됐다(§3.6 상단 정정 노트 참고). 2026-08-26에는 사용자 요청으로
> `seasonCumulativeDistance`/`seasonFinisher` 카테고리와 그 조건 타입 4종
> (`season_cumulative_distance_gte`/`consecutive_seasons_participated_gte`/
> `season_first_and_last_week_active`/`season_final_week_active`)이 카탈로그에서 완전히
> 삭제됐다(마이그레이션 35) — 이후 2026-08-26에 `district_diversity_gte` 2종
> (`route_district_3`/`route_district_10`)도 사용자 요청으로 삭제되어 현재
> `condition_type`은 **39종**이다.

### 10.2 판정 규칙 정본 (2026-08-26 확정 — gamification-designer)

§10.1 구현 당시 문서화되지 않은 가정으로 채웠던 항목들이 정식 규칙으로 확정됐다.
정본은 [`_workspace/20260826_000340_gamification_badge-backlog-decisions.md`](../_workspace/20260826_000340_gamification_badge-backlog-decisions.md)이며,
아래는 그 요약이다. **⚠️ 표시는 기존 구현에서 값이 바뀌는 항목**이라 마이그레이션이 필요하다.

| 조건 | 확정 규칙 |
|---|---|
| `pb_first_achieved` | 세션 거리 ≥ `목표 − min(목표×2%, 300m)`. **상한 없음**. 실외·완주·비플래그만 ⚠️ |
| `pb_time_lte` | 위 거리 조건 + 기록 시간: 거리가 목표의 102% 이하면 `moving_seconds`, 초과하면 **GPS 샘플 선형 보간으로 목표 거리 통과 시각**. 보간 불가(샘플 없음)면 해당 거리 PB로 인정하지 않는다. 거리 비례 환산 금지 ⚠️ |
| `season_first_long_distance` | **`pb_first_achieved`와 동일한 거리 허용오차** `목표 − min(목표×2%, 300m)`(고정 98% 폐기, 하프 기준 20,678m → 20,800m). 같은 "목표 거리 완주" 판정에 두 기준을 두지 않는다. 대상 필터(실외·완주·비플래그·시즌 범위)는 유지. ✅ 적용됨(마이그레이션 42) |
| `session_distance_gte` | 위와 동일한 이유로 동일 허용오차 적용(고정 허용오차 없음 → `목표 − min(목표×2%, 300m)`). 대상 필터(완주·비플래그)는 유지. ✅ 적용됨(마이그레이션 42) |
| `route_diversity_count_gte` | 시작점 **반경 300m 그리디 클러스터링**. `started_at` 오름차순 처리, 클러스터 대표점(anchor) 갱신 없음 → 결정적 ⚠️ |
| `loop_course_count_gte` | 출발-도착 haversine **≤150m** + 총 거리 **≥2.0km** + GPS 샘플 ≥10개 ⚠️ |
| `streak_weeks_gte` | KST 월~일 주. **활동 주 = 완주 1건 이상 AND 주 합산 거리 ≥1.0km**(실내·수동 포함). **1회 유예 크레딧 자동 소모**, 유예 후 4주 연속 활동 시 회복, 스트릭 종료 시 크레딧 리셋. 유예 주는 스트릭 카운트·XP 모두 0. 크레딧은 저장 상태가 아니라 가입 주부터의 **리플레이 파생값**. 판정 대상은 `longest_streak_weeks` ⚠️ |
| `pace_negative_split_count_gte` | 총 거리 절반 지점(보간) 기준 후반<전반. **세션 거리 ≥4km**만 대상 ⚠️ |
| `pace_final_km_faster_pct_gte` | **세션 거리 ≥5km**. 마지막 **완주된** 1km 스플릿 vs 그 앞 구간 평균 km 페이스 ⚠️ |
| `pace_variance_lte` | CV = stddev/mean×100. **완주된 정수 km 스플릿만**(자투리 제외), **스플릿 ≥3개**여야 판정 ⚠️ |
| 스플릿 헬퍼 `_run_km_split_seconds` | 경계를 사이에 둔 두 샘플 간 **누적거리 비율 선형 보간**으로 시각 산출. 워치 동기화 기록은 샘플 간격이 60초 이상일 수 있어 무보간 근사는 최대 1분 오차가 난다 ⚠️ |
| `calendar_date_match` 음력 | **고정 룩업 테이블 `public.lunar_holidays(holiday_key, year, solar_date)`** 채택. `holiday_key`는 `condition->>'date'` 값(`lunar_newyear`/`chuseok`)과 동일 문자열. 2026~2040 15년치 확정(한국천문연구원 기준 — 중국 음력 라이브러리와 2027·2028 설날이 하루 다르므로 회귀 테스트 필수). 미등재 연도는 `false` |
| `season_weekly_rank_lte` | `bucket ∈ {top1, top10, top10pct}` 3종 확정. 모집단 = 주 종료 시점 해당 티어 + 주간 거리>0. 순위는 PRD §8.2 3단계 타이브레이크 + `user_id` 최종 폴백으로 **고유 순위**. `top1`은 N≥10, `top10`/`top10pct`는 N≥20일 때만 발급 |
| `device_source_count_gte` / `device_source_diversity_gte` | **정본은 §3.1.2**(중재 결과 — 스칼라 `runs.device_source` 안은 폐기). `runs.device_vendors`(`device_vendor[]`) 배열 겹침 `&&` 단일 규칙. 토큰 5종 `phone`/`watchApple`/`watchGarmin`/`watchOther`/`unknown`. OR 구분자 **`_or_`**, `sources` 배열 원소 간은 **AND**. 대상은 완주·비플래그 세션 |
| `level_gte` | §3.7 참조 |

> ✅ **위 표 전체가 2026-08-26 마이그레이션 41 로 구현·적용됐다.** 관련 헬퍼 함수:
> `_run_time_at_distance`(선형 보간) / `_run_km_split_seconds`(보간 기반, 완주된 정수 km만 방출) /
> `_run_negative_split(samples, distance_m)` / `_run_final_km_faster_pct(samples, pct, distance_m)` /
> `_run_pace_variance_pct`(스플릿 3개 미만이면 null) / `_route_cluster_count(user_id)`(300m 그리디) /
> `_pb_best_seconds(user_id, target_km)` / `_device_vendor_tokens(text)`.
>
> **구현 노트 — `_route_cluster_count` 의 "첫 매칭에서 멈춤"**: 정본은 "가장 가까운 클러스터에 편입"이지만
> anchor 를 갱신하지 않으므로 어느 클러스터에 넣든 **클러스터 개수는 동일**하고, 이 함수의 반환값은
> 개수뿐이라 결과가 정확히 같다. 최근접 탐색을 생략해 상수만 줄인 것이다.
>
> **구현 노트 — 스트릭 리플레이 시작 주**: 정본은 "가입 주"지만 서버 `_weekly_streak_state` 와
> 클라이언트 `GamificationStats.computeWeeklyStreak` 모두 `least(가입 주, 첫 활동 주)` 로 감쌌다.
> 프로덕션 불변식(가입 ≤ 첫 러닝) 아래에서는 결과가 정본과 동일하고, 시드/임포트 데이터처럼 러닝이
> 가입보다 앞서는 경우에 러닝을 리플레이에서 잃지 않는다.

**공통**: 모든 날짜·시간대 판정은 KST(UTC+9 고정) · 러닝 귀속은 `started_at` 기준.
**임계값이 조여진 항목이라도 이미 지급된 뱃지는 회수하지 않는다**(PRD §8.1) —
`evaluate_badges`는 INSERT 전용이므로 자동으로 지켜지며, DELETE/revoke 경로를 추가하지 말 것.



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
| ~~1~~ | ~~로컬 영속 저장소 패키지(Hive/Drift/Isar)~~ → **해소. drift로 확정·구현 완료**(`lib/features/tracking/data/local_run_database.dart`) | — |
| 2 | `run_samples` jsonb → 별도 테이블 전환 임계 규모 | Phase 1 실측 후 |
| ~~3~~ | ~~공유 카드(HI-08) 이미지 렌더링 방식(클라이언트 위젯 캡처 vs 서버 렌더링)~~ → **해소(2026-08-26). 클라이언트 위젯 캡처 확정** — `RenderRepaintBoundary.toImage()`로 1080×1920 PNG. 서버 렌더링을 버린 이유: (a) 디자인 시스템(`AppTokens`·Pretendard 가변 폰트·뱃지 SVG 146종)이 전부 Flutter 자산이라 서버에 **두 번째 구현**이 필요하고 어긋나면 앱에서 본 카드와 올라간 카드가 달라진다, (b) 마케팅 예산 0원(BRD)인데 유일한 성장 레버에 서버 비용·왕복을 얹을 이유가 없다, (c) HI-10은 러닝 종료 직후에 동작해야 하는데 그 지점은 신호가 나쁠 수 있다(오프라인 우선 §9의 연장), (d) 경로 좌표가 이미지 한 장 만들자고 기기 밖으로 나가지 않는다. 서버 렌더링은 **링크 공유의 OG 이미지**가 필요해질 때 이 경로를 대체하는 게 아니라 추가된다 — PRD가 요구하는 건 스토리에 올릴 이미지 파일이다. 스펙은 §3.9.2 | — |
| 4 | 시즌 롤오버 시 `user_season_tier` 신규 row를 lazy insert할지 전원 일괄 생성할지 | Phase 2, 실제 사용자 수 확인 후 |
| 5 | 이상치 판정 임계값(가속도, accuracy 등)의 실측 튜닝 | Phase 1 실기기 테스트 후 |
| 6 | GPX 내보내기 클라이언트 vs 서버 처리 | Phase 1 이후(P1) |
| 7 | 포인트 이코노미(Phase 4) 테이블 설계 | Phase 4 착수 전 — PRD §10.2 |
| 8 | Apple Watch 벤더 판별의 기기명 의존(§8.4.1) — `HKDevice`/`Metadata.device`를 얻는 얇은 platform channel이 필요한지 | P1 웨어러블 실기기 테스트에서 오분류가 실제로 확인되면 |
| ~~9~~ | ~~`device_source_diversity_gte`의 OR 표현식 파싱 규약~~ → **해소(2026-08-26)**. 문법·매칭 시맨틱 모두 §3.1.2에 정본화 | — |
| ~~10~~ | ~~`runs.device_vendors` 마이그레이션(§4.0) 미적용~~ → **해소(2026-08-26, 마이그레이션 36)**. 컬럼·GIN 인덱스·백필·판정 로직 전부 적용됐다. 뱃지 5종은 이제 판정 가능하며, 실제 지급은 P1 웨어러블 연동으로 `device_vendors` 에 값이 실리기 시작한 뒤부터다 | — |
| 11 | **`season_weekly_rank_lte` 최소 모집단(top1 N≥10 / 나머지 N≥20)이 현재 시드 규모에서 절대 충족되지 않는다.** 티어별 모집단이 1~4명이라 이 뱃지 12종은 실사용자가 붙기 전까지 아무도 못 받는다. 판정 로직은 정확하지만 **아직 실데이터로 검증되지 않았다** | 베타 사용자 20명 이상 확보 시 |
| 12 | **주간 랭킹 확정 배치가 아직 `pg_cron` 에 없다.** 정본(§2.2)은 "매주 월요일 KST 00:10(`10 15 * * 0` UTC)"이고, 현재는 마이그레이션 16의 기존 `refresh_all_leaderboards` 주기 스케줄에 의존한다. 주 경계 직후 확정 시점이 스펙과 다르다 | Phase 2 랭킹 모듈 |
| ~~13~~ | ~~`season_first_long_distance` 의 거리 허용오차가 PB 조건과 다르다~~ → **해소(2026-08-26, 마이그레이션 42)**. `목표 − min(목표×2%, 300m)` 으로 통일(§10.2 표) — 같은 "목표 거리 완주" 판정이므로 별도 기준을 둘 이유가 없다 | — |
| ~~15~~ | ~~`session_distance_gte` 5종은 허용오차 없이 정확히 `≥ 목표×1000m`~~ → **해소(2026-08-26, 마이그레이션 42)**. 동일 허용오차 `목표 − min(목표×2%, 300m)`로 통일(완화 방향이라 소급 회수 없음, `evaluate_badges` 재실행으로 미지급분 채움) | — |
| 14 | **`tier_change_history` 가 0행이라 XP-4(티어 도달 XP)가 아무에게도 적립되지 않고 있다.** 마이그레이션 34가 "상승 이벤트만 기록"으로 정정하면서 백필을 취소했고(소급 복원 불가는 의도된 결정), 기존 유저는 이번 시즌에 강등 없이는 다시 상승할 기회가 없다. 다음 시즌부터 정상 적립된다 — 그때까지 `total_xp` 는 XP-4 만큼 과소 집계된 상태다 | 2026-Q4 시즌 시작 시 자연 해소 |
| 16 | **`session_distance_gte`는 실내 러닝을 제외하지 않는데 `pb_first_achieved`/`season_first_long_distance`는 제외한다.** 마이그레이션 42가 세 조건을 "같은 목표 거리 판정"으로 선언해 허용오차만 통일했고 실내 취급 차이는 그대로 남았다 — 트레드밀 42.2km는 `session_dist_full`(풀런)은 받고 `pb_first_full`/`season_first_long_distance`는 못 받는다. PRD §8.3(실내 기록 처리)만으로는 이 셋 중 무엇이 맞는 기준인지 단정할 수 없다 | gamification-designer 확인 대상 |
| 18 | **`user_badges`에 "판정 확정값" 컬럼이 없다** — PB 카드가 서버가 확정한 기록(초)을 그릴 수 없는 구간이 생긴다(§3.9.1). 제안: `achieved_value numeric null` 한 컬럼에 서버가 판정 시점 값(PB 초 / 스트릭 주 / 주간 순위)을 적는다. **P0는 이것 없이 성립**한다(102% 이내는 `moving_seconds`가 곧 서버 규칙, 초과 구간은 시간을 비운 카드) — 이 컬럼이 생기면 폴백 분기가 사라진다 | P1, backend-engineer |
| ~~19~~ | ~~성취 큐에 소비자가 없어 밀린 `is_seen=false` 뱃지가 한꺼번에 쏟아진다~~ → **해소(2026-08-26, UI 구현)**. `isAchievementBacklog()`(`features/sharing/domain/achievement_backlog.dart`)가 **개수(>5) 또는 획득 시각 간격(>24h)** 중 하나라도 걸리면 큐를 "밀린 성취"로 보고 "그동안 받은 뱃지 N개" 한 장으로 접은 뒤 **일괄** `markBadgesSeen` 한다. 요약 화면·전역 호스트 양쪽에 같은 판정이 걸려 있다. **로컬 "이미 처리함" 플래그는 두지 않았다** — 접고 나면 서버 행이 `is_seen=true`가 되어 큐에서 영구히 빠지므로 그 상태는 이미 서버가 들고 있고, 같은 사실을 두 곳에 적으면 재설치·기기 변경에서 어긋난다 | — |
| 17 | **클라이언트 진행률 바가 마이그레이션 42의 새 허용오차(§10.2)를 반영하지 않는다.** `badge_condition.dart`의 `sessionDistanceGte` 진행률 계산이 여전히 `distance/목표`(정확 비율)라, 텐런을 9.8km(서버 인정 기준)에서 뛰어도 바는 98.00%로 멈춘다. 실제 지급 시점에 `isEarned`가 `ratio: 1.0`으로 스냅해 자가 치유되므로 사용자에게 "받았는데 바가 98%"로 잠깐 보이는 정도이며, 클라이언트가 값을 내는 조건이 이 하나뿐이라 영향 범위는 좁다 | 다음 gamification-designer/flutter-ui-designer 라운드에서 진행률 계산에 동일 허용오차 반영 |
| 20 | **성취 억제 카운터와 전역 축하 다이얼로그 사이에 프레임 경합이 있다**(QA F-2, `achievement_celebration.dart`). `suppressAchievementCelebrations()`는 다음 프레임에 +1 하고 `AchievementCelebrationHost._present`도 같은 프레임에 post-frame으로 등록되는데, 호스트가 조상이라 먼저 실행돼 억제 카운터를 아직 0으로 본다. 정상 흐름(러닝 종료 후 뱃지가 뒤늦게 도착)에서는 발생하지 않고, "요약 화면 진입 시점에 이미 큐가 차 있는 경우"(밀린 뱃지 등)에 한정된다 — 전역 다이얼로그와 인라인 축하가 동시에 뜰 수 있다 | flutter-ui-designer, `_present` 진입부에서 `endOfFrame` 후 재확인 한 줄로 해소 가능 |
| 21 | **뱃지 아트 경로 규칙이 다시 두 곳이다**(QA O-4) — `badge_assets.dart`의 정본 `badgeAssetPath`와 `share_card_body.dart`의 `tierEmblemAssetPath`가 별도로 존재한다. 현재는 `assets/badges/tier/{bronze,silver,gold,platinum}.svg` 파일명이 우연히 일치해 문제가 드러나지 않지만, 이번 라운드가 없앤 이원화와 같은 형태다 | flutter-ui-designer, 정본으로 통합 |
| 22 | **`share_card_renderer.dart` 주석의 뱃지 SVG 종수가 158종으로 적혀 있으나 정본(`docs/badge-catalog.csv`)은 현재 146개다.** 판정 로직에 쓰이는 숫자는 아니고 서술뿐이지만, 카탈로그 삭제(마이그레이션 35/37)가 반영 안 된 흔적이다 | 문서 정리, 낮은 우선순위 |
