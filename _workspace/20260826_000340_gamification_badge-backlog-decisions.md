> ## ⚠️ §4 부분 폐기 (2026-08-26) — `_workspace/20260826_012000_architect_device-vendor-arbitration.md` 참조
>
> **§4의 스칼라 컬럼 전제는 폐기됐다.** `runs.device_source`(세션당 단일 값)와 토큰 7종
> (`watchWearOS`/`external`/`manual` 포함)은 만들지 않는다. mobile-architect 중재 결과
> 정본은 러닝 단위 **배열** `runs.device_vendors public.device_vendor[]` + 토큰 **5종**
> (`phone`/`watchApple`/`watchGarmin`/`watchOther`/`unknown`)이다. 폰 GPS + 워치 심박
> 하이브리드 세션을 스칼라로 접으면 `device_both_used`와 애플워치 뱃지 3종이 구조적으로
> 미지급되는 것이 결정 사유다(중재 문서 §1.1).
>
> **§4에서 채택된 부분**: `_or_` OR 표현식 문법(§4.2), 판정 대상 세션 규칙
> `completed AND NOT is_flagged`, 원소 간 AND / 원소 내부 OR 구조. 배열에서는 OR가
> 배열 겹침 `&&`으로 그대로 떨어진다. **§4.3의 "각 원소는 서로 다른 세션으로 충족"
> 규칙과 §4.4의 `default 'phone'` 백필은 폐기**됐다(정본: 제약 없음 / `default '{}'`).
>
> **§1~3, §5 이후의 다른 결정(XP·레벨, 스트릭 유예, `bucket` 도메인, 음력 룩업 등)은
> 그대로 유효하다.** 이 폐기 표시는 §4에만 적용된다.

# 뱃지 백로그 설계 결정 확정본 (7개 항목)

작성: gamification-designer / 2026-08-26
기준 문서: `docs/PRD.md` §5.3/§5.4/§5.5/§8 · `docs/TRD.md` §9/§10 · `docs/badge-catalog.csv` ·
`_workspace/20260825_193000_backend_badge-evaluation-logic.md` §4/§6/§8 ·
`_workspace/20260825_181914_backend_badge-v2-migration.md` §7.1/§7.2 ·
`_workspace/20260825_architect_badge-model-v2.md` §4/§7

> **이 문서의 성격**: 결정문이다. 아래 수치·이름·규칙은 backend-engineer가 그대로 마이그레이션으로
> 옮길 수 있는 확정값이며, 이견이 있으면 구현 전에 제기해야 한다. SQL은 작성하지 않았다.
>
> **일관 원칙 (7개 항목 전부에 적용)**
> 1. 모든 판정은 **순수 함수**다 — 입력(러닝 이력 + 프로필 + 카탈로그)만으로 결정되고,
>    누적 상태를 저장하지 않는다. 기록이 삭제돼도 재계산으로 같은 답이 나와야 한다.
> 2. **클라이언트 판정은 표시용 추정치**다. `UserBadge` 행을 만드는 것은 오직 서버다.
> 3. **이미 지급된 뱃지는 이 문서의 규칙 변경으로 회수하지 않는다** (PRD §8.1 — 부정 판정만 회수).
>    `evaluate_badges`는 INSERT 전용이므로 임계값을 조여도 소급 회수가 발생하지 않는다.
>    backend는 이 규칙을 깨는 DELETE/revoke 경로를 추가하지 말 것.

---

## 요약 — 7개 항목 결정 한 줄씩

| # | 항목 | 결정 |
|---|------|------|
| 1 | `level_gte` (9종) | XP 4원천 합산 + `XP(L)=ceil(50×(L−1)^2.2)`, **만렙 60**. `profiles.total_xp`/`profiles.level` 저장 컬럼. `total_points`는 Phase 4 포인트 이코노미 전용으로 반납 |
| 2 | `season_weekly_rank_lte` `bucket` | `top1` / `top10` / `top10pct` **3종으로 확정**. 최소 모집단(top1 N≥10, 나머지 N≥20) 조건 추가 |
| 3 | `streak_weeks_gte` | 주 = KST 월~일, 활동 주 = 완주 1건 + 주간 합산 ≥1.0km. 유예 크레딧 1개 자동 소모, 4주 연속 활동 시 회복. **크레딧은 저장 상태가 아니라 리플레이 파생값** |
| 4 | device source 토큰 | 7토큰 lowerCamelCase (`phone`/`watchApple`/`watchGarmin`/`watchWearOS`/`watchOther`/`external`/`manual`), OR 구분자 `_or_`, 배열 원소 간 AND |
| 5 | §6 가정값 | PB 허용 부족분 `min(목표×2%, 300m)` + 초과분은 스플릿 보간(상한 115% 폐기) / 루프 150m·2.0km / 경로 클러스터 반경 300m 그리디 |
| 6 | 음력 | **고정 룩업 테이블 채택**. 2026~2040 설날·추석 양력 날짜 15년치 제공(한국천문연구원 기준) |
| 7 | `district_diversity_gte` 삭제 | **부수 영향 없음**. 대상 `route_district_3`/`route_district_10` 2종. 경로탐험 카테고리는 7종 남아 존치 |

---

## 1. `level_gte` — GM-04 XP / 레벨 공식 확정

### 1.0 먼저 정리할 이름 충돌 — `points`는 XP가 아니다

현재 DB에는 `profiles.total_points` / `runs.awarded_points` / `compute_awarded_points()` /
`compute_level(p_total_points)`가 이미 있고, 클라이언트에도
`AppUser.totalPoints` / `LevelCurve`(계수 500, 지수 1.6, 상한 100)가 있다.

**그런데 PRD §5.6은 "포인트"를 Phase 4의 상품 교환 화폐로 정의했고, 그 적립 기준은
"거리와 무관하게 설계한다"가 확정 원칙이다.** 지금의 `total_points`는 정확히 그 반대(거리 비례)이며
용도도 레벨 산정 하나뿐이다. 두 개념이 같은 이름을 쓰고 있어 Phase 4에서 반드시 충돌한다.

**결정: 레벨의 재화를 `XP`로 개명하고, `points`라는 이름을 Phase 4에 반납한다.**

| 현재 | 변경 후 | 비고 |
|---|---|---|
| `profiles.total_points` | **`profiles.total_xp`** | Phase 4에서 `total_points`를 새 의미로 재생성 |
| `runs.awarded_points` | **`runs.awarded_xp`** | |
| `compute_awarded_points(...)` | **`compute_run_xp(...)`** | 산식은 §1.2에서 확장 |
| `compute_level(p_total_points)` | **`compute_level(p_total_xp)`** | 산식은 §1.3에서 교체 |
| `AppUser.totalPoints` | **`AppUser.totalXp`** | `@Default(0) int totalXp` |
| `LevelCurve` 상수 | §1.3 값으로 교체 | |

