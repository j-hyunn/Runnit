# Runnit 데이터 모델 & 아키텍처 명세서 v1.0

- 작성: mobile-architect
- 일자: 2026-08-19
- 상태: **확정 (v1.0)** — 이 문서는 팀 전체의 source of truth다. 변경 시 전원 브로드캐스트.
- 대상 독자: backend-engineer(스키마 설계 시 직접 참조), gps-tracking-engineer, gamification-designer, flutter-ui-designer, qa-integration-tester

> **빌드 상태 주의:** 이 머신에 Flutter SDK 설치가 진행 중이라 `flutter create` / `flutter pub get` / `build_runner`를 아직 실행하지 못했다. 따라서 `*.freezed.dart` / `*.g.dart` **생성 파일이 존재하지 않으며, 현재 코드는 컴파일되지 않는다.** SDK 설치 완료 후 아래를 실행해야 한다.
>
> ```bash
> flutter pub get
> dart run build_runner build --delete-conflicting-outputs
> ```
>
> 또한 `flutter create . --platforms=ios,android` 로 android/ ios/ 플랫폼 폴더를 생성해야 한다 (기존 lib/ pubspec.yaml 은 덮어쓰지 않도록 주의 — `flutter create`는 기존 파일을 보존하지만 `pubspec.yaml`은 확인 후 병합할 것).

---

## 0. 단위 규약 (Unit Contract) — 가장 중요

**모든 저장/전송 값은 SI 단위다.** km, 마일, `5'30"` 같은 표현은 표시 계층에서만 생성한다. 단위가 섞이면 GPS·게이미피케이션·백엔드 세 모듈에서 서로 다른 환산이 일어나 랭킹 점수가 어긋난다.

| 개념 | 단위 | Dart 타입 | 필드명 접미사 규칙 |
|------|------|-----------|-------------------|
| 거리 | 미터 (m) | `double` | `...Meters` |
| 시간(구간) | 초 (s) | `int` | `...Seconds` |
| 페이스 | 초/킬로미터 (s/km) | `double` | `...SecPerKm` |
| 속도 | 초당 미터 (m/s) | `double` | `...Mps` |
| 고도 | 미터 (m) | `double` | `...Meters` |
| 심박수 | bpm | `int` | `...Bpm` |
| 케이던스 | spm (steps/min) | `int` | `...Spm` |
| 칼로리 | kcal | `int` | `...Kcal` |
| 각도(방위) | degree | `double` | `...Degrees` |
| 좌표 | WGS84 degree | `double` | `latitude` / `longitude` |
| 시각 | **UTC** `DateTime` | `DateTime` | `...At` |

**시각 규칙:** 모든 `DateTime`은 UTC로 저장·전송한다 (직렬화는 ISO-8601). 로컬 타임존 변환은 표시 시점에만. DB 측은 `timestamptz`를 사용한다.

**페이스 vs 시간 두 종류:** `elapsedSeconds`(벽시계, 일시정지 포함)와 `movingSeconds`(순수 이동)를 구분한다. **페이스 계산의 분모는 항상 `movingSeconds`다.**

파생값(`distanceKm`, `avgSpeedMps`)은 모델의 getter로만 제공하며 저장하지 않는다. 구현: `lib/core/utils/units.dart`.

---

## 1. 필드명 매핑 규칙 (Dart ↔ Postgres) — backend-engineer 필독

### 1.1 자동 변환 규칙

모든 모델의 factory 생성자에 `@JsonSerializable(fieldRename: FieldRename.snake)`를 적용했다 (freezed는 이 애너테이션을 클래스가 아니라 생성자에서 읽는다). 따라서:

> **Dart의 camelCase 필드는 자동으로 snake_case JSON 키로 직렬화된다. DB 컬럼명은 이 snake_case 키와 1:1로 정확히 일치해야 한다.**

