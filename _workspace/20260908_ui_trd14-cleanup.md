# 클라이언트 정리 2건 — TRD §14 #17 · #21

- 일자: 2026-09-08
- 담당: flutter-ui-designer
- 범위: **클라이언트 코드만.** 백엔드·스키마·마이그레이션·PRD 스펙 변경 없음
- 근거 문서: `docs/PRD.md` §5.5(뱃지), `docs/TRD.md` §10.2(뱃지 판정 규칙) · §14 #17·#21,
  `supabase/migrations/20260826040000_42_unify_distance_tolerance.sql`

---

## 1. #17 — 진행률 바에 마이그레이션 42 허용오차 반영

### 1.1 문제

`BadgeProgressCalculator` 가 진행률을 `현재값 / 목표값`(정확 비율)로 계산했다.
서버(마이그레이션 42)는 "목표 거리 도달" 판정에 허용오차를 두므로

```
distance_meters >= D*1000 - least(D*1000*0.02, 300.0)
```

텐런(10km)을 9.8km에 뛰면 **서버는 지급**하는데 클라이언트 바는 98%에서 멈춘다.
지급 순간 `isEarned` 가 `ratio: 1.0` 으로 스냅해 자가 치유되지만, 그 사이 사용자에게
"받았는데 바가 98%"로 보인다.

### 1.2 마이그레이션 42 실측 — 어느 조건이 허용오차를 쓰는가

42번 파일의 `evaluate_badge_condition` 전문을 읽어 거리 비교식을 전부 확인했다.

| condition_type | 42번 마이그레이션의 거리 비교식 | 허용오차 |
|---|---|---|
| `session_distance_gte` | `r.distance_meters >= D*1000 - least(D*1000*0.02, 300.0)` | ✅ |
| `pb_first_achieved` | `r.distance_meters >= D*1000 - least(D*1000*0.02, 300.0)` | ✅ |
| `season_first_long_distance` | `r.distance_meters >= D*1000 - least(D*1000*0.02, 300.0)` | ✅ |
| **`cumulative_distance_gte`** | `p.total_distance_meters >= v_distance_km * 1000.0` | **❌ 없음** |

**`cumulative_distance_gte` 는 허용오차를 쓰지 않는다.** 42번이 통일한 것은 "한 번의
목표 거리 완주" 판정 3종이고, 누적 거리는 합계라 대상이 아니다. 따라서 클라이언트도
누적에는 적용하지 않았다 — 여기서만 완화하면 **클라이언트가 서버보다 먼저 100%를
그리는** 반대 방향 불일치가 생긴다.

### 1.3 구현

**`lib/features/gamification/domain/badge_condition.dart`**

- `_distanceTolerancePct = 0.02` / `_distanceToleranceCapMeters = 300.0`
- `_distanceToleranceConditionTypes` — 위 3종만. `cumulative_distance_gte` 를 왜 넣지
  않는지 주석으로 명시
- `bool usesDistanceTolerance(String conditionType)`
- `double effectiveDistanceTargetKm({required String conditionType, required double targetKm})`
  — 대상이 아니거나 목표가 0 이하면 원값을 그대로 반환(호출부가 분기하지 않아도 되게)

이 상수/함수는 **마이그레이션 42 SQL의 거울**이라는 점을 doc 주석에 못박았다. 서버 식이
바뀌면 여기도 같이 바뀌어야 한다.

**`lib/features/gamification/domain/badge_progress.dart`**

- `BadgeProgressCalculator.effectiveTargetOf({conditionType, condition})` 신설 —
  `targetOf` 위에 허용오차를 얹는다
- `forBadge` 가 `targetOf` 대신 이 값을 쓴다 → **`ratio` 와 `meetsThresholdLocally` 가
  같은 유효 목표를 공유**한다(진행률은 100%인데 "곧 지급됩니다"는 안 뜨는 어긋남 방지)
- 방어: 허용오차 대상 조건인데 목표 키가 `distanceKm` 가 아니면(카탈로그 오타 등)
  완화하지 않고 원값을 쓴다 — 서버보다 느슨해지는 쪽이 더 나쁘다