`ranking_metric` enum에서 `points`는 이미 제거됐다(마이그레이션 16) — XP로 순위를 매기는 리더보드는
없다. XP는 **레벨 하나만** 결정한다.

### 1.1 XP의 4원천 — GM-04 "거리·꾸준함 기반"

GM-04 수용 기준이 "거리·**꾸준함** 기반"인데 현행 `compute_awarded_points`는 세션 단위(거리·페이스·고도)뿐이라
꾸준함 성분이 아예 없다. 4개 원천으로 확장한다.

```
total_xp(user) = XP_run + XP_streak + XP_badge + XP_tier
```

**4원천 모두 원본 데이터로부터 재계산 가능(멱등)** 하다. 이것이 원천 선정의 유일한 기준이었다 —
"이번에 +50 해줬다" 식의 증분 가산은 기록 삭제/플래그 처리 후 정합이 깨지므로 채택하지 않는다.

#### XP-1. 러닝 세션 XP (거리 축)

대상: `status='completed' AND NOT is_flagged AND distance_meters >= 500`

```
실외(activity_type <> 'indoor_run')  :
    xp = min( 20                                  -- 완주 보너스
            + floor(distance_m / 100)             -- 100m당 1
            + floor(floor(distance_m/100) * pace_mult)
            + min(floor(max(elev_gain_m,0) / 10), 100),
            1000 )

    pace_mult = 0.30  if pace <= 300 s/km   (5'00")
                0.20  if pace <= 360        (6'00")
                0.10  if pace <= 420        (7'00")
                0.00  otherwise 또는 distance < 2000m 또는 moving_seconds = 0

실내·수동(activity_type = 'indoor_run') :
    xp = min( 20 + floor(distance_m / 100), 300 )   -- 페이스·고도 보너스 없음, 세션 상한 300
```

- 실외 산식은 **현행 `compute_awarded_points` 그대로**다(마이그레이션 10). 검증된 값이므로 바꾸지 않는다.
- 실내/수동을 낮은 상한으로 분리한 이유: PRD §8.3이 실내·수동 기록을 **누적 통계에는 반영**하도록
  확정했으므로 XP에서 통째로 배제하면 정책이 어긋난다. 다만 검증 불가능한 입력이라
  보너스 배수를 곱해주는 것은 어뷰징 유인이 된다. 레벨은 경쟁 지표가 아니므로(랭킹·티어와 무관)
  이 정도 완화로 충분하다.
- ⚠️ 이는 현행 산식의 **변경**이다. `is_flagged` 러닝은 지금도 0점이므로 부정 기록 정합성은 유지된다.

#### XP-2. 주간 스트릭 XP (꾸준함 축)

§3에서 정의하는 **활동 주** 1개마다, 그 주가 스트릭의 n번째 주일 때:

```
xp_streak(n) = 30 × min(n, 5)      →  1주차 30 / 2주차 60 / 3주차 90 / 4주차 120 / 5주차 이상 150
```

- **유예(freeze)로 메워진 주는 XP 0.** 스트릭 연결만 유지되고 보상은 없다 — 안 뛴 주다.
- 스트릭이 끊기면 다음 활동 주는 다시 n=1(30 XP)부터.
- 거리에 비례하지 않는다 — 주 1회 4km나 주 5회 60km나 스트릭 XP는 같다. 의도된 설계다.
  거리 보상은 XP-1이 이미 담당하고, 이 항목은 **"매주 나온다"** 만 보상한다.

#### XP-3. 뱃지 획득 XP

`user_badges`에서 `verified = true AND revoked = false` 인 행에 대해, 뱃지의 `badge_grade`별:

| badge_grade | XP |
|---|---|
| bronze | 100 |
| silver | 250 |
| gold | 600 |
| platinum | 1,500 |
| diamond | 4,000 |
| special | 200 |

⚠️ **`category = 'level'` 뱃지(9종)는 예외로 XP 0을 지급한다.**
레벨 뱃지가 XP를 주면 `XP → 레벨 → 레벨 뱃지 → XP` 순환이 생긴다. 정의로 끊는다.

#### XP-4. 티어 달성 XP

`tier_change_history`(마이그레이션 33/34 — 승급만 기록)에서 **(season_id, tier) distinct 조합**마다 1회:

| 도달 티어 | XP |
|---|---|
| bronze | 0 (시즌 시작 기본값) |
| silver | 300 |
| gold | 800 |
| platinum | 2,000 |

한 시즌에 플래티넘까지 오르면 실버·골드를 거치므로 300+800+2,000 = **3,100**이 누적된다.
시즌마다 다시 지급된다 — 티어는 시즌마다 리셋되므로 매 시즌 다시 올라간 노력에 대한 보상이 맞다.
`tier_change_history`가 승급만 기록하므로(마이그레이션 34) 기록 삭제로 티어가 하향돼도
과거 도달 사실은 남는다 — PRD §8.1 "자발적 삭제 시 뱃지 미회수"와 같은 철학이다.

### 1.2 레벨 임계값 — **정본은 아래 60개 정수 배열**

```
XP_required(L) = ceil( 50 × (L − 1)^2.2 )     for L in 1..60,   XP_required(1) = 0
level(xp)      = max{ L : XP_required(L) <= xp }   (상한 60)
```

**⚠️ 위 수식은 유도 근거이고, 계약은 아래 정수 배열이다.**
이전 라운드에서 지수 역함수의 부동소수 오차로 "레벨업까지 1pt 남음"이 고착되는 버그가 실제로
발생했다(`_workspace/20260819_210450_badge_rules.md` §4.3). 상한이 60인 이상 60개 정수를
양쪽(Postgres / Dart)에 그대로 심는 것이 가장 단순하고 **정확히 동일**하다. 역함수를 계산하지 말 것.

`XP_LEVEL_THRESHOLDS[L]` (인덱스 1..60):

```
L1..L10   0, 50, 230, 561, 1056, 1725, 2576, 3616, 4851, 6285
L11..L20  7925, 9774, 11836, 14114, 16614, 19337, 22287, 25466, 28879, 32526
L21..L30  36412, 40538, 44906, 49519, 54380, 59490, 64851, 70465, 76334, 82461
L31..L40  88846, 95492, 102401, 109573, 117011, 124716, 132690, 140934, 149450, 158239
L41..L50  167303, 176643, 186260, 196156, 206332, 216790, 227530, 238554, 249863, 261458
L51..L60  273341, 285513, 297974, 310726, 323770, 337108, 350739, 364666, 378889, 393410
```

**만렙 = 60으로 확정한다.** 현행 코드의 상한 100은 구 포인트 곡선의 잔재이고,
카탈로그의 `lvl_60` 표시명이 이미 **"만렙"**(diamond)이다. 60 위에 아무 보상도 없는 40레벨을
남겨두면 레벨 숫자만 인플레이션된다. `LevelCurve.maxLevel`을 60으로 내릴 것.