| Dart 필드 | JSON 키 = DB 컬럼 |
|-----------|-------------------|
| `distanceMeters` | `distance_meters` |
| `avgPaceSecPerKm` | `avg_pace_sec_per_km` |
| `movingSeconds` | `moving_seconds` |
| `heartRateBpm` | `heart_rate_bpm` |
| `userId` | `user_id` |
| `routePolyline` | `route_polyline` |
| `totalDistanceMeters` | `total_distance_meters` |

**금지사항:** 쿼리 계층에서 수동으로 키를 매핑하지 말 것. 별칭(`select('distance_meters as distance')`)을 쓰면 `fromJson`이 깨진다. 컬럼명을 바꿔야 하면 반드시 mobile-architect에게 먼저 알리고 모델을 함께 수정한다.

### 1.2 enum 매핑

모든 enum은 **snake_case 문자열**로 직렬화된다 (`@JsonValue`로 명시). Postgres 측은 동일 이름의 enum 타입 또는 CHECK 제약이 걸린 `text`를 쓴다.

| Dart enum 값 | 전송 문자열 |
|--------------|-------------|
| `ActivityType.outdoorRun` | `outdoor_run` |
| `RankingPeriod.allTime` | `all_time` |
| `RunSampleSource.watch` | `watch` |
| `ChallengeType.distanceTotal` | `distance_total` |

### 1.3 서버 전용 / 클라이언트 전용 필드

| 필드 | 규칙 |
|------|------|
| `AppUser.totalDistanceMeters`, `totalMovingSeconds`, `totalRunCount`, `totalPoints`, `level`, `currentStreakDays`, `longestStreakDays`, `lastRunAt` | **서버 전용 쓰기.** 클라이언트는 읽기만. RLS/트리거로 클라이언트 UPDATE를 차단할 것 |
| `RunRecord.awardedPoints` | 서버 재검증 후 서버가 확정. 클라이언트 값 신뢰 금지 |
| `UserBadge.earnedAt` | 서버 시각으로 확정 (클라이언트 시각 조작 방지) |
| `RankingEntry.*` 전체 | 서버 집계 결과 읽기 전용 |
| `RunRecord.syncStatus` | **클라이언트 로컬 전용.** `@JsonKey(includeToJson: false, includeFromJson: false)` — DB 컬럼을 만들지 말 것 |
| `RunRecord.id` | **클라이언트가 UUID v4 생성.** 서버는 이 값을 PK로 그대로 수용해야 한다(오프라인 업로드 멱등성). `gen_random_uuid()` 기본값은 두되 INSERT 시 클라이언트 값이 우선 |

---

## 2. 엔티티 명세

### 2.1 `RunSample` — 단일 측정 시점 (`lib/models/run_sample.dart`)

**핵심 원칙: 폰 GPS와 워치 센서를 하나의 모델로 통합한다.** 소스는 `source` 필드로만 구분하며 `PhoneRunSample`/`WatchRunSample` 분리 모델을 만들지 않는다. 분리 시 게이미피케이션·백엔드·UI 세 곳에서 소스 분기 처리가 중복된다.

| 필드 | 타입 | 단위 | Nullable | 설명 |
|------|------|------|:--------:|------|
| `latitude` | `double` | WGS84 deg | O | 실내 러닝(트레드밀)은 null |
| `longitude` | `double` | WGS84 deg | O | 실내 러닝은 null |
| `timestamp` | `DateTime` | UTC | X | 측정 시각 |
| `altitudeMeters` | `double` | m | O | 기압계/GPS 고도 미지원 시 null |
| `accuracyMeters` | `double` | m | O | 수평 정확도 반경. 클수록 부정확 — 스무딩 필터 입력 |
| `speedMps` | `double` | m/s | O | 기기 미제공 시 null, 소비 측에서 좌표 미분으로 대체 |
| `headingDegrees` | `double` | deg (0=북) | O | |
| `heartRateBpm` | `int` | bpm | O | 웨어러블 연동 시에만 |
| `cadenceSpm` | `int` | spm | O | |
| `cumulativeDistanceMeters` | `double` | m | O | 세션 시작부터 누적. 트래킹 엔진이 채움 |
| `source` | `RunSampleSource` | — | X | `phone` / `watch` / `external` |

