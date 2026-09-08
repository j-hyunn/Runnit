# QA 통합 경계 검증 — TRD §14 소규모 정리 5건 (#17 · #18 · #21 · #31 · #33)

| 항목 | 내용 |
|------|------|
| 일자 | 2026-09-08 |
| 담당 | qa-integration-tester |
| 대상 | 미커밋 워킹트리 변경 전체 (Dart 8파일 + 마이그레이션 65·66 신규 + 테스트 3파일 + `docs/TRD.md`) |
| 근거 | `docs/PRD.md` §5.5·§8.1/§8.2/§8.4, `docs/TRD.md` §3.9.1·§4.1·§10.2·§14, `_workspace/20260908_backend_trd14-cleanup.md`, `_workspace/20260908_ui_trd14-cleanup.md` |
| 방법 | 정적 양측 대조(마이그레이션 SQL ↔ Dart 모델/생성물, 41·42·57·58·60·61·63 ↔ 65·66) + `flutter analyze` / `flutter test` 재실행 |
| 결론 | **PASS 18 · CONFIRMED 4(전부 문서 정합, 코드 결함 0) · PLAUSIBLE 3 · 검증 불가 2(원격 미적용)** |

> ⚠️ **마이그레이션 65·66은 원격에 적용되지 않았고, 이 환경에는 로컬 Postgres 가 없다.**
> 아래 SQL 판정은 전부 **정적 판독**이다. §7 "적용 전 브랜치 검증 필수" 항목을 반드시 먼저 수행할 것.

---

## 0. 검증 재실행 결과

```
dart run build_runner build --delete-conflicting-outputs  → wrote 4 outputs
flutter analyze                                           → No issues found! (2.5s)
flutter test                                              → All tests passed!  348건
```