### 1.3 동기부여 곡선 검산

기준 사용자 3종의 월 XP 추정(뱃지·티어 XP 포함):

| 프로필 | 주간 러닝 | 월 XP |
|---|---|---|
| 캐주얼 | 1회 × 4km @7'00" | ≈ 1,300 |
| 표준 | 3회 × 6km @6'00" | ≈ 2,950 |
| 헤비 | 5회 × 12km @5'00" | ≈ 5,500 |

레벨 뱃지 9종 도달 시점(표준 사용자) — 카탈로그의 등급별 페이싱(브론즈 2~4주 / 실버 2~4개월 /
골드 8~19개월 / 플래티넘 2.7~5년 / 다이아 6~10년, `dist_cum_*`·`cnt_cum_*` 실측 기준)과 대조:

| 뱃지 | 등급 | 필요 XP | 표준 사용자 도달 | 등급 페이싱 적합 |
|---|---|---:|---|---|
| `lvl_5` 루키 | bronze | 1,056 | 11일 | ✅ |
| `lvl_10` 러너 | bronze | 6,285 | 2.1개월 | ✅ |
| `lvl_15` 에이스 | silver | 16,614 | 5.6개월 | ✅ |
| `lvl_20` 베테랑 | silver | 32,526 | 11개월 | ✅ |
| `lvl_25` 엘리트 | gold | 54,380 | 1.5년 | ✅ |
| `lvl_30` 챔피언 | gold | 82,461 | 2.3년 | ✅ |
| `lvl_40` 마스터 | platinum | 158,239 | 4.5년 | ✅ |
| `lvl_50` 그랜드마스터 | platinum | 261,458 | 7.4년 | ✅ |
| `lvl_60` 만렙 | diamond | 393,410 | 11.2년 | ✅ (`dist_cum_10000km` 10.7년과 동급) |

- **첫 러닝 1건(≈95 XP)으로 즉시 레벨 2**가 된다 — 온보딩 첫 보상.
- 헤비 사용자는 L60에 약 5.9년. 다이아 등급의 희소성이 유지된다.
- 간격이 등간격이 아니라 체증한다(레벨당 +50 → +14,500).

### 1.4 저장 위치 — **저장 컬럼(뷰 아님, 트리거로 갱신)**

| 컬럼 | 타입 | 비고 |
|---|---|---|
| `profiles.total_xp` | `integer not null default 0` | `total_points` 개명 |
| `profiles.level` | `integer not null default 1` | 기존 컬럼 유지, CHECK를 `between 1 and 60`으로 |
| `runs.awarded_xp` | `integer` | `awarded_points` 개명 |

**뷰로 만들지 않는 이유 3가지**
1. `evaluate_badge_condition`이 `level_gte`를 판정할 때 프로필 1행 읽기로 끝나야 한다.
   뷰면 뱃지 158행 루프마다 4원천 집계가 다시 돈다.
2. GM-04 수용 기준이 **"레벨업 시 알림"** 이다. 알림은 old→new 전이 감지가 필요하고,
   그건 저장 컬럼의 UPDATE 트리거에서만 자연스럽다.
3. XP-3(뱃지)·XP-4(티어)는 `runs`와 다른 테이블이 원천이라 뷰가 3-way 조인이 된다.

**갱신 경로**: `recompute_profile_stats(p_user_id)` 를 확장해 4원천을 재집계 → `total_xp` →
`compute_level(total_xp)` → `level`. 호출 지점 3곳:

| 트리거 | 테이블 | 사유 |
|---|---|---|
| 기존 `runs_0*` | `runs` INSERT/UPDATE/DELETE | XP-1, XP-2 |
| **신규** | `user_badges` AFTER INSERT/UPDATE(verified, revoked) | XP-3 |
| **신규** | `tier_change_history` AFTER INSERT | XP-4 |

**재진입 종료 보장**: 뱃지 획득 → XP 증가 → 레벨업 → 레벨 뱃지 지급 → (레벨 뱃지는 XP 0) →
`total_xp` 불변 → 레벨 불변 → 종료. `evaluate_badges`를 **"새 뱃지가 생겼으면 다시 한 번,
최대 3회"** 루프로 감싸면 한 트랜잭션에서 수렴한다. 무한 루프 방어로 `pg_trigger_depth()`
가드를 함께 둘 것.

### 1.5 파급 — 수정 대상

| 파일 | 조치 |
|---|---|
| `lib/models/app_user.dart` | `totalPoints` → `totalXp` (JSON key `total_xp`) |
| `lib/features/gamification/domain/level_curve.dart` | 상수/역함수 전면 교체 — `basePoints`/`exponent`/보정 루프 삭제, `XP_LEVEL_THRESHOLDS` 60개 정수 배열 + 이진 탐색으로 대체. `maxLevel = 60` |
| `test/gamification/level_curve_test.dart` | 임계값 단언 전면 갱신. **`levelForXp(threshold[L]) == L` 과 `levelForXp(threshold[L]-1) == L-1` 을 L=2..60 전수 검증하는 테스트를 반드시 남길 것** |
| Supabase | 컬럼 3개 rename, `compute_run_xp`/`compute_level` 교체, `recompute_profile_stats` 확장, 트리거 2개 신설, `level_gte` 스텁 → `profiles.level >= (condition->>'level')::int` |

---

## 2. `season_weekly_rank_lte` — `bucket` 값 도메인 확정

### 2.1 값 집합 — 정확히 3종

```
bucket ∈ { 'top1', 'top10', 'top10pct' }
```

카탈로그 12행(4티어 × 3버킷)이 쓰는 값이 전부이며, **확장하지 않는다.**
`condition` 스키마: `{"tier": "bronze"|"silver"|"gold"|"platinum", "bucket": "<위 3종>"}`.
backend는 CHECK 제약으로 이 두 도메인을 강제할 것.

### 2.2 순위(rank)의 정의

| 항목 | 확정 |
|---|---|
| 주 경계 | KST 월요일 00:00 ~ 일요일 23:59 (PRD §8.5). 러닝은 **시작 시각** 기준 귀속 |
| 집계 지표 | 그 주의 **검증 통과 실외 러닝 누적 거리** (PRD §8.3 — 실내·수동 기록 제외) |
| 모집단 | 그 주가 끝나는 시점에 해당 티어에 속하고, **주간 거리 > 0** 인 사용자. 0km 사용자는 순위를 갖지 않는다 |
| 티어 판정 시점 | **주 종료 시점의 `current_tier`** (PRD §8.6 — 주중 승급 시 거리를 들고 새 티어로 이동하므로, 그 주의 랭킹은 최종 티어에서 매겨진다) |
| 순위 부여 | 정렬 후 **1..N 고유 순위** (공동 순위 없음) |
| 동점 처리 | PRD §8.2 순서대로: ① 러닝 횟수 적은 사람 ② 해당 거리에 먼저 도달한 사람 ③ 총 러닝 시간 짧은 사람. 셋 다 동일하면 `user_id` 오름차순(결정성 확보용 최종 폴백) |
| 확정 시점 | 주 종료 직후 배치 — **매주 월요일 KST 00:10** (`pg_cron`: `10 15 * * 0` UTC) |