**저장 전략 (backend-engineer 결정 필요):** 1시간 러닝 ≈ 3,600 샘플. 행 단위 저장(`run_samples` 테이블)은 인덱스 부담이 크다. **권장: `runs.samples`를 `jsonb`(또는 압축 바이너리) 단일 컬럼으로 저장**하고, 지도 썸네일은 `route_polyline`로 별도 제공. 샘플 단위 쿼리 요구가 없기 때문. 이견이 있으면 회신 바람.

### 2.2 `RunRecord` — 러닝 세션 (`lib/models/run_record.dart`)

| 필드 | 타입 | 단위 | Nullable | 설명 |
|------|------|------|:--------:|------|
| `id` | `String` | UUID v4 | X | **클라이언트 생성** |
| `userId` | `String` | UUID | X | = `auth.users.id` |
| `startedAt` | `DateTime` | UTC | X | |
| `endedAt` | `DateTime` | UTC | O | 진행 중이면 null |
| `activityType` | `ActivityType` | — | X | `outdoor_run` 등 |
| `status` | `RunStatus` | — | X | `recording`/`paused`/`completed`/`discarded` |
| `distanceMeters` | `double` | m | X | 스무딩 적용 후 |
| `elapsedSeconds` | `int` | s | X | 벽시계 경과(일시정지 포함) |
| `movingSeconds` | `int` | s | X | 순수 이동. **페이스 분모** |
| `avgPaceSecPerKm` | `double` | s/km | O | 거리 0이면 null |
| `maxSpeedMps` | `double` | m/s | O | |
| `elevationGainMeters` | `double` | m | O | 누적 상승 |
| `elevationLossMeters` | `double` | m | O | 누적 하강 |
| `avgHeartRateBpm` | `int` | bpm | O | |
| `maxHeartRateBpm` | `int` | bpm | O | |
| `caloriesKcal` | `int` | kcal | O | 추정값 |
| `avgCadenceSpm` | `int` | spm | O | |
| `samples` | `List<RunSample>` | — | X (기본 `[]`) | **목록 조회 시 빈 배열**, 상세에서만 채움 |
| `routePolyline` | `String` | — | O | Google encoded polyline (precision 5) |
| `title` | `String` | — | O | |
| `note` | `String` | — | O | |
| `syncStatus` | `SyncStatus` | — | X (기본 `local`) | **직렬화 제외 — DB 컬럼 없음** |
| `sources` | `List<RunSampleSource>` | — | X (기본 `[]`) | 기여 소스 목록 |
| `awardedPoints` | `int` | pt | O | **서버 확정값** |
| `createdAt` / `updatedAt` | `DateTime` | UTC | O | 서버 관리 |

파생 getter: `distanceKm`, `avgSpeedMps`, `isActive` — 저장하지 않음.

**인덱스 권장:** `(user_id, started_at DESC)` — 히스토리 목록 조회. 랭킹 집계용으로 `(user_id, started_at)` 부분 인덱스 `WHERE status = 'completed'`.

### 2.3 `AppUser` — 사용자 프로필 (`lib/models/app_user.dart`)

클래스명이 `User`가 아니라 `AppUser`인 이유: Supabase SDK의 `User`, Flutter 생태계의 다른 `User`와 이름 충돌을 피하기 위함. **DB 테이블명은 `profiles`**, `id`는 `auth.users.id`를 참조하는 UUID PK.