산출 문서가 주장한 348건과 일치한다(#17·#21 12건 + #18·#31 14건, 기존 322건).
`test/models/trd14_cleanup_wire_contract_test.dart`(신규 10건)·`share_card_builder_test.dart`(PB 그룹 개편) 단독 실행도 통과.

---

## 1. 모델 ↔ 스키마 경계 (PASS)

### 1.1 `user_badges.achieved_value` ↔ `UserBadge.achievedValue` — **PASS**

| 축 | 서버 (65-1) | 클라이언트 | 판정 |
|---|---|---|---|
| wire 키 | `achieved_value` | `badge.g.dart:71` `json['achieved_value']` | ✅ `@JsonSerializable(fieldRename: FieldRename.snake)` 가 `achievedValue → achieved_value` 로 정확히 변환 |
| 타입 | `numeric null` | `(json['achieved_value'] as num?)?.toDouble()` → `double?` | ✅ PostgREST 가 정수로 내려도(주 수·등수) `num → double` 승격. `int` 로 받았다면 PB 보간 소수에서 던졌을 자리다 |
| 직렬화 | — | `badge.g.dart:86` `'achieved_value': instance.achievedValue` | ✅ 왕복 대칭 |
| 조회 | — | `supabase_gamification_repository.dart:55`·`:79` `select('*, badge:badges(*)')` | ✅ `*` 라 새 컬럼이 자동 포함. **변경 불필요가 맞다** |

`user_badges` 를 읽는 경로는 위 두 곳뿐임을 확인했다(`_userBadges` 상수 사용처 전수).

### 1.2 `season_leaderboard_snapshots` ↔ `SeasonLeaderboardSnapshot` — **PASS**

마이그레이션 58 DDL + 60(`is_voided`) + 66(`rank` nullable) 을 전 컬럼 대조했다.

| DDL | 타입 | Dart | 판정 |
|---|---|---|---|
| `season_id text not null` | text | `String seasonId` | ✅ |
| `user_id uuid not null` | uuid | `String userId` | ✅ |
| `tier public.tier not null` | enum | `Tier tier` (`@JsonValue('bronze'…'platinum')`) | ✅ enum 라벨 4종 일치 |
| `rank integer` **(66에서 not null 해제)** | int null | `int? rank` → `(json['rank'] as num?)?.toInt()` | ✅ |
| `participant_count integer not null` | int | `@Default(0) int participantCount` | ✅ |
| `season_distance_meters double precision not null` | double | `@Default(0) double seasonDistanceMeters` | ✅ 이름 불일치(`season_distance_meters`)를 필드명이 정확히 흡수 |
| `run_count` / `moving_seconds` | int | `int runCount` / `int movingSeconds` | ✅ |
| `reached_at timestamptz null` | ts | `DateTime? reachedAt` | ✅ |
| `is_voided boolean not null default false` | bool | `@Default(false) bool isVoided` | ✅ |
| `computed_at timestamptz not null default now()` | ts | `DateTime? computedAt` | ✅ (nullable 이 non-null 을 받는 방향이라 안전) |
| PK `(season_id, user_id)` | — | 대리 키 없음 | ✅ 올바른 판단 |

`topPercent` 의 `participantCount <= 0` 방어와 `ceil().clamp(1,100)` 규칙이 `RankingEntry.topPercent` 와 동일함을 확인했다 — 무효 행(`rank == null`)에서 `0%`·`1위` 로 새는 경로 없음.

---

## 2. 마이그레이션 65 SQL 정합성

### 2.1 `evaluate_badge_condition` 회귀 없음 — **PASS (CONFIRMED 동치)**

41(정본) 의 `case` 블록과 65 의 `case` 블록을 **기계 diff** 했다. 실질 차이는 아래 4종뿐이다.

| # | 차이 | 판정 |
|---|---|---|
| 1 | 주석 삭제 다수 | 무해 |
| 2 | `session_distance_gte` · `season_first_long_distance` 의 거리식이 `* 1000.0` / `* 0.98` → `- least(D*1000*0.02, 300.0)` | ✅ **마이그레이션 42 그대로**. 41 대비 diff 가 뜨는 것이 정상이며 42 파일과 문자열 일치 확인 |
| 3 | `season_weekly_rank_lte` · `season_streak_weeks_gte` · `season_weekly_rank_rising_streak_gte` 3분기가 헬퍼 호출로 치환 | ✅ 아래 2.2 |
| 4 | `v_season` 선언이 `season_id_at(now())` → `_badge_eval_season()` | ✅ 61-3 치환본과 동치(`coalesce(nullif(current_setting('runnit.badge_season', true), ''), season_id_at(now()))`) |

**분기 목록 38종이 41과 완전히 동일**하다(추가·삭제·순서 변경 0). 죽은 변수 `v_season_walk`·`v_participated`·`v_seasons_ok`·`v_i` 제거는 어느 분기에서도 참조되지 않음을 확인했다.

### 2.2 헬퍼 분해가 57-5 시맨틱을 유지하는가 — **PASS**

- `_season_weekly_rank_badge_rank`: 41의 `exists(...)` 술어를 `select min(le.rank)` 로 바꾸고 **`and le.finalized_at is not null` 을 그대로 포함**(65 파일 148행). bucket 3종 문턱(`top1` N≥10 & rank=1 / `top10` N≥20 & rank≤10 / `top10pct` N≥20 & rank ≤ ceil(N*0.10))이 41과 문자 단위로 동일.
- bucket 도메인 검증 위치가 디스패처 → 헬퍼로 이동했으나 **결과는 동치**: 알 수 없는 bucket → `raise notice` + `return null` → 디스패처 `is not null` → `false`. 41은 곧바로 `false`.
- 기간 경계: 41은 `declare` 에서 계산한 `v_season_start/_end`, 65는 헬퍼가 `season_start(p_season)`/`season_end(p_season)` 를 재계산. `p_season = v_season` 이므로 동일값.
- `tier` 키 누락 시: 양쪽 모두 `le.tier = null` → 무행 → false. 동치.
- `_season_streak_weeks` · `_season_weekly_rank_rising_streak`: 41의 인라인 CTE를 **문자 단위 그대로** 옮기고 `>= v_weeks` 비교만 호출부에 남겼다. `coalesce(..., 0) >= v_count` 로 감싼 것도 41의 `coalesce(max(...), 0) >= v_count` 와 동치.

### 2.3 `badge_achieved_value` 의 조건 타입별 값 — **PASS**

| condition_type | 반환 | 검증 |
|---|---|---|
| `pb_time_lte` · `pb_first_achieved` | `_pb_best_seconds(user, distanceKm)::numeric` = **초** | ✅ 판정(`pb_time_lte`)이 같은 함수를 쓴다. `distanceKm` null 방어 있음 |
| `streak_weeks_gte` | `profiles.longest_streak_weeks` = **주 수** | ✅ 판정도 같은 컬럼(65 파일 614행) |
| `season_streak_weeks_gte` | `_season_streak_weeks(user, season)` = **주 수** | ✅ **판정과 동일 함수** |
| `season_weekly_rank_lte` | `_season_weekly_rank_badge_rank(...)` = **등수** | ✅ **판정과 동일 함수**. 두 경로가 갈라질 수 없다 |
| `season_weekly_rank_rising_streak_gte` | `_season_weekly_rank_rising_streak(...)` = **연속 상승 주 수** | ✅ 동일 함수 |
| 나머지 33종 | `null`(notice 없음) | ✅ |

`_badge_eval_season()` 를 값 디스패처도 `declare` 에서 부르므로 판정과 **같은 시즌**을 본다. 호출 지점이 `evaluate_badges` 지급 루프 내부·같은 GUC 아래(65 파일 986행)라는 것도 확인했다.

### 2.4 63번 회귀 가드 폐지의 안전성 — **PASS**

- 63은 단일 `do $$` 블록 51줄이고 DDL 을 만들지 않는다. 신규 환경 replay 에서 63은 **65보다 앞 순서**에 실행되며, 그 시점의 라이브 정의는 57-5/61-3 치환본이라 두 문자열 검사를 통과한다.
- 65-8 대체 가드는 (a) 두 헬퍼 실재, (b) 디스패처가 둘을 호출, (c) 헬퍼 안의 `finalized_at` 필터 존재 — **호출 관계 + 최소 술어**를 본다. 헬퍼 내부 SQL 변경에 오탐하지 않으면서 #23/#30 재발은 여전히 막는다. 설계 의도대로다.
- `to_regprocedure(...)::oid` 캐스트가 null 일 때는 그 앞 두 검사가 이미 예외를 던지므로 도달 불가.

### 2.5 권한 — **PASS**

신규 6함수 전부 `revoke execute ... from public, anon, authenticated` 가 붙어 있다(`_badge_eval_season`, `_season_weekly_rank_badge_rank`, `_season_streak_weeks`, `_season_weekly_rank_rising_streak`, `badge_achieved_value`, `_rerank_season_snapshot`). `evaluate_badge_condition`·`evaluate_badges`·`snapshot_season_leaderboard`·`set_season_history_voided` 재정의분에도 revoke 를 다시 걸었다 — `create or replace` 는 기존 ACL 을 유지하지만 명시가 안전한 쪽이다.

**클라이언트가 `rpc(` 로 부르는 함수는 `lib/` 전체에 0건**이므로 revoke 로 깨질 앱 경로 없음.

---

## 3. 마이그레이션 66 SQL

### 3.1 window + `update … from cte` — **PASS(정적) / 문법 실행 미검증**

- `sum(case when is_voided then 0 else 1 end) over (partition … order … rows between unbounded preceding and current row)` — 무효 행을 건너뛰며 세는 누적 카운트라 **유효 행 1..N 연속**이 보장된다. `rank() over` 를 그대로 썼다면 무효 행이 자리를 차지해 구멍이 남았을 것이고, 그 선택이 정확하다.
- `count(*) filter (where not is_voided) over (partition by …)` — ORDER BY 없는 윈도우라 기본 프레임이 파티션 전체. 유효 참가자 수로 올바르다.
- window 호출이 `case` 식 내부에 중첩된 형태는 Postgres 에서 합법.
- `update … from valid_ranked v where t.season_id = v.season_id and t.user_id = v.user_id` — PK 조인이라 행당 1회 매칭. 자기 테이블을 CTE 로 읽고 갱신하는 형태는 합법이며 CTE 스냅샷을 읽으므로 갱신 중 재읽기 문제 없음.
- **정렬 키가 58·60의 적재 정렬과 완전히 동일**함을 diff 로 확인: 거리 desc → 횟수 asc → `reached_at` asc → 이동시간 asc → `user_id` asc. PRD §8.2(① 적은 횟수 → ② 먼저 도달 → ③ 짧은 총시간)와도 일치.
- 58의 `rank()` → 66의 누적 카운트(= `row_number()` 시맨틱) 변경은 **`user_id` 까지 내려가는 전순서**라 동치다(PK 로 중복 불가).

### 3.2 `is_voided ⇔ rank is null` CHECK — **PASS**

- 66-1 순서가 옳다: `drop not null` → 기존 무효 행 `rank = null` 백필 → `drop constraint if exists` → `add constraint`. 기존 유효 행은 NOT NULL 이었으므로 CHECK 위반 불가.
- 66-2 의 UPDATE 는 `new_rank` 가 `is_voided` 일 때만 null 이고 `is_voided` 를 건드리지 않으므로 **항상 CHECK 를 만족**한다.
- 66-4 무효화 방향은 `is_voided=true, rank=null` 을 **같은 UPDATE 에서** 세팅 → 위반 없음.
- 66-4 복구 방향의 `rank = 1` 자리표시자는 CHECK 를 통과시키기 위한 것이고 직후 `_rerank_season_snapshot` 이 확정한다. `idx_season_snapshots_season_tier_rank` 는 **UNIQUE 가 아니므로**(58 파일 75행) 일시적 rank 중복도 제약 위반이 아니다. ✅ 이 부분을 별도 확인했다.

### 3.3 RLS 상호작용 — **PASS**

- `season_leaderboard_snapshots` 에 `force row level security` 가 걸린 마이그레이션은 **전체 검색 결과 0건**이다. `_rerank_season_snapshot`·`set_season_history_voided`·`snapshot_season_leaderboard` 는 전부 `security definer`(소유자 = 테이블 소유자)라 RLS 를 우회한다. UPDATE 정책이 없어도 갱신이 막히지 않는다.
- 60의 SELECT 정책(`is_voided = false or user_id = auth.uid()`)은 **손대지 않았다**. "숨김은 숨김만, 순위 정합은 저장값이" 라는 분리가 유지된다.
- 후보 A(읽기 시점 뷰 재랭크) 기각 근거가 정확하다 — 뷰는 기반 테이블 RLS 를 받아 사람마다 다른 등수를 낸다(58 C-1 과 동형).

### 3.4 60 → 66 함수 diff — **PASS (회귀 없음)**

`snapshot_season_leaderboard` 를 60판과 기계 diff 한 결과, 변경은 (a) `ranked` CTE 의 rnk/pc 산출 2줄, (b) 말미 `if v_count > 0 then perform _rerank_season_snapshot` 뿐이다. `base`·`tiered` CTE(3단 티어 폴백, `dist_m > 0`, `profiles` 존재 확인, `indoor_run` 제외)와 `on conflict do nothing` 멱등 규약은 그대로다.

TRD §6.4 가 말하는 "`if not exists (…)` 가드"는 `snapshot_season_leaderboard` 가 아니라 **`recompute_season_tier` 안**에 있고(58 파일 263행), 66은 그 함수를 건드리지 않았다 — 가드 유실 없음.

---

## 4. #17 클라이언트 ↔ 서버 허용오차 일치 — **PASS**

### 4.1 42번 SQL의 거울인가

`badge_condition.dart:219` `effectiveDistanceTargetKm` 은
`(D*1000 - min(D*1000*0.02, 300.0)) / 1000` 을 계산한다. 65 파일에 실린 정본 SQL 3분기와 대조:

| condition_type | 65 정본 SQL | 클라이언트 | 판정 |
|---|---|---|---|
| `session_distance_gte` (378행) | `>= D*1000.0 - least(D*1000.0*0.02, 300.0)` | 포함 | ✅ |
| `pb_first_achieved` (602행) | 동일 | 포함 | ✅ |
| `season_first_long_distance` (789행) | 동일 | 포함 | ✅ |
| `cumulative_distance_gte` (362행) | `>= v_distance_km * 1000.0` **(정확 비교)** | **제외** | ✅ **제외가 맞다.** 여기서만 완화하면 클라이언트가 서버보다 먼저 100%를 그린다 |

경계값 재계산: 10km → 9.8km(2%), 5km → 4.9km, 21.0975km → 20.7975km(300m 상한), 42.195km → 41.895km(상한). 산출 문서의 표와 일치.

### 4.2 `ratio` 와 `meetsThresholdLocally` 가 같은 목표를 공유하는가 — **PASS**

`badge_progress.dart:113` 에서 `effectiveTargetOf` 를 **한 번만** 계산해 `meets`(118행)와 `ratioFor`(131행)에 같은 `target` 을 넘긴다. "바는 100%인데 '곧 지급됩니다'는 안 뜬다"는 어긋남이 구조적으로 불가능하다. `targetOf` 를 직접 부르는 곳은 `effectiveTargetOf` 내부뿐임을 확인했다.

방어 로직(`condition['distanceKm'] is! num` 이면 완화하지 않음, 169행)도 방향이 옳다 — 서버보다 느슨해지는 쪽을 막는다.

### 4.3 실제 영향 범위 (정보)

허용오차 3종 중 진행률 바에 **현재 실제로 반영되는 것은 `session_distance_gte` 뿐**이다:
`pb_first_achieved` 는 `clientEstimable` 이나 `GamificationStats` 가 지표를 수집하지 않아 `currentValueFor` 가 null,
`season_first_long_distance` 는 `clientPartial` 이라 애초에 null. 결함이 아니라 미수집 지표의 결과이며 산출 문서 §6이 이미 후속으로 명시했다.

---

## 5. #21 티어 엠블럼 경로 통합 — **PASS**

- 정본 위임 결과: `badgeCategoryAssetFolder(BadgeCategory.seasonTier)` → `'tier'`, `badgeGradeAssetName('bronze'|'silver'|'gold'|'platinum')` → 폴백 미발동(4종 모두 화이트리스트 안).
  → 출력 `assets/badges/tier/{bronze|silver|gold|platinum}.svg`. **삭제된 사본 `'assets/badges/tier/${tier.name}.svg'` 와 4개 티어 전부 문자 단위 동일.**
- 실물 자산 확인: `assets/badges/tier/` 에 bronze·silver·gold·platinum(+diamond·special) svg 전부 존재.
- 호출부 2곳(`share_card_body.dart:367` `_EmblemArt`, `:685` `shareCardEmblemAsset`)이 정본을 import 한다. `share_card_builder.dart` 는 원래부터 `badgeAssetPath` 사용.
- `grep -rn "assets/badges/" lib` 결과, **경로 문자열을 조립하는 코드는 `badge_assets.dart` 한 곳뿐**이다(나머지는 주석). 이원화 해소 확인.

---

## 6. 발견 사항

### CONFIRMED-1 — `docs/TRD.md` §4.1 매핑표가 이번 라운드를 반영하지 않았다 (문서, 코드 결함 아님)

`docs/TRD.md:1041-1045`:

- `| RankingEntry.rank | season_leaderboard_snapshots.rank | integer |` → 66에서 **`integer null`** 이 됐다. 같은 행의 비고 "별도 모델을 만들지 않고 재사용할 수 있게" 는 이번 라운드에 `SeasonLeaderboardSnapshot` 을 신설하면서 **사실과 달라졌다**.
- `| *(대응 필드 없음)* | …reached_at / run_count / moving_seconds / computed_at |` → 네 컬럼 모두 이제 Dart 필드가 있다.
- `season_leaderboard_snapshots.is_voided`(마이그레이션 60) 가 매핑표에 **처음부터 없었고** 지금도 없다.
- **`user_badges.achieved_value ↔ UserBadge.achievedValue` 행이 §4.1 에 없다.** `achieved_value` 는 §3.9.1·§14 #18 에만 등장한다. §4.1 이 camelCase↔snake_case 계약의 정본 표이므로 여기에 없으면 다음 라운드가 표만 보고 컬럼을 놓친다.

→ **조치**: mobile-architect + backend-engineer. §4.1 에 `achieved_value` 행 추가, 스냅샷 4행 갱신(+`is_voided` 행 신설).

### CONFIRMED-2 — TRD §4.3(1687행) 스냅샷 서술이 66 이전 상태다 (문서)

`season_leaderboard_snapshots(season_id, user_id, tier, rank, …)` DDL 나열에 `is_voided` 가 빠져 있고, "무효 시즌은 is_voided 컬럼을 복사해 두고 SELECT 정책이 그 컬럼만 본다(마이그레이션 60)" 에서 멈춘다. 66의 **재랭크·rank nullable·participant_count 의미 변경**이 없다.

### CONFIRMED-3 — TRD §6.4(1260-1270행) 시즌 마감 절차에 66 반영 없음 (문서)

"`snapshot_season_leaderboard(지난_시즌)` → 티어별 시즌 누적 거리 랭킹을 영구 적재" 서술에 무효 사용자 제외가 언급되지 않는다. §6.4는 마감 배치의 정본 서술이므로 여기에 없으면 RK-10 담당이 `participant_count` 를 "전체 모집단"으로 읽는다(58의 옛 정의).

### CONFIRMED-4 — `achieved_value` 가 null 이 되는 세 번째 사유가 문서에 없다 (문서, 저심각)

TRD §3.9.1 / `badge.dart` doc / `share_card_data.dart` doc 이 열거하는 null 사유는 ① 65 이전 지급분 ② 값 시맨틱 없는 34종 두 가지뿐이다. 그런데 **`pb_first_achieved` 는 판정이 거리만 보는데(65 파일 597-603행) `_pb_best_seconds` 는 목표의 102% 초과 세션에서 GPS 보간이 실패하면 null 을 돌려준다**(41 파일 336-346행: `_run_time_at_distance` 실패 · `secs > 0` 필터).
→ **지급됐는데 `achieved_value` 가 null 인 `pb_first_achieved` 뱃지가 65 적용 후에도 정상적으로 발생한다.** 동작은 올바르나(카드가 시간 없이 "5km PB 갱신"만 말함) 문서가 이를 "65 이전 지급분"으로만 설명하면 나중에 버그로 오인된다.
(`pb_time_lte` 는 판정 자체가 `_pb_best_seconds is not null` 을 요구하므로 이 경우가 없다.)

### PLAUSIBLE-1 — PB 공유 카드가 서로 다른 러닝의 값을 섞을 수 있다

`_pbCard` 는 `runDistanceMeters` 를 **`sourceRun`** 에서, `certifiedSeconds` 를 **`achieved_value`(= 판정 시점 `_pb_best_seconds`, 전체 러닝 중 최고)** 에서 가져온다.
평상시에는 같은 러닝이지만, **카탈로그에 `pb_time_lte` 뱃지가 새로 추가되어 과거 기록으로 소급 지급되는 경우** `source_run_id` 는 "판정을 촉발한 오늘의 러닝", `achieved_value` 는 "2주 전 러닝의 기록"이 된다. 카드에 "7.2km 러닝에서 5km PB 24:31" 이 뜨는데 24:31 은 그 7.2km 러닝의 기록이 아니다.
이전 규칙(`run.movingSeconds`)에서는 두 값이 항상 같은 러닝이었으므로 **이번 변경이 새로 연 창**이다.
빈도가 낮고(신규 뱃지 추가 시점) PB 자체는 사실이므로 P2. 대응 선택지: (a) 카드 문구를 "이 러닝" 대신 중립 표현으로, (b) `achieved_value` 산출을 `source_run` 한정으로, (c) 그대로 두고 알려진 한계로 등재.
→ **gamification-designer + flutter-ui-designer 판단 필요.**

### PLAUSIBLE-2 — `set_season_history_voided` 반환값이 "아무 일도 없었다"로 오독될 수 있다

반환값은 `season_histories` 갱신 행 수(`v_n`) 하나다. 두 테이블이 이미 갈라져 있는 상태(`season_histories.is_voided = true`, 스냅샷은 `false`)에서 `p_voided => true` 로 부르면 `v_n = 0` 을 돌려주지만 스냅샷 갱신 + 시즌 전체 재랭크는 **실제로 수행된다**. 운영 스크립트가 반환값으로 성공 여부를 판단하면 오판한다.
저심각(정합 복구 자체는 올바르게 동작). 함수 코멘트에 한 줄 명시 권장.

### PLAUSIBLE-3 — `_season_weekly_rank_rising_streak` 의 "현재 티어만" 한계가 이제 확정값에도 전이된다

27/41 의 원 로직(`le.tier = profiles.current_tier`)을 그대로 옮겼으므로 판정 회귀는 없다. 다만 65부터는 이 값이 `achieved_value` 로 **영구 저장**되므로, 시즌 중 승급한 사용자의 "연속 상승 주 수"가 과소 기록된 채 박제된다. 65가 로직 변경 없는 마이그레이션이라는 전제는 옳고 이번에 고칠 일은 아니지만, **`achieved_value` 를 UI 에 노출하기 전에** 별도 항목으로 등재하는 것이 맞다(백엔드 문서 §8도 같은 취지).

---

## 7. 검증 불가 — 적용 전 브랜치 검증 **필수** 항목

> 로컬 Postgres 부재(psql/docker 미설치) + 원격 미적용. 아래는 **정적으로는 통과했으나 실행으로 확인되지 않은** 것들이며, 프로덕션 전에 **반드시 Supabase 브랜치에서 먼저 적용**해야 한다.

| # | 항목 | 왜 실행 확인이 필요한가 | 확인 방법 |
|---|---|---|---|
| U-1 | **66-2 `update … from cte` + window 조합의 문법·플랜** | 이 라운드에서 유일하게 전례가 없는 구문이다. `case` 안의 window, `filter` 있는 window, 자기 테이블 CTE 가 한 문장에 모인다 | 브랜치 적용 후 스냅샷 시드 3~5행(1행은 무효)을 넣고 `_rerank_season_snapshot` 실행 → `max(rank) = max(participant_count)` 이고 티어별 1..N 이 끊기지 않는지 |
| U-2 | **65 판정 동치의 실측** | 정적 diff 로는 "본문이 같다"까지만 말할 수 있다. `_badge_eval_season()` 가 STABLE + SECURITY DEFINER 로 분리된 뒤에도 GUC 를 매 호출 새로 읽는지는 실행으로만 확정된다 | 65 **적용 전** 대표 사용자 × 조건 타입 6종(특히 `season_weekly_rank_lte`·`season_streak_weeks_gte`)의 `evaluate_badge_condition` 결과를 표로 떠 두고, 적용 후 **같은 입력으로 재실행해 전건 일치** 확인 |
| U-3 | 65-8 가드 블록 | 통과하면 두 술어가 살아 있다는 뜻. 실패하면 그 자리에서 롤백 | `apply_migration` 출력 확인 |
| U-4 | `evaluate_badges` 지급 시 `achieved_value` 채움 | 3-pass 루프 + GUC + 트리거 체인이 얽힌 자리다 | 러닝 1건 업로드(또는 기존 러닝 `updated_at` 터치) → 새 `user_badges` 행에 값이 들어가는지. **기존 199행이 null 로 남는 것이 정상** |
| U-5 | `get_advisors(security)` / `(performance)` | 신규 SECURITY DEFINER 6종. Postgres 가 새 함수에 PUBLIC EXECUTE 를 기본 부여하므로 revoke 누락 시 WARN 이 늘어난다 | baseline 6건에서 **늘지 않았음** 확인 |
| U-6 | 66-4 복구 경로(`p_voided => false`) | `rank = 1` 자리표시자 → 재랭크 확정의 2단계가 한 트랜잭션에서 도는지 | 무효화 → 해제 왕복 후 CHECK 위반 없이 1..N 이 복구되는지 |

**롤백 주의(백엔드 문서 §4 재확인)**: 65 이전 `evaluate_badge_condition` 정의는 앵커 치환의 산물이라 **되돌아갈 파일이 없다.** 브랜치 선적용이 사실상 유일한 안전망이다.

---

## 8. 요약

| 구분 | 건수 | 내용 |
|---|---|---|
| **PASS** | 18 | 모델↔스키마 2축, 65 판정 동치·헬퍼 분해·확정값 6종·권한·63 폐지, 66 window/CHECK/RLS/60-diff, #17 거울·목표 공유, #21 4티어 경로, analyze/test |
| **CONFIRMED** | 4 | **전부 문서 정합 — 코드·SQL 결함 0건.** TRD §4.1 매핑표(achieved_value 누락 + 스냅샷 4행 stale) / §4.3 / §6.4 / null 사유 3번째 |
| **PLAUSIBLE** | 3 | PB 카드 값 혼합, `set_season_history_voided` 반환값 오독, rising_streak 한계의 영구 저장 전이 |
| **검증 불가** | 6 (U-1~U-6) | 마이그레이션 65·66 미적용 — **브랜치 선적용 필수** |

**이번 라운드의 코드·SQL 자체에서 발견된 결함은 0건이다.** 5개 항목 모두 목표를 달성했고, 특히 #33의 "판정과 확정값이 같은 헬퍼를 부르게 한다"는 설계는 #18을 추가하면서 새로운 이원화를 만들지 않은 정확한 선택이다. 남은 것은 문서 4건과 원격 적용 검증이다.