### 2.3 버킷별 판정식

`N` = 위 모집단 크기, `rank` = 대상 사용자의 순위.

| bucket | 조건 | 최소 모집단 |
|---|---|---|
| `top1` | `rank = 1` | **N ≥ 10** |
| `top10` | `rank <= 10` | **N ≥ 20** |
| `top10pct` | `rank <= ceil(N × 0.10)` | **N ≥ 20** |

**최소 모집단 조건을 넣은 이유.** PRD §5.4.1은 티어 인원 불균형을 해소하지 않기로 확정했고,
그 결과 시즌 초 플래티넘은 0~수 명, 시즌 말 브론즈는 수천 명이 된다. 인원이 3명인 티어에서
"위클리킹"을 주면 뱃지가 **참가상**이 되어 다른 사용자의 같은 뱃지 가치까지 떨어뜨린다.
PRD §5.4.1의 "소수 정예를 그대로 노출한다"는 **순위 표시**에 대한 결정이지 뱃지 발급 기준이 아니다.
모집단 미달 주에는 그 티어의 해당 버킷 뱃지를 **아무에게도 지급하지 않는다**(에러 아님, 조용히 skip).

`top10`과 `top10pct`는 포함 관계가 아니다 — N=20이면 `top10pct`는 상위 2명, `top10`은 상위 10명이라
`top10pct`가 더 좁다. N=3,000이면 반대가 된다. 각각 독립 판정하면 되고, 이는 의도된 설계다
(작은 티어에서는 "상위 10%"가, 큰 티어에서는 "TOP10"이 더 어려운 목표가 된다).

### 2.4 중복 획득 / 시즌 인스턴스

- 뱃지는 **시즌 인스턴스**(`srank_gold_top1@2026-Q3`)에 지급되므로, 한 시즌 안에서 여러 주 1위를 해도
  `user_badges` 행은 1개다(`on conflict (user_id, badge_id) do nothing`).
- 시즌이 바뀌면 새 인스턴스가 발급되므로 **다시 획득 가능**하다 — GM-07의 시즌 희소성 설계와 동일.
- 지급 대상 시즌: 그 주의 **종료일이 속한 시즌**. 시즌 경계에 걸친 단축 주간(PRD §8.5)도
  종료일 기준으로 하나의 시즌에만 귀속된다.

### 2.5 backend가 필요로 하는 입력

`weekly_ranking_cache` (아직 없음 — backend 신설 대상)에 최소한 아래가 있어야 위 판정이 가능하다:

```
week_id            text        -- 'YYYY-Www' (KST ISO 주)
season_id          text
user_id            uuid
tier               public.tier -- 주 종료 시점 확정 티어
weekly_distance_m  double precision
weekly_run_count   integer     -- §8.2 동점 처리 ①
weekly_moving_sec  integer     -- §8.2 동점 처리 ③
reached_at         timestamptz -- §8.2 동점 처리 ② (최종 거리에 도달한 러닝의 started_at)
rank               integer     -- 배치가 확정해 기록
```

`rank`를 배치가 **기록**해야 한다(조회 시마다 재계산 금지). 동점 처리 ②의 `reached_at`은
주간 누적 거리가 최종값에 도달한 러닝의 시작 시각이며, 이 값이 없으면 §8.2를 구현할 수 없다.

---

## 3. `streak_weeks_gte` — 주 단위 스트릭 + 1회 유예(GM-05)

### 3.1 주·활동 주의 정의

| 항목 | 확정 |
|---|---|
| 주 경계 | **KST 월요일 00:00 ~ 일요일 23:59** (PRD §8.5). 주 키는 KST ISO 주차 `'YYYY-Www'` |
| 러닝 귀속 | **`started_at`** 기준 (PRD §8.5 "경계 걸침은 시작 시각") |
| **활동 주** | 그 주에 `status='completed' AND NOT is_flagged` 러닝이 **1건 이상**이고, **그 주 합산 거리 ≥ 1.0 km** |
| 실내·수동 포함 여부 | **포함한다** |

**주간 최소 거리 1.0km를 넣은 이유.** 하한이 없으면 50m 기록으로 104주 스트릭을 유지할 수 있다.
1.0km는 러너에게 부담이 아니면서(PRD GM-05가 주 단위를 택한 이유가 회복일 확보다) "실제로 뛰었다"를
요구한다. 세션이 아니라 **주 합산** 기준이라 400m×3회도 통과한다.

**실내·수동을 포함하는 이유.** 스트릭은 이탈 방지 장치이지 경쟁 지표가 아니다.
겨울·우천에 트레드밀로 스트릭을 이어갈 수 없다면 GM-05가 목적을 정반대로 배신한다.
PRD §8.3이 실내·수동을 배제한 대상은 **티어·랭킹**이지 누적 자산이 아니다.

### 3.2 유예(freeze) 규칙

| 항목 | 확정 |
|---|---|
| 보유량 | **1개** (상한 1) |
| 소모 | 비활동 주가 확정되는 순간 **자동** 소모. 사용자 조작 없음 |
| 효과 | 그 주는 스트릭을 **끊지 않는다**. 단 **스트릭 카운트에 포함하지 않고 XP도 0** — 연결만 유지 |
| 회복 | 유예 사용 후 **연속 4주 활동**하면 크레딧 1개로 복구 |
| 리셋 | 스트릭이 0으로 끊기면 크레딧은 즉시 1로 초기화 (새 스트릭에 다시 안전망 제공) |
| 연속 2주 결석 | 크레딧이 1개뿐이므로 메울 수 없다 → 스트릭 0 |
| 진행 중인 주 | 아직 끝나지 않은 주는 **비활동으로 판정하지 않는다**(유예도 소모하지 않는다) |

회복 조건을 4주로 잡은 이유: 유예를 무제한 재충전하면 "2주에 1번만 뛰기"가 무한 스트릭이 된다.
유예 사용 → 4주 활동 → 재충전 이므로 **유예 사용 최대 빈도는 5주에 1회**로 자연 상한이 걸린다.

### 3.3 판정 알고리즘 — 순수 함수 (정본)

**크레딧은 저장 상태가 아니라 리플레이 파생값이다.** 매 계산마다 가입 주부터 다시 돌린다.
그래야 러닝이 삭제/플래그 처리돼도 같은 답이 나온다(원칙 1).