| 필드 | 타입 | 단위 | Nullable | 설명 |
|------|------|------|:--------:|------|
| `id` | `String` | UUID | X | = `auth.users.id` |
| `username` | `String` | — | X | 고유 핸들. **UNIQUE 제약 필요** |
| `displayName` | `String` | — | O | 미설정 시 UI가 username으로 폴백 |
| `avatarUrl` | `String` | — | O | |
| `bio` | `String` | — | O | |
| `crewId` | `String` | UUID | O | 러닝크루. 미소속 null |
| `heightCm` | `double` | cm | O | 칼로리 추정용 |
| `weightKg` | `double` | kg | O | 칼로리 추정용 |
| `birthDate` | `DateTime` | UTC 자정 | O | 연령대 랭킹/칼로리 |
| `gender` | `Gender` | — | O | |
| `preferredUnit` | `DistanceUnit` | — | X (기본 `metric`) | **표시 전용** |
| `totalDistanceMeters` | `double` | m | X (기본 0) | 서버 캐시 |
| `totalMovingSeconds` | `int` | s | X (기본 0) | 서버 캐시 |
| `totalRunCount` | `int` | 회 | X (기본 0) | 서버 캐시 |
| `totalPoints` | `int` | pt | X (기본 0) | 서버 캐시 |
| `level` | `int` | — | X (기본 1) | totalPoints에서 서버 파생 |
| `currentStreakDays` | `int` | 일 | X (기본 0) | 서버 캐시 |
| `longestStreakDays` | `int` | 일 | X (기본 0) | 서버 캐시 |
| `lastRunAt` | `DateTime` | UTC | O | 스트릭 판정 기준 |
| `createdAt` | `DateTime` | UTC | X | |
| `updatedAt` | `DateTime` | UTC | O | |

**통계 캐시 설계 근거:** 프로필/랭킹 화면마다 `runs` 전체 집계를 하면 사용자·기록이 늘수록 선형으로 느려진다. 러닝 업로드 시 트리거로 증분 갱신하는 비정규화 캐시를 둔다. 대신 **정합성 책임은 서버에 있다** — 기록 삭제/수정 시 캐시 재계산 경로를 반드시 구현할 것.

### 2.4 `Badge` / `UserBadge` (`lib/models/badge.dart`)

카탈로그(정의)와 획득 기록을 분리한다. 합치면 사용자 수 × 뱃지 수만큼 정의가 중복 저장된다.

**`Badge` (마스터 데이터, 테이블 `badges`)**

| 필드 | 타입 | 단위 | Nullable | 설명 |
|------|------|------|:--------:|------|
| `id` | `String` | 슬러그 | X | 예: `distance_10k`. **UUID가 아닌 사람이 읽는 키** |
| `name` | `String` | — | X | |
| `description` | `String` | — | X | |
| `category` | `BadgeCategory` | — | X | distance/streak/pace/elevation/social/challenge/special |
| `tier` | `BadgeTier` | — | X | bronze/silver/gold/platinum |
| `iconAsset` | `String` | — | X | `assets/badges/{id}.png` 컨벤션 |
| `criteriaType` | `String` | — | X | 판정 지표 키 (gamification-designer 정의) |
| `threshold` | `double` | criteriaType에 종속 | X | 임계값 |
| `points` | `int` | pt | X (기본 0) | 획득 시 부여 |
| `sortOrder` | `int` | — | X (기본 0) | |
| `isSecret` | `bool` | — | X (기본 false) | 히든 뱃지 |
| `isActive` | `bool` | — | X (기본 true) | 시즌 종료 뱃지 비활성화 |

**`criteriaType` 단위 규약:** 접미사에 단위를 내장한다 — `single_run_distance_m`, `total_distance_m`, `streak_days`, `pace_sec_per_km_below`, `elevation_gain_m`, `run_count`. 판정 조건을 코드에 하드코딩하지 않고 데이터화한 이유: 뱃지 추가마다 앱 배포가 필요해지는 것을 막기 위함.

**`UserBadge` (테이블 `user_badges`)**

| 필드 | 타입 | Nullable | 설명 |
|------|------|:--------:|------|
| `id` | `String` (UUID) | X | 서버 생성 |
| `userId` | `String` | X | |
| `badgeId` | `String` | X | → `badges.id` (슬러그 FK) |
| `earnedAt` | `DateTime` UTC | X | **서버 시각 확정** |
| `sourceRunId` | `String` | O | 계기가 된 러닝 |
| `isSeen` | `bool` | X (기본 false) | 획득 연출 표시 여부 |
| `badge` | `Badge` | O | 조인 결과(전송 시 중첩 객체). DB 컬럼 아님 |