단위는 손대지 않았다. 목표 키 `distanceKm` 도 km, `currentValueFor` 의
`sessionDistanceGte` 반환값도 km라 이미 정합이다.

### 1.4 동작 변화

| 상황 | 이전 | 이후 |
|---|---|---|
| 텐런(10km) 뱃지, 최고 단일 러닝 9.8km | `ratio 0.98`, `meets false` | `ratio 1.0`, `meets true` |
| 텐런 뱃지, 9.79km | `ratio 0.979` | `ratio 0.999`(≠1.0), `meets false` |
| 하프(21.0975km) — 2% = 421.95m > 300m 상한 | 유효 목표 21.0975km | 유효 목표 **20.7975km** |
| 풀(42.195km) | 유효 목표 42.195km | 유효 목표 **41.895km** |
| 누적 100km 뱃지, 누적 98km | `ratio 0.98` | `ratio 0.98`(**불변**) |

⚠️ `isEarned` 는 그대로 **서버가 내려준 `UserBadge` 로만** 결정된다. 이번 변경은 표시용
비율과 "서버 반영 대기" 판정에만 닿으며, 획득 연출을 앞당기지 않는다(ARCHITECTURE 원칙 3).

---

## 2. #21 — 뱃지 아트 경로 규칙 단일화 (QA O-4)

### 2.1 문제

- 정본: `lib/features/gamification/domain/badge_assets.dart` 의 `badgeAssetPath`
- 사본: `lib/features/sharing/presentation/widgets/share_card_body.dart:667`
  `tierEmblemAssetPath(Tier)` 가 `'assets/badges/tier/${tier.name}.svg'` 를 직접 조립

현재 파일명이 우연히 일치해 증상이 없지만, 이전 라운드가 없앤 이원화와 같은 형태다.
정본의 폴더 매핑이나 등급 폴백을 바꾸면 공유 카드만 조용히 갈라진다.

### 2.2 구현

`tierEmblemAssetPath` 를 `badge_assets.dart` 로 **이동**하고, 구현을 정본 위임으로 바꿨다.

```
String tierEmblemAssetPath(Tier tier) => badgeAssetPath(
      category: BadgeCategory.seasonTier,
      badgeGrade: tier.name,
    );
```

- `badgeCategoryAssetFolder(BadgeCategory.seasonTier)` → `'tier'`
- `badgeGradeAssetName('bronze'|'silver'|'gold'|'platinum')` → 그대로(폴백 미발동)

→ **출력 경로는 4개 티어 모두 이전과 완전히 동일.** 행위 변화 없는 구조 정리다.

호출부:

- `share_card_body.dart:363`(`_EmblemArt` 자산), `:685`(`shareCardEmblemAsset`) — 정본
  import 로 전환. 사본 함수 삭제
- `share_card_builder.dart:66`·`:174` — **이미 정본 `badgeAssetPath` 를 쓰고 있어 변경 없음**

`grep -rn "assets/badges/"` 결과, 경로 문자열을 조립하는 코드는 이제 `badge_assets.dart`
한 곳뿐이다.

---

## 3. 테스트

회귀는 기존 `test/gamification/level_curve_test.dart`(뱃지 판정 규칙-서버 계약 잠금 파일)에
붙였다 — 이 파일이 이미 "서버 SQL과 클라이언트 구현이 갈라지지 않았음"을 잠그는 자리다.

**#17 — 9건**

- 허용오차 대상은 3종뿐 / `cumulative_distance_gte` 는 대상이 아니다(서버도 정확 비교)
- 2% 구간: 10km → 9.8km, 5km → 4.9km
- 300m 상한 구간: 21.0975km → 20.7975km, 42.195km → 41.895km
- 목표 0 이하 방어
- 9.8km에서 `ratio 1.0` · `meets true` · **`isEarned` 는 false 유지**
- 9.79km는 여전히 100% 아님
- 누적 98km/100km는 0.98 유지
- `effectiveTargetOf` 가 `distanceKm` 없으면 완화하지 않음