```
입력:
  activeWeeks   : Set<WeekKey>   -- §3.1 활동 주 조건을 만족하는 주들
  firstWeek     : WeekKey        -- 사용자 가입일이 속한 KST 주
  currentWeek   : WeekKey        -- 평가 시점(now, KST)이 속한 주
출력:
  { currentStreakWeeks, longestStreakWeeks, freezeCredits }

computeWeeklyStreak(activeWeeks, firstWeek, currentWeek):
    credits        = 1
    usedFreeze     = false
    sinceFreeze    = 0
    current        = 0
    longest        = 0

    for w in weeksInclusive(firstWeek, currentWeek):        # 주 단위로 1씩 전진
        if w in activeWeeks:
            current += 1
            longest = max(longest, current)
            if usedFreeze:
                sinceFreeze += 1
                if sinceFreeze >= 4:                        # 유예 회복
                    credits    = 1
                    usedFreeze = false
                    sinceFreeze = 0
        else:
            if w == currentWeek:
                break                                       # 진행 중인 주는 끊지 않는다
            if credits >= 1:
                credits    -= 1                             # 유예 자동 소모
                usedFreeze  = true
                sinceFreeze = 0                             # current 는 증가시키지 않는다
            else:
                current    = 0                              # 스트릭 종료
                credits    = 1                              # 새 스트릭용 안전망 리셋
                usedFreeze = false

    return { current, longest, credits }
```

- **`streak_weeks_gte` 뱃지가 보는 값은 `longestStreakWeeks`** 다.
  카탈로그 설명이 "역대 최장 주간 연속 러닝 스트릭"이고, 뱃지는 영구 자산이므로 한 번 달성하면 유지된다.
- `longest`는 **새 러닝으로만 증가**한다 → 뱃지 판정은 러닝 업로드 트리거만으로 충분하다.
  주간 cron 배치는 `current`/`credits`(표시·"스트릭 위험" 알림용) 갱신에만 필요하다.
- **진행 중인 주도 활동 주면 즉시 카운트된다** — 그래야 러닝 직후 GM-02 획득 연출이 뜬다.

### 3.4 저장 컬럼

| 컬럼 | 타입 | 성격 |
|---|---|---|
| `profiles.current_streak_weeks` | `integer not null default 0` | 리플레이 결과 캐시 |
| `profiles.longest_streak_weeks` | `integer not null default 0` | 리플레이 결과 캐시 · **뱃지 판정 소스** |
| `profiles.streak_freeze_credits` | `smallint not null default 1` | 리플레이 결과 캐시(표시용) |
| `profiles.streak_last_active_week` | `text` | KST ISO 주 키. 알림 판단용 |

기존 `current_streak_days`/`longest_streak_days`는 **삭제하지 않고 통계 표시용으로 남긴다.**
단 **뱃지 판정에는 절대 쓰지 않는다** — GM-05가 주 단위로 확정했다.

클라이언트에는 `GamificationStats.computeLongestStreakWeeks(runs)`를 위 알고리즘 그대로
추가한다(기존 `computeLongestStreakDays`는 유지). 서버와 **글자 그대로 같은 규칙**이어야 한다.

---

## 4. `device_source_count_gte` / `device_source_diversity_gte` — 토큰 이름과 OR 표현식 규약

> ⚠️ **gps-tracking-engineer 필독.** 아래 토큰 문자열은 **카탈로그 `condition` 값에 이미 박혀 있는
> 리터럴**이다(`"watchApple"`, `"watchApple_or_watchGarmin"`). 새로 추가할 enum/컬럼 값이
> 이 문자열과 **한 글자라도 다르면 판정이 전부 false가 된다.** 아래 이름을 그대로 쓸 것.

### 4.1 source 토큰 목록 (확정, 7종)

| 토큰 | 의미 | 우선순위 |
|---|---|---|
| `phone` | 앱의 폰 GPS 단독 기록 | P0 |
| `watchApple` | Apple Watch (watchOS 앱 또는 HealthKit workout의 source가 Apple Watch) | P0 |
| `watchGarmin` | Garmin (Garmin Connect → HealthKit / Health Connect 경유) | P1 |
| `watchWearOS` | Wear OS 워치 (Health Connect 경유) | P1 |
| `watchOther` | 그 외 워치·밴드 | P1 |
| `external` | 그 외 외부 앱/서비스 가져오기 (Strava 등) | P2 |
| `manual` | 사용자 수동 입력 | P0 |

**이름 규약**: `lowerCamelCase`. 워치는 `watch` + 벤더명 `PascalCase`. 공백·하이픈·언더스코어 없음
(언더스코어는 OR 구분자로 예약돼 있다 — §4.2).

**스키마 권고 (gps-tracking-engineer / backend 협의 대상)**

```
create type public.run_device_source as enum
  ('phone','watchApple','watchGarmin','watchWearOS','watchOther','external','manual');

alter table public.runs add column device_source public.run_device_source not null default 'phone';
```

- **세션당 단일 값**이다. "이 러닝을 만들어낸 주 기기"를 뜻한다.
- 기존 `run_sample_source`(`phone`/`watch`/`external`)는 **샘플 단위 전송 경로** enum이라
  의미가 다르다. 대체하지 말고 **병존**시킨다. 새 컬럼은 세션 단위 **벤더** 식별자다.
- 판정에 쓰이는 것은 `runs.device_source` 하나뿐이다 — `runs.sources` 배열은 보지 않는다.
  배열로 판정하면 한 러닝이 `phone`·`watchApple` 샘플을 모두 가질 때
  "애플워치로 뛴 50회"의 집계가 모호해진다.

> 📌 **이 이름들은 새로 지어낸 것이 아니다.** `docs/TRD.md` §3.1의 `RunSampleSource`가
> 이미 `phone` / `watchApple` / `watchGarmin` / `watchOther`로 설계돼 있었고
> ("애플워치로 완주 뱃지에 대비"라는 근거까지 적혀 있다), 라이브 DB로 내려오면서
> `phone`/`watch`/`external` 3종으로 축소된 것이 문제의 원인이다.
> 위 7종은 그 원래 설계를 복원하고 `watchWearOS`·`manual`을 추가한 것이다.

### 4.2 OR 표현식 문법 (확정)

```
expr  := token ( "_or_" token )*
token := 위 §4.1의 7개 값 중 하나 (대소문자 구분, exact match)
```

| 규칙 | 확정 |
|---|---|
| 구분자 | **`_or_`** — 정확히 소문자, 앞뒤 밑줄 포함 |
| 의미 | 논리 OR. 세션의 `device_source`가 토큰 중 **하나와 같으면** 매칭 |
| AND 연산자 | **없다.** `_and_`는 문법에 존재하지 않는다 |
| 괄호·중첩 | **없다.** 1단계 평면 OR만 |
| 공백 | 허용하지 않는다 |
| 미지 토큰 | 파싱 오류로 취급 — 그 뱃지는 판정 불가(`false`)로 두고 로그를 남긴다. 조용히 무시하지 말 것 |
| 검증 정규식 | `^[a-z][A-Za-z0-9]*(_or_[a-z][A-Za-z0-9]*)*$` |