**제약:** `UNIQUE (user_id, badge_id)` — 중복 획득 방지.

### 2.5 `RankingEntry` — 리더보드 행 (`lib/models/ranking_entry.dart`)

**읽기 전용 뷰 모델.** 클라이언트는 절대 순위를 계산하지 않는다.

| 필드 | 타입 | 단위 | Nullable | 설명 |
|------|------|------|:--------:|------|
| `userId` | `String` | UUID | X | |
| `username` | `String` | — | X | 집계 시점 스냅샷(비정규화) |
| `displayName` | `String` | — | O | |
| `avatarUrl` | `String` | — | O | |
| `rank` | `int` | — | X | **1부터 시작.** 동점자는 같은 순위 공유 후 건너뜀 (1,2,2,4) |
| `rankDelta` | `int` | — | O | 직전 집계 대비 변동. 양수=상승 |
| `metric` | `RankingMetric` | — | X | distance/duration/run_count (points 제거됨 — 2026-08-20 리더 결정, 아래 각주 참조) |
| `score` | `double` | metric에 종속 | X | **클수록 상위** |
| `tieBreakValue` | `double` | s | O | **작을수록 상위** (예: 동일 거리면 총 시간 짧은 쪽) |
| `period` | `RankingPeriod` | — | X | daily/weekly/monthly/all_time |
| `scope` | `RankingScope` | — | X | global/crew/friends |
| `crewId` | `String` | UUID | O | crew 스코프일 때만 |
| `periodStart` | `DateTime` UTC | — | X | 반열림 구간 `[start, end)` |
| `periodEnd` | `DateTime` UTC | — | X | |
| `runCount` | `int` | 회 | O | 부가 표시 |
| `totalMovingSeconds` | `int` | s | O | 부가 표시 |
| `computedAt` | `DateTime` UTC | — | O | "N분 전 기준" 표시용 |

`score` 단위: `distance`→미터, `duration`→초, `runCount`→회.

> **[2026-08-20 업데이트] `points`(게이미피케이션 포인트) 랭킹 지표는 제거되었다.** 리더 결정 —
> 별도 요청 없이 처음부터 있던 지표였고, 굳이 필요하지 않다고 판단. `RankingMetric` enum에서
> `points` 값을 삭제했고(`lib/models/enums.dart`), DB `ranking_metric` enum도 동일하게 재생성해
> 반영했다(`supabase/migrations/20260820000000_16_remove_points_ranking_metric.sql`).
> 뱃지/챌린지로 얻는 게이미피케이션 포인트 자체(`AppUser.totalPoints`, 레벨 산정)는 그대로
> 유지된다 — 없앤 것은 "포인트로 순위를 매기는 리더보드"뿐이다.

**동점 처리 규약 (gamification-designer와 합의 필요):** `score` 내림차순 → `tieBreakValue` 오름차순 → `userId` 오름차순(결정론적 안정 정렬). 순위 표시는 `RANK()`(1,2,2,4)이지 `DENSE_RANK()`(1,2,2,3)가 아니다.

**기간 경계:** 주간/월간 경계는 **사용자 로컬 타임존이 아니라 앱 표준 타임존(Asia/Seoul)** 기준으로 정한다 — 타임존별로 다르면 같은 리더보드에 서로 다른 기간이 섞인다. 최종 확정은 backend-engineer와 조율.

### 2.6 `Challenge` / `ChallengeParticipation` (`lib/models/challenge.dart`)

**`Challenge`**

| 필드 | 타입 | 단위 | Nullable | 설명 |
|------|------|------|:--------:|------|
| `id` | `String` (UUID) | — | X | |
| `title` / `description` | `String` | — | X | |
| `type` | `ChallengeType` | — | X | distance_total / run_count / single_run_distance / streak_days / elevation_total |
| `status` | `ChallengeStatus` | — | X | upcoming/active/ended/archived |
| `targetValue` | `double` | **type에 종속** | X | 거리형→m, 횟수형→회, 스트릭→일 |
| `startAt` / `endAt` | `DateTime` UTC | — | X | 반열림 구간 `[startAt, endAt)` |
| `bannerImageUrl` | `String` | — | O | |
| `rewardBadgeId` | `String` | — | O | → `badges.id` |
| `rewardPoints` | `int` | pt | X (기본 0) | |
| `crewId` | `String` | UUID | O | null이면 전체 공개 |
| `participantCount` | `int` | 명 | X (기본 0) | 서버 캐시 |
| `createdAt` | `DateTime` UTC | — | X | |

