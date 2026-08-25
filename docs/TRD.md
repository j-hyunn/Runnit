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

- `source`는 ARCHITECTURE §6.2 근거로 `phone`/`watchApple`/`watchGarmin`/`watchOther` 4갈래로 세분화한다 — 뱃지·통계에서 기기별 구분이 필요해질 가능성(예: "애플워치로 완주" 뱃지)에 대비하되, HealthKit/Health Connect 경로 자체는 공통이므로 소스 값만 다르게 태깅한다.
- `accuracy`는 GPS 스무딩(§8.2) 판정에 쓰인다.

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

### 3.6 `Badge` / `UserBadge`

뱃지 카탈로그(158개 템플릿, 16개 카테고리)의 확정 스펙은 [`docs/badge-catalog.csv`](./badge-catalog.csv) 참고. `category`·`scope`는 이 카탈로그에서 역산한 필드다.

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
  seasonCumulativeDistance,  // 시즌누적거리 (seasonal, P1)
  seasonEvent,               // 시즌한정이벤트 (seasonal, GM-08 P1)
  seasonFinisher,            // 시즌완주 (seasonal)
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
    required Map<String, dynamic> condition,  // 판정 함수 입력 파라미터
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
    required String userId,
    required String badgeId,
    required DateTime earnedAt,
    @Default(false) bool verified,   // 서버 재검증 결과
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

---

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