### 4.3 두 condition_type의 판정 규칙

공통 대상 세션: `status = 'completed' AND NOT is_flagged`
(카탈로그 설명이 "기록한 러닝이 처음 **검증**될 때"이므로 플래그 기록은 제외한다).

**`device_source_count_gte`** — `{"source": "<expr>", "count": N}`

```
count( 대상 세션 중 device_source ∈ tokens(expr) )  >=  N
```
`source`도 `<expr>` 문법을 허용한다(현재 카탈로그 4행은 단일 토큰만 쓰지만, 문법을 통일해 둔다).

**`device_source_diversity_gte`** — `{"sources": ["<expr1>", "<expr2>", ...]}`

```
모든 i 에 대해:  count( 대상 세션 중 device_source ∈ tokens(expr_i) ) >= 1
```

- **배열 원소 간은 AND, 원소 내부 `_or_`는 OR.** 이것이 규약의 핵심이다.
- 각 원소는 **서로 다른 세션**으로 충족되어야 한다. `device_source`가 세션당 단일 값이고
  §4.1 토큰이 상호배타이므로 자동으로 성립하지만, 규약으로 명시해 둔다.
- 현행 유일 사례 `device_both_used` (올라운더):
  `{"sources": ["phone", "watchApple_or_watchGarmin"]}`
  → `device_source='phone'` 세션 ≥1건 **그리고** `device_source ∈ {watchApple, watchGarmin}` 세션 ≥1건.

### 4.4 미연동 사용자에 대한 기본값

`device_source` 컬럼 신설 전에 저장된 기존 러닝은 `default 'phone'`으로 백필된다.
이는 **의도된 관대함**이다 — 폰 GPS로 뛴 기록이 대부분이고, 워치 뱃지는 어차피
`watchApple`/`watchGarmin` 값이 실제로 기록되기 시작한 뒤에만 지급된다.

---

## 5. §6 가정값 정본화

이전 라운드가 구현하면서 스스로 채운 가정(`_workspace/20260825_193000_backend_badge-evaluation-logic.md` §6)을
전부 검토해 정식 규칙으로 확정한다. **변경되는 항목은 표에 ⚠️로 표시**했다.

### 5.1 PB 거리 허용오차 ⚠️ 변경

| 항목 | 이전 가정 | **확정** |
|---|---|---|
| 하한 | 목표 × 98% | **목표 − min(목표 × 2%, 300 m)** |
| 상한 | 목표 × 115% | **폐기 (상한 없음)** |
| 초과 세션의 기록 시간 | 세션 `moving_seconds` 그대로 | **§5.1.2 참조** |

#### 5.1.1 허용 부족분

```
tolerance_m = min( target_km × 1000 × 0.02, 300 )
인정 조건    : distance_meters >= target_km × 1000 − tolerance_m
```

| 목표 거리 | 허용 부족분 | 인정 하한 |
|---|---:|---:|
| 1 km | 20 m | 980 m |
| 5 km | 100 m | 4,900 m |
| 10 km | 200 m | 9,800 m |
| 21.1 km (하프) | 300 m | 20,800 m |
| 42.2 km (풀) | 300 m | 41,900 m |

이전의 고정 2%는 풀마라톤에서 **844m 부족**까지 인정해 버렸다 — 너무 관대하다.
상대 오차(GPS 거리 오차 실측 1~3%)를 짧은 거리에, 절대 상한 300m를 긴 거리에 적용해
두 특성을 모두 만족시킨다.

#### 5.1.2 상한 폐기 + 스플릿 보간

상한 115%는 잘못된 설계였다. 42.2km를 뛴 사람의 5km PB를 원천 차단하고, 동시에
11.5km 세션의 **총 시간**을 10km 기록으로 인정해 그 사람에게 불리하게 작동했다.

```
pb_time_lte 판정 시 대상 세션의 기록 시간:
  distance ∈ [목표−tolerance, 목표 × 1.02]  →  세션 moving_seconds 그대로 사용
  distance >  목표 × 1.02                    →  GPS 샘플 선형 보간으로 "목표 거리 통과 시각" 산출
                                               (보간 불가 = 샘플 없음 → 그 세션은 해당 거리 PB로 인정하지 않음)
```

- `pb_first_achieved`(첫 완주)는 **시간과 무관**하므로 §5.1.1의 거리 조건만 본다. 상한 없음.
- 거리 비례 환산(`시간 × 목표/실제`)은 **금지**한다. 페이스가 균일하지 않아 부정확하고,
  긴 세션에서 실제보다 빠른 가짜 PB를 만든다.
- 대상 필터는 유지: **실외(`activity_type <> 'indoor_run'`) · `status='completed'` · `NOT is_flagged`.**

### 5.2 `loop_course_count_gte` ⚠️ 변경

| 항목 | 이전 가정 | **확정** | 근거 |
|---|---|---|---|
| 출발-도착 근접 반경 | ≤ 200 m | **≤ 150 m** | 도심 GPS 시작/종료 픽스 편차 10~30m. 150m면 "건물 앞↔뒤" 수준의 정당한 루프를 살리면서 왕복(out-and-back) 코스를 거른다 |
| 최소 총 거리 | ≥ 1.0 km | **≥ 2.0 km** | 1km 루프는 대부분 우연히 성립한다. 2km면 "루프 코스를 돌았다"는 의도가 담긴다 |
| 샘플 요건 | (없음) | **GPS 샘플 ≥ 10개** | 샘플 없는 수동/실내 기록이 시작=끝으로 오판되는 것을 막는다 |

- 거리 계산은 첫 샘플과 마지막 샘플의 **haversine 직선거리**(기존 `_haversine_meters` 그대로).
- **출발점 최대 이탈 거리 조건은 두지 않는다.** 400m 트랙 5바퀴(최대 이탈 ≈127m)도
  정당한 루프 코스이며, 이탈 조건은 이를 잘못 배제한다.
- ⚠️ 임계값이 조여지므로 **이미 지급된 `route_loop_10`은 회수하지 않는다**(문서 상단 원칙 3).
  `evaluate_badges`가 INSERT 전용이므로 자동으로 지켜진다.

### 5.3 `route_diversity_count_gte` ⚠️ 변경

이전의 "위경도 소수 3자리 반올림"은 **그리드 스내핑**이라 경계 문제가 있다 —
20m 떨어진 두 시작점이 셀 경계를 사이에 두면 서로 다른 경로로 잡힌다.

**확정: 반경 300m 그리디 클러스터링 (결정적 순수 함수)**