**`ChallengeParticipation`**

| 필드 | 타입 | 단위 | Nullable | 설명 |
|------|------|------|:--------:|------|
| `id` | `String` (UUID) | — | X | |
| `challengeId` / `userId` | `String` | — | X | `UNIQUE (challenge_id, user_id)` |
| `joinedAt` | `DateTime` UTC | — | X | |
| `progressValue` | `double` | Challenge.type에 종속 | X (기본 0) | **서버 갱신** |
| `completedAt` | `DateTime` UTC | — | O | null이면 미완주 |
| `rank` | `int` | — | O | 랭킹형 챌린지에서만 |
| `challenge` | `Challenge` | — | O | 조인 결과. DB 컬럼 아님 |

---

## 3. 엔티티 관계

```
AppUser (profiles)
  │ 1
  ├──< RunRecord (runs)                      user_id
  │       └──< RunSample                     runs.samples (jsonb 권장, 별도 테이블 아님)
  ├──< UserBadge (user_badges)               user_id ─> badges.id
  ├──< ChallengeParticipation                user_id ─> challenges.id
  ├──── RankingEntry (집계 뷰)                user_id (실체 테이블 아님/MV)
  └──── crew_id ─> crews (v1.1 예정, 모델 미정의)

Badge (badges, 마스터)  ──< UserBadge
Challenge (challenges)  ──< ChallengeParticipation
                        └── reward_badge_id ─> badges.id
```

**주의:** `Crew` 엔티티는 이번 단계에서 정의하지 않았다. `AppUser.crewId`, `RankingEntry.crewId`, `Challenge.crewId`가 참조하는 대상이므로, 크루 기능 착수 시 mobile-architect가 `Crew` 모델을 추가하고 재브로드캐스트한다. **backend-engineer는 `crews` 테이블을 선반영해도 되나, 컬럼 확정 전까지는 `crew_id`를 nullable로 둘 것.**

---

## 4. 상태관리 — Riverpod provider 계층

### 4.1 선택 근거

Riverpod을 기본값으로 정했다. 근거는 세 가지다. (1) 컴파일 타임 안전성 — provider 오타를 빌드 시점에 잡는다. (2) `ProviderScope(overrides:)`로 목킹이 쉬워 GPS/네트워크 없이 화면 테스트가 가능하다. (3) 이 앱은 GPS 스트림처럼 백그라운드에서 갱신되는 상태를 여러 화면이 동시 구독하는 구조인데, `StreamProvider`가 이 패턴에 정확히 들어맞는다.

이는 근거 있는 기본값이지 강제사항이 아니다. 팀이 Bloc을 선호하면 모델 계층은 그대로 두고 상태 계층만 교체 가능하다(모델이 상태관리에 의존하지 않도록 설계했다).

### 4.2 provider 계층