**#21 — 3건**

- `tierEmblemAssetPath(t) == badgeAssetPath(seasonTier, t.name)` (4개 티어 전부)
- 실제 경로 문자열 4건
- `Tier` 4종이 `badgeGradeAssetName` 폴백을 타지 않음

**결과**

```
flutter analyze  → No issues found!
flutter test     → All tests passed!  334건 (기존 322 + 신규 12)
```

`dart run build_runner build --delete-conflicting-outputs` 를 선행했다(워크트리에 생성
파일이 없어 baseline analyze 가 먼저 깨졌다). 생성물은 커밋 대상이 아니다.

---

## 4. 변경 파일

- `lib/features/gamification/domain/badge_condition.dart`
- `lib/features/gamification/domain/badge_progress.dart`
- `lib/features/gamification/domain/badge_assets.dart`
- `lib/features/sharing/presentation/widgets/share_card_body.dart`
- `test/gamification/level_curve_test.dart`
- `docs/TRD.md` (§14 #17·#21 해소 표기 + 변경 이력 v0.31)

디자인 토큰은 새로 만들지 않았다 — 색/타이포/스페이싱을 건드리지 않는 작업이다.

---

## 5. TRD §14 갱신 문구 (적용 완료)

**#17 → 해소**

> ~~클라이언트 진행률 바가 마이그레이션 42의 새 허용오차(§10.2)를 반영하지 않는다~~ →
> **해소(2026-09-08, flutter-ui)**. 허용오차 규칙을 `badge_condition.dart` 에
> `usesDistanceTolerance(conditionType)` + `effectiveDistanceTargetKm({conditionType, targetKm})`
> 로 두고(마이그레이션 42 SQL의 **거울**), `BadgeProgressCalculator.effectiveTargetOf` 가
> 이를 한 번만 적용해 `ratio` 와 `meetsThresholdLocally` 가 **같은 기준**을 쓰게 했다.
> 텐런 9.8km → `ratio 1.0` · `meets true`(`isEarned` 는 false 유지 — 확정은 서버).
> 대상은 서버와 동일한 3종이고 **`cumulative_distance_gte` 는 의도적으로 제외**(42번의
> 누적 분기는 정확 비교 그대로라, 클라이언트만 완화하면 서버보다 먼저 100%를 그린다).
> 회귀 9건.

**#21 → 해소**

> ~~뱃지 아트 경로 규칙이 다시 두 곳이다(QA O-4)~~ → **해소(2026-09-08, flutter-ui)**.
> `share_card_body.dart` 의 `tierEmblemAssetPath` 사본을 삭제하고 정본
> `badge_assets.dart` 로 옮겨 `badgeAssetPath(category: seasonTier, badgeGrade: tier.name)`
> 위임으로 구현. 폴더명 매핑도 등급 폴백도 정본 규칙을 그대로 탄다. 출력 경로는 4개
> 티어 모두 이전과 동일(행위 변화 없는 구조 정리). 회귀 3건.

**변경 이력 v0.31** — `docs/TRD.md` 상단 표에 추가, 문서 버전 v0.30 → v0.31.

---

## 6. 남은 것 / 인접 항목 (이번 범위 아님)

- **§14 #16** — `session_distance_gte` 는 실내 러닝을 제외하지 않는데
  `pb_first_achieved`/`season_first_long_distance` 는 제외한다. 42번이 허용오차만 통일하고
  실내 취급 차이는 남겼다. 이번 클라이언트 작업은 **허용오차만** 맞췄고 실내 취급은
  건드리지 않았다 — #26 웨어러블 라운드 소관
- 진행률 바를 그리는 조건이 아직 4종뿐이다(`cumulativeDistanceGte`·`cumulativeCountGte`·
  `sessionDistanceGte`·`elevationGainCumulativeGte`). `clientEstimable` 로 분류됐는데
  `GamificationStats` 가 수집하지 않는 지표(스트릭 주 단위, 시간대 집계, 페이스 계열,
  device 계열)는 여전히 null → 지표 수집 확장은 별도 후속

---

# 클라이언트 반영 2건 — TRD §14 #18 · #31 (마이그레이션 65·66)

- 일자: 2026-09-08
- 담당: flutter-ui-designer
- 범위: **클라이언트 코드만.** 마이그레이션 SQL·스키마·PRD 스펙 변경 없음
- 전제: 마이그레이션 65·66은 **원격 미적용**. wire 계약이 확정됐으므로 클라이언트만 먼저 맞춘다
- 근거 문서: `_workspace/20260908_backend_trd14-cleanup.md` §5, `docs/TRD.md` §3.9.1 · §14 #18·#31,
  `supabase/migrations/20260908120000_65_badge_achieved_value.sql`,
  `supabase/migrations/20260908120100_66_snapshot_void_rerank.sql`

---

## #18 — PB 카드 폴백 제거 + `achieved_value` 모델 반영

### 1. 모델 — `UserBadge.achievedValue`

`lib/models/badge.dart`

```dart
double? achievedValue,   // wire: achieved_value (numeric null)
```

생성 결과(`badge.g.dart`)가 `(json['achieved_value'] as num?)?.toDouble()` 이므로
서버가 정수로 내려도(스트릭 주 수·등수) 안전하게 승격된다.

**`int` 로 받지 않은 이유는 백엔드 경고 그대로다** — `numeric` 이고 PB 초는 102% 초과 구간의
GPS 선형 보간값이라 소수가 나온다. `int` 로 받으면 그 행에서 파싱이 던진다.

doc 주석에 **단위 표**(조건 타입별 초/주/등수, 나머지 34종 null)와 "진행률이 아니라 판정 시점
확정값"을 함께 박았다. 이 컬럼만 보고 포맷을 정하면 안 된다는 것이 이 값의 유일한 함정이다.

조회 경로는 손댈 것이 없었다 — `supabase_gamification_repository.dart` 가
`select('*, badge:badges(*)')` 라 새 컬럼이 자동으로 따라온다.

### 2. 폴백 제거 — `ShareCardBuilder.certifiedPbSeconds`

시그니처가 바뀌었다.

```
이전: certifiedPbSeconds({required RunRecord? run, required double targetKm})
이후: certifiedPbSeconds({required Badge badge, required UserBadge userBadge})
```

`static const double pbDirectTimeRatio = 1.02` 는 **삭제**했다. 이 상수는 "서버가 확정한 값이
어디에도 없다"는 사실 때문에만 존재했고, 남겨 두면 두 번째 정본으로 되살아난다.

구현은 네 줄이지만 분기는 셋이다.

```dart
if (!pbSecondsConditionTypes.contains(badge.conditionType)) return null;
final value = userBadge.achievedValue;
if (value == null || !value.isFinite || value <= 0) return null;
return value.round();
```

**조건 타입 화이트리스트를 추가한 이유**(지시에 없던 방어 1건, 근거를 남긴다).
`_pbCard` 는 `badge.category == personalBest` 로 진입한다. 그런데 `achieved_value` 의 단위는
**카테고리가 아니라 `condition_type` 이 정한다**(백엔드 문서 §2.2). 카탈로그가 `personal_best`
카테고리에 `season_weekly_rank_lte` 를 달아 두면 **등수 `3` 이 `0:03` 으로 카드에 박힌다** —
"인스타에 올린 기록이 앱 화면과 다르다"를 막으려고 폴백을 지우는 라운드에서 같은 사고를
카테고리 오분류로 다시 여는 셈이다. 카테고리는 **어떤 카드를 그릴지**, 조건 타입은
**그 숫자를 어떻게 읽을지**를 정하므로 둘을 각각 본다.

`0 이하·비유한 값` 방어는 삭제한 폴백의 `run.movingSeconds > 0` 검사를 옮겨 온 것이다.
`0:00` 을 자랑하게 두지 않는다.

### 3. 동작 변화

| 상황 | 이전 | 이후 |
|---|---|---|
| 5km PB, 세션 5.02km, `achieved_value = 1470.6` | `24:31`(= movingSeconds) | **`24:31`**(= 서버 확정값) |
| 5km PB, 세션 7.2km(102% 초과), `achieved_value = 1471.2` | **null** — 보간값을 알 수 없었다 | **`24:31`** |
| 5km PB, `achieved_value = null`(65 이전 지급분) | `24:31`(movingSeconds 폴백) | **null** — 시간 칸이 빠진다 |
| `source_run` 이 없는 PB 뱃지 | null | `achieved_value` 있으면 **시간이 나온다** |

⚠️ **마이그레이션 65 적용 전에는 모든 PB 카드에서 시간이 빠진다.** 개발 DB 의 기존 PB 뱃지
38행이 전부 `null` 이기 때문이고(백필하지 않기로 확정 — 백엔드 §2.4), **버그가 아니다.**
실사용자 데이터가 아니므로 시드 재생성으로 해소한다. 65 적용 후 새로 지급되는 PB 부터
시간이 다시 나온다.

`runDistanceMeters`("이 러닝" 칸)와 경로 그림은 여전히 `sourceRun` 에서 온다 — 그쪽은 서버
확정값이 아니라 러닝 자체의 사실이라 폴백 대상이 아니었다.

### 4. 문서 동기화

- `share_card_data.dart` 라이브러리 주석의 "단 하나의 스키마 요청 (P1, backend-engineer)" →
  **해소됨**으로 교체
- `PersonalBestCardData.certifiedSeconds` doc — 102% 폴백 설명을 지우고 "출처는 서버 확정값
  하나뿐 / 여전히 null 일 수 있는 두 경우"로 재작성
- `share_card_body.dart` `_pbStats` 의 ⚠️ 주석 — null 사유를 "보간값 미저장"에서
  "65 이전 지급분"으로 갱신

---

## #31 — 스냅샷 `rank` nullable

### 1. 조사 결과 — **바꿀 모델이 없었다**

```
grep -rn "snapshot|SeasonSnapshot|snapshotRank" lib   → 러닝 세션 집계기의 snapshot() 뿐
grep -rn "season_leaderboard_snapshots" lib           → 0건
```

`season_leaderboard_snapshots` 를 읽는 Dart 코드는 **하나도 없다.** `SeasonHistory` 는
`season_histories`(다른 테이블)이고 `rank` 필드 자체가 없다. `RankingEntry.rank`(non-null)는
`leaderboard_entries`(주간)라 마이그레이션 66의 영향 밖이다. 즉 **`rank` 를 non-null 로 강제하던
곳도 없었다.**

### 2. 그래서 모델을 신설했다 — `SeasonLeaderboardSnapshot`

`lib/models/season_leaderboard_snapshot.dart` (+ `models.dart` 배럴 export)

"바꿀 것이 없다"로 끝내면 마이그레이션 66이 확정한 계약이 **문서에만** 남고, RK-10 화면을
붙이는 라운드가 `rank` 의 nullable 여부를 다시 추측하게 된다. 그 추측이 틀리면 무효 시즌
사용자 화면에서 파싱이 던진다. 모델은 그 계약을 컴파일러가 지키게 하는 가장 싼 방법이다.

컬럼은 마이그레이션 58 DDL + 60(`is_voided`) + 66(`rank` nullable)을 그대로 옮겼다.

| Dart | wire | 비고 |
|---|---|---|
| `userId` / `seasonId` | 동일 | **대리 키 없음** — PK 가 `(season_id, user_id)` 라 `id` 컬럼을 만들지 않았다 |
| `tier` | `tier` | 랭킹은 같은 티어 안에서만 매겨진다(PRD §5.4) |
| **`int? rank`** | `rank` | **null ⇔ `is_voided`** (66의 CHECK). doc 에 SQL 그대로 인용 |
| `participantCount` | `participant_count` | **유효 참가자 수**(무효 제외). 무효 행에도 같은 값 |
| `seasonDistanceMeters` | `season_distance_meters` | 이름이 다르므로 주의 |
| `runCount` / `movingSeconds` / `reachedAt` | 동일 | PRD §8.2 타이브레이크 키이기도 하다 |
| `computedAt` | `computed_at` | `created_at` 아님 |

파생값 둘만 얹었다.

- `hasRank` — `rank != null` 과 같은 뜻이지만 호출부가 "무효라서 순위가 없다"는 인과를 읽게 한다
- `topPercent` — **순위가 없으면 null.** `RankingEntry.topPercent` 와 같은 올림 규칙(1위도 0% 가
  되지 않는다). 무효 행에서 `0%` 나 `1위` 로 새는 경로를 여기서 닫는다

### 3. 리포지토리·프로바이더·화면은 붙이지 않았다

RK-10(명예의 전당)이 이번 범위가 아니고, 지금 만들면 **호출자 없는 코드**가 된다
(백엔드 문서 §8이 같은 이유로 `_pb_best_seconds` 컷오프 변형을 만들지 않았다).
모델 + 회귀 테스트까지가 "계약을 못 박는다"의 최소 단위다.

**RK-10 담당자에게 남기는 것:** `rank == null` 은 "무효 처리된 시즌"이며 **0위·미참여와
구분해서 표기해야 한다.** 모델 doc 에 ⚠️ 로 적어 뒀다.

---

## 검증

| 항목 | 결과 |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter test` | **348건 전부 통과** (이전 334건 → +14) |
| `dart run build_runner build` | `badge.g.dart` 에 `achieved_value` 매핑, `season_leaderboard_snapshot.{freezed,g}.dart` 생성 |
| 마이그레이션 SQL | **미수정** |

### 추가한 회귀 테스트

**`test/models/trd14_cleanup_wire_contract_test.dart` (신규, 10건)** — 파싱 규약 고정.
서버가 보내기 시작한 뒤 런타임에서만 터지는 부류라 여기서 먼저 잡는다.

- `achieved_value` 소수(`1470.6`) → `double` / 정수(`4`) → `4.0` 승격
- 키 누락과 명시적 `null` 이 **둘 다** null
- `toJson()` 이 snake_case 로 되돌아간다
- 스냅샷 유효 행 파싱(전 컬럼 + `reached_at`/`computed_at` 시각)
- **무효 행(`rank: null, is_voided: true`) 파싱이 던지지 않는다**
- 무효 행의 `participant_count` 는 유효 참가자 수 그대로
- `topPercent` — 순위 없으면 null / 1위 → 1% / 꼴찌 → 100% / 참가자 0이면 null(0 나누기 방어)
- 무효 행 JSON 왕복 동일성

**`test/sharing/share_card_builder_test.dart` (개편, PB 그룹 +4)**

- 서버 확정값 반올림(`1470.6` → `1471`)
- `pb_first_achieved` 도 같은 경로
- **`achieved_value == null` 이면 비운다 — 폴백 회귀 가드.** 세션 5.02km / `movingSeconds 1500`
  을 함께 넘긴다: 예전 규칙(≤102%)이라면 `1500` 이 나왔을 입력이다
- **102% 초과 러닝이어도 확정값이 있으면 쓴다** — 예전에 null 이던 구간이 채워진다
- 단위가 초가 아닌 조건 타입(`season_weekly_rank_lte`)은 읽지 않는다
- `0` · 음수 · `NaN` · `Infinity` 를 전부 비운다

---

## 남는 것 / 이번 범위 아님

- **마이그레이션 65·66 원격 적용** — 백엔드 문서 §4 절차. 적용 전까지 PB 카드에 시간이 없다
- **RK-10 명예의 전당 UI** — `SeasonLeaderboardSnapshot` 의 리포지토리·프로바이더·화면.
  `rank == null` 분기 필수
- **`achieved_value` 를 쓰는 다른 화면** — 뱃지 갤러리/상세가 "획득 당시 기록"을 보여 줄 수
  있게 됐지만, 단위가 조건 타입별로 다르므로 포맷터를 먼저 설계해야 한다.
  `certifiedPbSeconds` 의 화이트리스트 방식이 그 포맷터의 원형이다