```
대상 세션: status='completed' AND NOT is_flagged AND GPS 첫 샘플 존재
1. 세션을 started_at 오름차순 정렬                       ← 결정성의 핵심
2. clusters = []
3. 각 세션의 시작점 p 에 대해:
     near = { c ∈ clusters : haversine(p, c.anchor) <= 300 m }
     if near 비어있음 : clusters += Cluster(anchor = p)     ← 새 경로
     else            : (가장 가까운 c 에 편입, anchor 는 갱신하지 않는다)
4. 결과값 = len(clusters)
```

| 결정 | 근거 |
|---|---|
| 반경 **300 m** | 같은 집/직장 앞 출발(주차 위치 차이, GPS 초기 픽스 편차 포함)을 하나로 묶고, 다른 동네·공원은 분리한다. 100m는 초기 픽스 오차만으로 같은 장소가 쪼개진다 |
| **시간순** 처리 | 순서를 고정하지 않으면 같은 데이터에서 다른 개수가 나온다 |
| anchor **갱신 안 함** | 대표점을 이동 평균으로 갱신하면 결과가 처리 순서·부동소수에 훨씬 민감해진다. 첫 세션 시작점을 고정하면 클라이언트/서버가 항상 같은 답을 낸다 |

성능은 O(n·k)이고 n(러닝 수)·k(클러스터 수)가 모두 작아 문제되지 않는다.

### 5.4 페이스 3종 — 스플릿 보간 ⚠️ 변경

`_run_km_split_seconds`가 현재 "경계를 처음 넘는 샘플의 시각"을 그대로 쓴다.
폰 GPS(1~5초 간격)에서는 오차가 무시할 만하지만, **워치 동기화 기록은 샘플 간격이 60초 이상**일 수
있어 km 스플릿이 최대 1분까지 틀어진다. §5.1.2의 PB 보간도 같은 헬퍼를 쓰므로 보간이 필수다.

**확정: 경계를 사이에 둔 두 샘플 간 누적거리 비율로 시각을 선형 보간한다.**

```
t(D) = t[i-1] + (t[i] − t[i-1]) × (D − d[i-1]) / (d[i] − d[i-1])
       where d[i-1] < D <= d[i],  d = cumulative_distance_meters, t = timestamp
```

추가 확정 사항 3건:

| condition_type | 확정 |
|---|---|
| `pace_negative_split_count_gte` | 분할 기준 = **총 거리의 정확히 절반 지점**(위 보간). 후반 소요 < 전반 소요. **세션 거리 ≥ 4 km** 인 세션만 대상 (짧은 러닝의 스플릿 차이는 노이즈) |
| `pace_final_km_faster_pct_gte` | **세션 거리 ≥ 5 km**. 마지막 **완주된** 1km 스플릿 vs 그 앞 구간 전체의 평균 km 페이스. 자투리 구간은 비교에서 제외 |
| `pace_variance_lte` | CV(변동계수) = stddev/mean × 100. 대상은 **완주된 정수 km 스플릿만** (마지막 자투리 구간 제외 — 200m 자투리가 통째로 이상치가 되어 CV를 왜곡한다). **스플릿 ≥ 3개** 여야 판정한다(2개짜리 CV는 무의미) |

`pace_consistent_1`(메트로놈) 설명에 이미 "5km 이상 세션 한정"이 있으므로 `pace_variance_lte`의
스플릿 3개 조건과 모순되지 않는다.

### 5.5 그 외 정본화

| 항목 | 확정 |
|---|---|
| `streak_weeks_gte` 가정 | **§3으로 전면 대체.** 이전 가정("유예 없음")은 GM-05 위반이었다 |
| `calendar_date_match` 음력 | **§6으로 대체** |
| 시각 기준 | 모든 날짜·시간대 판정은 **KST(UTC+9 고정, 서머타임 없음)**. 러닝 귀속은 `started_at` |

---

## 6. 음력 날짜 — 고정 룩업 테이블 (확정)

### 6.1 방식 확정

**음력 변환 함수를 구현하지 않는다. 고정 룩업 테이블을 채택한다.**

| 판단 | 근거 |
|---|---|
| 변환 함수 미구현 | 정확한 한국 음력은 **한국천문연구원의 삭(朔) 계산(동경 135°E 기준)** 을 따라야 한다. 중국 음력(120°E)과 **날짜가 갈리는 해가 실제로 있다** — 예: 2027년 설날은 한국 2/7, 중국 2/6. 범용 음력 라이브러리를 쓰면 이 차이를 그대로 버그로 들여온다 |
| 룩업 테이블 | 필요한 것은 **연간 2일**뿐이다. 15년치 = 30행. 유지보수 비용이 사실상 0 |
| 갱신 | 2038년경 다음 15년치를 추가하면 된다. 테이블 미등재 연도는 판정 `false`(뱃지 미지급) — 조용히 넘어가되 로그를 남길 것 |

### 6.2 날짜 목록 (2026~2040, 한국천문연구원 기준 · 15년치)

| 연도 | 설날 (음 1/1) | 추석 (음 8/15) |
|---|---|---|
| 2026 | 2026-02-17 | 2026-09-25 |
| 2027 | 2027-02-07 | 2027-09-15 |
| 2028 | 2028-01-27 | 2028-10-03 |
| 2029 | 2029-02-13 | 2029-09-22 |
| 2030 | 2030-02-03 | 2030-09-12 |
| 2031 | 2031-01-23 | 2031-10-01 |
| 2032 | 2032-02-11 | 2032-09-19 |
| 2033 | 2033-01-31 | 2033-09-08 |
| 2034 | 2034-02-19 | 2034-09-27 |
| 2035 | 2035-02-08 | 2035-09-16 |
| 2036 | 2036-01-28 | 2036-10-04 |
| 2037 | 2037-02-15 | 2037-09-24 |
| 2038 | 2038-02-04 | 2038-09-13 |
| 2039 | 2039-01-24 | 2039-10-02 |
| 2040 | 2040-02-12 | 2040-09-21 |

> ⚠️ **2027 / 2028 설날 주의.** 중국 음력 기준 라이브러리는 각각 2027-02-06 / 2028-01-26을 반환한다.
> 위 표(한국 기준)가 정본이다. 구현 후 이 두 해로 회귀 테스트를 반드시 넣을 것.

### 6.3 저장 위치와 판정

**권고: `public.lunar_holidays` 소형 마스터 테이블**

```
lunar_holidays (
  holiday_key  text     -- 'lunar_newyear' | 'chuseok'  ← condition 의 date 값과 동일 문자열
  year         integer
  solar_date   date     -- KST 양력 날짜
  primary key (holiday_key, year)
)
```

- `condition->>'date'` 값(`'lunar_newyear'`, `'chuseok'`)을 **그대로 `holiday_key`로 쓴다** —
  매핑 테이블이 하나 더 생기지 않게 한다.
- 판정: 러닝 `started_at`을 KST 날짜로 변환 → `(holiday_key, extract(year from kst_date))`로 조회 →
  `solar_date`와 일치하면 true.