```
[Infra 계층]  core/providers/repository_providers.dart
  runRepositoryProvider           Provider<RunRepository>
  rankingRepositoryProvider       Provider<RankingRepository>
  gamificationRepositoryProvider  Provider<GamificationRepository>
  userRepositoryProvider          Provider<UserRepository>
      ↑ 현재 전부 UnimplementedError. 각 담당이 구현체로 교체.

[Domain/State 계층]  features/{name}/domain/
  tracking     runTrackingServiceProvider   Provider<RunTrackingService>
               liveSamplesProvider          StreamProvider<RunSample>
               activeSessionProvider        StreamProvider<RunRecord>
               runSessionControllerProvider NotifierProvider  (start/pause/stop 명령)
  history      runHistoryProvider           FutureProvider.family<List<RunRecord>, HistoryQuery>
               runDetailProvider            FutureProvider.family<RunRecord?, String>
  ranking      leaderboardProvider          StreamProvider.family<List<RankingEntry>, LeaderboardQuery>
               myRankProvider               FutureProvider.family<RankingEntry?, LeaderboardQuery>
  gamification badgeCatalogProvider         FutureProvider<List<Badge>>   (장기 캐시)
               userBadgesProvider           FutureProvider.family<List<UserBadge>, String>
               unseenBadgeQueueProvider     StreamProvider<List<UserBadge>>  (획득 연출 큐)
               challengesProvider           FutureProvider<List<Challenge>>
  profile      currentUserProvider          StreamProvider<AppUser?>

[UI 계층]  features/{name}/presentation/  — ConsumerWidget에서 watch만 한다
```

**패턴 규칙**
- `StreamProvider`: GPS 위치 스트림, 실시간 랭킹 구독, 미확인 뱃지 큐
- `NotifierProvider`: 러닝 세션 명령 상태(진행중/일시정지/종료)
- `FutureProvider`: 히스토리·리더보드 등 1회성 비동기 조회
- **UI는 repository를 직접 참조하지 않는다.** 반드시 domain provider를 경유한다.

### 4.3 모듈 경계 (핵심)

트래킹 모듈은 백엔드/게이미피케이션 모듈에 **직접 의존하지 않는다.** `RunTrackingService`는 `sampleStream` / `sessionStream`을 방출할 뿐이고, 저장·뱃지 판정은 이 스트림을 구독하는 상위 계층이 담당한다. 덕분에 트래킹 로직을 게이미피케이션과 독립적으로 테스트할 수 있고, 트래킹 소스가 늘어나도(트레드밀 연동 등) 하위 모듈 수정이 필요 없다.

계약: `lib/features/tracking/domain/run_tracking_service.dart`

---

## 5. 폴더 컨벤션

```
lib/
  main.dart                     앱 진입점 (Supabase 초기화 지점)
  app.dart                      MaterialApp.router
  models/                       ★ 공유 데이터 모델 (mobile-architect 전담)
    models.dart                 배럴 — 타 feature는 이것만 임포트
    enums.dart run_sample.dart run_record.dart
    app_user.dart badge.dart ranking_entry.dart challenge.dart
  core/
    api/supabase_client.dart    backend-engineer
    config/app_config.dart      dart-define 환경변수
    error/failure.dart          계층 경계 에러 타입 (sealed)
    providers/                  repository provider 등록 지점
    repositories/               ★ 레포지토리 추상 계약 (mobile-architect 전담)
    router/app_router.dart      go_router
    theme/app_theme.dart        flutter-ui-designer 확장
    utils/                      units.dart(단위 기준점), formatters.dart
    widgets/app_shell.dart      바텀 네비 셸
  features/
    tracking/  history/  ranking/  gamification/  profile/
      data/          외부 연동 구현 (backend-engineer, gps-tracking-engineer)
      domain/        비즈니스 로직 + provider (각 도메인 담당)
      presentation/  위젯 (flutter-ui-designer)
```

**feature-first를 택한 이유:** 레이어 우선(전체를 `models/`·`screens/`·`services/`로 분할)은 서로 다른 기능의 코드가 같은 폴더에 모여 병렬 작업 시 파일 충돌이 잦다. 기능별로 나누고 그 안에서 data/domain/presentation을 나누면, flutter-ui-designer는 `presentation/`만, backend-engineer는 `data/`만 건드리게 되어 충돌이 줄어든다.

**예외:** 공유 모델(`models/`)과 레포지토리 계약(`core/repositories/`)은 여러 feature가 함께 쓰므로 feature 밖에 두고 mobile-architect가 단독 관리한다. 이 두 디렉토리를 다른 에이전트가 임의 수정하면 계약이 깨진다 — 변경이 필요하면 요청할 것.

---

## 6. 패키지 선정 근거