- 함수 내부 CTE/`VALUES` 리스트로 하드코딩해도 동작하지만, **테이블을 권고한다** —
  15년 뒤 갱신이 마이그레이션이 아니라 INSERT 한 줄이 되고, 관리자가 값을 눈으로 확인할 수 있다.
- RLS: `authenticated`/`anon` SELECT 허용(공개 상수), 쓰기는 `service_role`만.

### 6.4 검토했으나 채택하지 않은 것 — 연휴 3일 확대

명절 **당일**은 차례·이동으로 러닝이 어려워 획득률이 낮을 것이 예상되므로,
연휴 3일(전날·당일·다음날) 중 하루로 넓히는 안을 검토했다. **이번에는 채택하지 않는다** —
같은 카테고리의 다른 8종(`special_newyear`, `special_christmas` 등)이 전부 당일 기준이라
설날/추석만 3일로 하면 규칙이 불균질해진다. 위 테이블 구조는 `solar_date` 컬럼을
`start_date`/`end_date`로 확장하면 **데이터만 고쳐** 넓힐 수 있으므로, 출시 후 획득률 실측을 보고
재검토한다.

---

## 7. `district_diversity_gte` 삭제 — 부수 영향 검토 결과

### 7.1 삭제 대상 (정확한 ID)

| 뱃지 ID | 표시명 | 등급 | condition | CSV 행 |
|---|---|---|---|---|
| `route_district_3` | 동네탐방 | bronze | `{"distinctDistricts": 3}` | 82 |
| `route_district_10` | 구역정복 | gold | `{"distinctDistricts": 10}` | 83 |

condition_type `district_diversity_gte`도 함께 폐기한다(이 2종이 유일한 사용처).

### 7.2 부수 영향 — **없음. 삭제해도 안전하다** (전수 확인 완료)

| 검사 항목 | 결과 |
|---|---|
| 지급된 `user_badges` | **0건**. 판정이 계속 `false` 스텁이었고, 이전 라운드 전수 실행(시드 10명 121건)에서 차단 카테고리 지급 0건이 확인됐다 |
| 카테고리 공동화 | **없음.** `경로탐험`은 9종 → **7종**으로 줄 뿐 유지된다 (`route_diverse_5/10/25`, `elev_cum_*` 3종, `route_loop_10`). 마이그레이션 35와 달리 **카테고리·enum 삭제는 불필요**하다 — `BadgeCategory.routeExploration`을 그대로 둘 것 |
| 다른 뱃지의 선행 조건 | **없음.** 카탈로그에 뱃지 간 의존 관계 자체가 없다 |
| 진행률 계산 | **영향 없음.** `BadgeProgress`는 뱃지별 독립 계산이고 총 개수를 하드코딩하지 않는다 |
| 등급별 집계 | bronze 29→28, gold 25→24. 어떤 로직도 이 개수에 의존하지 않는다 |
| 역지오코딩 인프라 | 삭제로 **PostGIS 확장·법정동 경계 데이터·외부 역지오코딩 API 의존이 전부 불필요해진다** (`20260825_181914` §7.1의 미결 사항이 통째로 소멸). 다른 뱃지 중 역지오코딩을 쓰는 것은 없다 |

### 7.3 삭제 후 카탈로그 규모

| 지표 | 전 | 후 |
|---|---|---|
| 뱃지 수 | 148 | **146** |
| 카테고리 수 | 14 | **14** (변화 없음) |
| distinct condition_type | 40 | **39** |
| 경로탐험 | 9 | 7 |
| bronze / gold | 29 / 25 | 28 / 24 |

### 7.4 backend 마이그레이션 체크리스트

1. `delete from public.user_badges where badge_id in ('route_district_3','route_district_10');`
   (0건 예상 — 방어적으로 먼저 실행)
2. `delete from public.badges where id in ('route_district_3','route_district_10');`
3. `badges_condition_type_check` CHECK 제약에서 `'district_diversity_gte'` 제거
   (마이그레이션 25의 목록 재정의)
4. `evaluate_badge_condition`의 `when 'district_diversity_gte' then ... raise notice` 분기 삭제
   (현재 마이그레이션 33에 살아 있는 버전이 최신)
5. 멱등성 확인 — 재적용해도 안전해야 한다

### 7.5 클라이언트 수정

| 파일 | 조치 |
|---|---|
| `lib/features/gamification/domain/badge_condition.dart` | `districtDiversityGte` 상수 삭제 (L57), `all` 집합에서 제거 (L99), L167 주석의 언급 정리 |
| `test/gamification/*` | `BadgeConditionType.all.length` 단언이 있으면 39로 갱신 |
| `docs/badge-catalog.csv` | 82·83행 삭제 — **이 문서와 함께 반영 완료** |
| `docs/TRD.md` | §10.1의 "40종" → "39종", 스텁 목록에서 district 제거 — **반영 완료** |

---

## 8. backend-engineer 인계 요약 (구현 순서 권고)

| # | 작업 | 선행 조건 | 난이도 |
|---|---|---|---|
| 1 | `district_diversity_gte` 삭제 마이그레이션 (§7.4) | 없음 | 낮음 |
| 2 | `lunar_holidays` 테이블 + `calendar_date_match` 음력 분기 (§6) | 없음 | 낮음 |
| 3 | §5 임계값 반영 — PB 허용오차·보간, 루프 150m/2km, 클러스터 300m, 스플릿 선형 보간 (§5) | 없음 | 중간 |
| 4 | `runs.device_source` 컬럼 + `device_source_*` 2종 판정 (§4) | **gps-tracking-engineer**의 enum 값 확정 — §4.1 이름과 일치해야 함 | 중간 |
| 5 | XP 개명 + 4원천 + 레벨 임계값 + `level_gte` (§1) | 없음 (클라이언트 `AppUser`/`LevelCurve` 동시 수정 필요) | **높음** |
| 6 | 주 단위 스트릭 리플레이 + `streak_weeks_gte` 교체 (§3) | 없음 | 중간 |
| 7 | `weekly_ranking_cache` + 주간 배치 + `season_weekly_rank_lte` (§2) | `seasons` 테이블 | **높음** |

**서버 재검증 원칙 재확인.** §1~§6의 모든 판정은 클라이언트가 진행률 추정에 같은 식을 쓰지만,
`UserBadge` / `profiles.level` / `rank` 를 **확정하는 것은 서버뿐**이다. 특히 아래 3개는
클라이언트 값을 절대 신뢰하면 안 되는 어뷰징 경로다:

- **XP-1 세션 XP** — 거리·페이스·고도가 조작되면 레벨이 조작된다. `is_flagged` 재계산 후 산정할 것
- **§2 주간 순위** — 다른 사용자 집계라 클라이언트가 계산 자체를 할 수 없다
- **§5.1 PB** — 비현실적 페이스(PRD §8.4: 평균 3:00/km 미만)는 플래그 처리 후 PB에서 제외할 것