| 목적 | 패키지 | 선정 이유 |
|------|--------|-----------|
| 상태관리 | `flutter_riverpod` + `riverpod_annotation`/`riverpod_generator` | §4.1 참조 |
| 불변 모델 | `freezed` + `json_serializable` | copyWith/==/직렬화 자동 생성. 수동 `toJson`은 필드 추가 시 누락됨 |
| 라우팅 | `go_router` | 딥링크(챌린지 초대), `StatefulShellRoute`로 탭별 네비 스택 유지 |
| GPS | `geolocator` | 위치 스트림 + 정확도/거리필터 옵션, 거리 계산 유틸 내장 |
| 백그라운드 | `flutter_background_service` | 화면 꺼짐/앱 백그라운드에서 세션 유지 — 러닝앱 필수 |
| 웨어러블 | `health` | HealthKit/Health Connect 통합 래퍼. **Apple Watch는 HealthKit 경유, Garmin은 Garmin Connect→HealthKit/Health Connect 동기화 경유** (CLAUDE.md 확정사항) |
| 권한 | `permission_handler` | iOS/Android 위치·활동·건강 권한 흐름 통합 |
| 백엔드 | `supabase_flutter` | Auth+Postgres+Realtime(랭킹 구독)+Storage 단일 SDK. Supabase MCP 연결 환경 |
| 로컬 DB | `drift` + `sqlite3_flutter_libs` | 진행 중 샘플을 append-only로 저장 → 앱 강제종료/네트워크 없이도 기록 보존 |
| 지도 | `flutter_map` + `latlong2` | API 키/과금 없이 시작. 더 정교한 UX 필요 시 `google_maps_flutter`로 교체 — 교체 비용을 줄이려 지도 위젯을 얇은 래퍼 뒤에 격리할 것 |
| 차트 | `fl_chart` | 페이스/고도/심박 추이 시각화 |
| 기타 | `uuid`(오프라인 멱등 id), `intl`(로케일 포맷), `logger`, `shared_preferences` | |
| lint | `flutter_lints` + `custom_lint` + `riverpod_lint` | provider 오용을 정적 검출 |

**미확정 트레이드오프 (사용자/팀 확인 필요)**
1. **지도**: `flutter_map`(무료, 타일 서버 정책 확인 필요) vs `google_maps_flutter`(UX 우수, API 키·과금). 초기값은 flutter_map.
2. **샘플 저장 형식**: `runs.samples` jsonb 단일 컬럼 vs `run_samples` 별도 테이블. 초기값은 jsonb — backend-engineer 회신 대기.
3. **`riverpod_generator` 도입 범위**: 코드젠 provider(`@riverpod`)와 수동 provider를 섞으면 혼란스럽다. 현재 골격은 수동 provider로 작성했고, 팀 합의 시 일괄 전환한다.

---

## 7. 다음 단계 및 인수인계

| 담당 | 해야 할 일 |
|------|-----------|
| (환경) | Flutter SDK 설치 완료 후 `flutter create . --platforms=ios,android`(기존 lib/pubspec 보존 확인) → `flutter pub get` → `dart run build_runner build --delete-conflicting-outputs`. 이때까지 코드는 컴파일되지 않는다 |
| backend-engineer | §1 매핑 규칙대로 Supabase 스키마 설계. §2.1 샘플 저장 전략, §2.5 기간 경계 타임존, 서버 전용 필드 RLS 회신 |
| gps-tracking-engineer | `RunTrackingService` 구현 + `features/tracking/data/`에 로컬 `RunRepository` |
| gamification-designer | `Badge.criteriaType` 키 목록 확정, 뱃지 카탈로그 시드, 동점 처리 규약 확인 |
| flutter-ui-designer | `presentation/` placeholder 교체, `AppTheme` 토큰 확장 |
| qa-integration-tester | build_runner 성공 후 모델↔스키마 필드 대조 |

**변경 요청 절차:** 모델에 없는 필드가 필요하면 mobile-architect에게 요청한다. 각자 로컬에서 모델을 수정하면 계약이 갈라진다. 확장은 즉시 반영 후 전원 브로드캐스트한다.
