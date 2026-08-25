# 뱃지 백로그 7건 구현 — 적용 완료 보고

작성: backend-engineer / 2026-08-26
대상 프로젝트: Supabase `xwtbwexcofcgmbvktwdo` (Runnit, ap-southeast-1)
작업 위치: `/Users/jehyun/Runnit/.claude/worktrees/organize-todo-list-e416ed`

기준 문서 (전부 선독 후 그대로 옮김, 새 설계 판단 없음)
- `docs/PRD.md` §5.3 / §5.5 / §5.6 / §8
- `docs/TRD.md` v0.5 → **v0.6으로 갱신** (§3.1.1·§3.1.2·§3.8·§4.0·§10.1·§10.2·§14)
- `docs/badge-catalog.csv` (146 템플릿)
- `_workspace/20260826_012000_architect_device-vendor-arbitration.md` §2 (기기 벤더 정본)
- `_workspace/20260826_000340_gamification_badge-backlog-decisions.md` §1·§2·§3·§5·§6·§7
- `_workspace/20260825_193000_backend_badge-evaluation-logic.md` (이전 라운드 기준선)

> **한 줄 요약**: `evaluate_badge_condition` 의 `raise notice … 보류` 스텁이 **0개**가 됐다.
> `condition_type` **39종 전량이 실제 판정**이며, 이제 `false` 가 나오면 스텁이 아니라 조건 미충족이다.

---

## 1. 적용한 마이그레이션 (6개, 전부 적용 완료)

| 파일 | DB 등록명 | 내용 |
|---|---|---|
| `supabase/migrations/20260826020000_36_device_vendor.sql` | `36_device_vendor` | `device_vendor` enum 5종 + `runs.device_vendors` 배열 + GIN 인덱스 + 보수적 백필 + `device_both_used` 설명문 정정 |
| `supabase/migrations/20260826020100_37_remove_district_diversity.sql` | `37_remove_district_diversity` | `route_district_3`/`_10` 삭제, `condition_type` CHECK 44→**39종**, `category` CHECK 16→**14종**, `bucket` 도메인 CHECK 신설 |
| `supabase/migrations/20260826020200_38_lunar_holidays.sql` | `38_lunar_holidays` | `lunar_holidays` 테이블 + RLS + 2026~2040 30행 시드 |
| `supabase/migrations/20260826020300_39_xp_level_and_weekly_streak.sql` | `39_xp_level_and_weekly_streak` | XP 개명 + 4원천 + 60레벨 정수 배열 + 주간 스트릭 4컬럼 + 갱신 트리거 2개 + `evaluate_badges` 3패스 수렴 루프 |
| `supabase/migrations/20260826020400_40_weekly_rank_tiebreak_reached_at.sql` | `40_weekly_rank_tiebreak_reached_at` | `leaderboard_entries.reached_at` + PRD §8.2 3단계 타이브레이크 |
| `supabase/migrations/20260826020500_41_badge_condition_canon_rules.sql` | `41_badge_condition_canon_rules` | 헬퍼 8종 + `evaluate_badge_condition` 전면 재정의(스텁 전량 해제) + 전 프로필 재평가 |

기존 마이그레이션 파일은 **한 줄도 수정하지 않았다.** 27/32/33번의 `보류` 스텁은 파일을 고치는 대신
41번에서 `create or replace` 로 함수 전체를 재정의해 대체했다(프로젝트 관례).

---

## 2. 지시 항목별 처리 결과

### 2.1 기기 벤더 — ✅ 완료

중재 문서 §2.1 DDL을 그대로 적용했다. **스칼라 안(`runs.device_source`, 토큰 7종)은 만들지 않았다.**

- `create type public.device_vendor as enum ('phone','watchApple','watchGarmin','watchOther','unknown')`
- `runs.device_vendors public.device_vendor[] not null default '{}'` + `runs_device_vendors_gin`
- 백필: `sources @> '{phone}'` 인 행만 `{phone}` 으로. **무조건 채우지 않는다** — `{}`(정보 없음)과
  `{phone}`(폰 단독 확정)은 다른 뜻이다. 시드 러닝 35건은 `sources = '{}'` 라 **0건이 백필됐고, 이는 정상**이다.
- `_device_vendor_tokens(text)` 파서 신설 — `_or_` 구분자, 검증 정규식
  `^[a-z][A-Za-z0-9]*(_or_[a-z][A-Za-z0-9]*)*$`, 미지 토큰이면 `null` + `raise notice`(조용히 무시 안 함).
- 매칭은 **단일 규칙** `device_vendors && ARRAY[tokens(expr)]`, 대상 세션 `completed AND NOT is_flagged`.
- `device_both_used` 는 **"서로 다른 세션" 제약 없음** — 하이브리드 세션 1건이 두 원소를 동시에 충족하면 지급.
- 27/32/33번의 `device_source_count_gte`/`device_source_diversity_gte` 스텁 해제 완료.

### 2.2 XP / 레벨 — ✅ 완료

| 개명 | 결과 |
|---|---|
| `profiles.total_points` → `profiles.total_xp` | ✅ (구 컬럼 잔존 0건) |
| `runs.awarded_points` → `runs.awarded_xp` | ✅ |
| `compute_awarded_points(3인자·5인자)` → `compute_run_xp(6인자)` | ✅ 구 함수 2개 `drop` |
| `compute_level(p_total_points)` → `compute_level(p_total_xp)` | ✅ 정수 배열 조회로 교체 |

- **재계산 방식**(증분 가산 금지). `recompute_profile_stats` 가 4원천을 매번 재집계한다:
  XP-1 `sum(runs.awarded_xp)` / XP-2 스트릭 리플레이 / XP-3 뱃지 등급별 / XP-4 `tier_change_history` distinct.
- **`category='level'` 뱃지는 XP 0** — `XP → 레벨 → 레벨 뱃지 → XP` 순환을 정의로 끊는다.
- 레벨 곡선은 **60개 정수 배열이 정본**(`public.xp_level_thresholds()`). 역함수를 계산하지 않는다.
- `profiles.level` CHECK `between 1 and 60` (`profiles_level_range`, 구 `profiles_level_positive` 대체).
- 신규 트리거 2개: `user_badges_02_recompute_xp`, `tier_change_history_01_recompute_xp`
  (공통 함수 `trg_recompute_xp_source()`, `pg_trigger_depth() > 8` 가드).
- `evaluate_badges` 를 **최대 3패스 수렴 루프**로 감쌌다. 패스 끝에서만 `recompute_profile_stats` 를 호출하고,
  그 사이 `user_badges` 트리거는 세션 변수 `runnit.badge_eval='on'` 을 보고 스킵한다 —
  켜둔 채로 두면 지급 뱃지 N개마다 전체 재집계가 N번 돈다(결과 동일, 비용만 N배).

⚠️ **정본 대비 1건 제거**: 구 `recompute_profile_stats` 가 `total_points` 에 더하던
`challenges.reward_points` 항을 뺐다. XP 4원천에 챌린지가 없고 `reward_points` 는 Phase 4 포인트 이름이다.
(현재 `challenges` 0행이라 값 영향 없음.)

### 2.3 주 단위 스트릭 + 1회 유예 — ✅ 완료

`_weekly_streak_state(uuid)` 신설. **크레딧을 저장하지 않고** 매번 가입 주부터 리플레이한다.

- 활동 주 = 완주·비플래그 러닝 1건 이상 **AND** 주 합산 거리 ≥ 1.0km (실내·수동 **포함**)
- 유예 1개 자동 소모 → 사용 후 연속 4주 활동 시 회복 → 스트릭 종료 시 즉시 1로 리셋
- 유예 주는 스트릭 카운트·XP 모두 0. 진행 중인 주는 비활동으로 판정하지 않음
- 캐시 컬럼 4개 신설: `current_streak_weeks` / `longest_streak_weeks` / `streak_freeze_credits` / `streak_last_active_week`
- `streak_weeks_gte` 판정은 **`longest_streak_weeks`** 를 본다(카탈로그 설명 "역대 최장", 뱃지는 영구 자산)
- 기존 `*_streak_days` 는 삭제하지 않고 통계 표시용으로 남겼다 — 뱃지 판정에는 쓰지 않는다
- 클라이언트에 `GamificationStats.computeWeeklyStreak(runs)` / `computeLongestStreakWeeks(runs)` 를
  **같은 알고리즘으로** 추가했고, 서버와 같은 시나리오에서 같은 답(longest=6)이 나오는 것을 테스트로 잠갔다

### 2.4 `season_weekly_rank_lte` bucket 도메인 — ✅ 완료

- `bucket ∈ {top1, top10, top10pct}` — 판정 함수에서 도메인 검증 + `badges` CHECK 제약(`badges_season_weekly_rank_domain`) 이중 방어
- 최소 모집단: `top1` N≥10, `top10`/`top10pct` N≥20. 미달 주에는 **아무에게도 지급하지 않는다**(에러 아님)
- `top10pct` = `rank <= ceil(N × 0.10)`. `top10` 과 포함 관계가 아닌 것은 의도된 설계
- 동점 처리 = **PRD §8.2 3단계 + `user_id` 폴백**을 `refresh_leaderboard` 의 순위 부여에 반영:
  `score desc → run_count asc → reached_at asc → total_moving_seconds asc → user_id asc` (공동 순위 없음)

⚠️ **테이블명 — 지시서의 `weekly_ranking_cache` 는 라이브에 존재하지 않는다.**
실제 이름은 `public.leaderboard_entries`(마이그레이션 03)이고 §2.5가 요구한 컬럼이 이미 전부 들어 있었다
(`week_id`→`period_start`, `weekly_distance_m`→`score`, `weekly_run_count`→`run_count`,
`weekly_moving_sec`→`total_moving_seconds`, `rank`, `tier`, `N`→`participant_count`).
**없던 것은 `reached_at` 하나뿐**이라 새 테이블을 만들지 않고 이 테이블에 컬럼을 추가했다.
마이그레이션 32/33의 `season_weekly_rank_*` 판정도 이미 이 테이블을 읽고 있었다.
매핑표를 TRD **§4.3(신설)** 에 적어 뒀다.

### 2.5 PB / 루프 / 클러스터링 정본 수치 — ✅ 완료

| 항목 | 이전 | 확정 적용값 |
|---|---|---|
| PB 허용 부족분 | 고정 2% | `min(목표 × 2%, 300m)` |
| PB 거리 상한 | 115% | **폐지**. 목표의 102% 초과 세션은 **샘플 선형 보간**으로 통과 시각 산출, 보간 불가면 미인정 |
| 루프 코스 | 200m / 1.0km | **150m / 2.0km / GPS 샘플 ≥ 10** |
| 경로 다양성 | 소수 3자리 그리드 스내핑 | **반경 300m 그리디 클러스터링**(`started_at` 오름차순, anchor 미갱신 → 결정적) |
| km 스플릿 | 무보간(경계를 처음 넘는 샘플 시각) | **선형 보간** `t(D) = t[i-1] + (t[i]−t[i-1]) × (D−d[i-1])/(d[i]−d[i-1])` |
| 네거티브 스플릿 | 스플릿 개수의 절반 | **거리의 절반 지점**(보간) + 세션 ≥ 4km |
| 마지막 1km 가속 | 제한 없음 | 세션 ≥ 5km |
| 페이스 변동계수 | 스플릿 ≥ 2 | **스플릿 ≥ 3** |

거리 비례 환산(`시간 × 목표/실제`)은 구현하지 않았다 — 정본이 금지한 방식이다.

### 2.6 음력 룩업 테이블 — ✅ 완료

`public.lunar_holidays(holiday_key, year, solar_date)` 2026~2040 **30행**.
`holiday_key` 는 `condition ->> 'date'` 값(`lunar_newyear`/`chuseok`)과 같은 문자열 — 매핑 계층 없음.
RLS: `anon`/`authenticated` SELECT 허용, 쓰기 정책 없음 + write 권한 revoke.
미등재 연도는 `false` + `raise notice`(조용히 넘기지 않음).

**2027/2028 재확인 결과 — 문서 값이 맞다.** 검증 방식: 해당 삭(朔) 시각을 KST(135°E)와 CST(120°E)로 각각 환산.

| 연도 | 삭(UTC) | KST 환산 | CST 환산 | 결론 |
|---|---|---|---|---|
| 2027 설날 | 2/6 15:5x | **2/7 00:5x → 2/7** | 2/6 23:5x → 2/6 | 표의 **2027-02-07** 맞음 |
| 2028 설날 | 1/26 15:1x | **1/27 00:1x → 1/27** | 1/26 23:1x → 1/26 | 표의 **2028-01-27** 맞음 |

두 해 모두 삭이 KST 자정 **직후**에 들어 한국이 하루 늦는 전형적 케이스이고, 정본 문서의 경고와 기전이 정확히 일치한다.
DB에 중국 기준값(2027-02-06 / 2028-01-26)이 한 건도 없음을 쿼리로 확인했다.

### 2.7 `district_diversity_gte` 삭제 마무리 — ✅ 완료

DB 시드에 `route_district_3`/`route_district_10` 이 **남아 있었다**(CSV만 삭제된 상태였다).
마이그레이션 35와 같은 패턴으로 처리:
`user_badges` 삭제(0건 — 예상대로) → `badges` 삭제(2건) → `condition_type` CHECK 재정의.

CHECK 재정의 시 마이그레이션 35가 뱃지만 지우고 남겨뒀던 시즌 4종
(`season_cumulative_distance_gte` / `consecutive_seasons_participated_gte` /
`season_first_and_last_week_active` / `season_final_week_active`)도 함께 제거했다.
`44 − 4 − 1 = 39` 로 TRD §4.1·§10.1의 "39종" 서술과 이제 실제로 일치한다.
`category` CHECK 도 같은 이유로 16 → 14종으로 정리했다.
`BadgeCategory.routeExploration` 은 **존치**(9종 → 7종으로 줄 뿐).

---

## 3. 클라이언트(Dart) 동반 변경

`flutter analyze` **0건**, `flutter test` **91/91 통과**(이전 80건 → 스트릭·레벨 테스트 11건 추가).
`build_runner` 재생성 완료.

| 파일 | 변경 |
|---|---|
| `lib/models/app_user.dart` | `totalPoints` → **`totalXp`** (JSON `total_xp`). 주석에 "Phase 4 포인트와 다른 개념" 명시 |
| `lib/models/run_record.dart` | `awardedPoints` → **`awardedXp`**. `deviceVendors` 주석의 **"폰 단독 기록: 정확히 `[phone]`"** 서술을 중재 결과(배열 겹침, 하이브리드 세션 인정)로 교체 |
| `lib/features/gamification/domain/level_curve.dart` | **전면 교체.** `basePoints`/`exponent`/보정 루프 삭제 → `thresholds` 60개 정수 배열 + 이진 탐색. `maxLevel = 60`. `levelForPoints`→`levelForXp`, `pointsRequiredFor`→`xpRequiredFor`, `pointsToNextLevel`→`xpToNextLevel` |
| `lib/features/gamification/domain/gamification_stats.dart` | **`computeWeeklyStreak` / `computeLongestStreakWeeks` 신설**(서버 리플레이와 동일 규칙) + `WeeklyStreakState` |
| `lib/features/gamification/domain/badge_condition.dart` | `districtDiversityGte` 상수·`all` 원소 삭제(40→39종) |
| `lib/features/tracking/data/local_run_repository.dart` | `_serverOwnedKeys` 의 `awarded_points` → `awarded_xp` |
| `lib/features/profile/presentation/profile_page.dart` | `profile?.totalPoints` → `profile?.totalXp` |
| `test/gamification/level_curve_test.dart` | 임계값 단언 전면 갱신 + **L=2..60 전수 경계 검증 유지**(부동소수 버그 재발 방지 잠금) + 주간 스트릭 8케이스 신설 |

---

## 4. 검증

### 4.1 `get_advisors(security)` — 신규 경고 **0건**

기존 4건만 그대로다(전부 이번 작업과 무관한 선재 이슈):
`rls_auto_enable` anon/authenticated 실행 가능, `sync_my_season` authenticated 실행 가능,
Auth leaked-password protection 비활성(대시보드 설정).
이번에 만든 `SECURITY DEFINER` 함수(`_weekly_streak_state`, `_route_cluster_count`, `_pb_best_seconds`,
`trg_recompute_xp_source`)는 전부 `revoke execute … from public, anon, authenticated` 했다.

### 4.2 레벨 곡선 — 부동소수 버그 재발 없음

과거 "레벨업까지 1pt 남음"이 고착된 버그(`badge_rules.md` §4.3)의 재발 여부를 전수 검증했다.

| 검사 | 결과 |
|---|---|
| `compute_level(threshold[L]) = L`, L=1..60 | **60/60 일치** |
| `compute_level(threshold[L]−1) = L−1`, L=2..60 | **59/59 일치** |
| 경계값 | `compute_level(0)=1`, `(49)=1`, `(50)=2`, `(393409)=59`, `(393410)=60`, `(999999999)=60` |

정수 비교만 하므로 구조적으로 재발 불가능하다. Dart 쪽도 동일 단언을 테스트로 잠갔다.

### 4.3 시드 프로필 전수 재평가 (이전 라운드 대비)

| 프로필 | 27번 라운드 | **현재** | XP | 레벨 | 최장 주 스트릭 |
|---|---:|---:|---:|---:|---:|
| a8 ohsprint | 21 | **39** | 16,982 | 15 | 8 |
| a7 hanmara | 25 | **35** | 8,163 | 11 | 1 |
| a5 choitrack | 17 | **25** | 4,842 | 8 | 1 |
| a6 jungrunning | 15 | **23** | 4,446 | 8 | 1 |
| a4 yoonpace | 13 | **18** | 3,311 | 7 | 1 |
| a2 leedallim | 12 | **17** | 3,427 | 7 | 1 |
| a1 kimrunner | 10 | **15** | 2,711 | 7 | 1 |
| a3 parkjogging | 8 | **13** | 2,255 | 6 | 1 |
| 6c27 dev.tester | 0 | **1** | 100 | 2 | 0 |
| 4286 jehyun2220 | 0 | **1** | 100 | 2 | 0 |
| **합계** | **121** | **187** | | | |

> 27번 라운드(121) → 이번 작업 직전(136)의 +15는 이번 라운드가 아니라 마이그레이션 31~35(시즌 인스턴스 발급)의 결과다.
> **이번 라운드 순증가는 136 → 187 = +51.**

새로 지급되기 시작한 condition_type: `level_gte` **11건**, `streak_weeks_gte` **3건**.
`device_source_*` 는 0건 — 시드 러닝에 `device_vendors` 값이 없어서이고, **정상**이다
(실지급은 P1 웨어러블 연동 이후).

**대량 오지급 패턴 없음**을 확인했다. 지급 분포가 러닝 이력 규모에 비례한다.

### 4.4 새 로직 기능 검증 (임시 QA 사용자 2명, 검증 후 삭제 완료)

DB는 검증 전후로 `profiles 10 / runs 35 / user_badges 187` 동일하다.

**A. 스플릿 선형 보간** — 샘플 간격 60초(워치 동기화 시나리오), 전반 6:00/km · 후반 5:00/km

| 검사 | 기대 | 실제 |
|---|---|---|
| 1km 통과 시각 | 360.00s | **360.00** |
| 5km 통과 시각 | 1800.00s | **1800.00** |
| 10km 통과 시각 | 3300.00s | **3300.00** |
| 샘플 범위 밖(99,999m) | null | **null** |
| 전반/후반 평균 스플릿 | 360 / 300 | **360.00 / 300.00** |

무보간 근사였다면 60초 간격에서 최대 1분씩 틀어졌을 값이 정확히 나온다.

**B. 페이스 3종 최소 조건**

| 검사 | 결과 |
|---|---|
| 네거티브 스플릿, 11km 세션 | **true** |
| 네거티브 스플릿, 3km 세션(<4km 하한) | **false** |
| 마지막 1km 5% 가속, 11km | **true** |
| 마지막 1km 10% 가속, 11km | **false** (앞 구간 평균 330s × 0.9 = 297 < 300) |
| 마지막 1km, 4km 세션(<5km 하한) | **false** |
| CV, 스플릿 2개 | **null**(판정 불가) |
| CV, 스플릿 3개 균일 | **0.00** |

**C. 기기 벤더 파서 + 배열 겹침**

| 입력 | 기대 | 실제 |
|---|---|---|
| `watchApple` | `{watchApple}` | ✅ |
| `watchApple_or_watchGarmin` | `{watchApple,watchGarmin}` | ✅ |
| `phone_or_watchOther_or_unknown` | 3토큰 | ✅ |
| `watchapple` (대소문자 틀림) | null | ✅ |
| `watchApple_or_` (문법 오류) | null | ✅ |
| `watchWearOS` (불채택 토큰) | null | ✅ |
| `watch Apple` (공백) | null | ✅ |
| `{phone,watchApple}` vs `phone` | true | ✅ |
| `{phone,watchApple}` vs `watchApple_or_watchGarmin` | true | ✅ |
| `{}` vs `phone` | false | ✅ |

**하이브리드 세션 1건**(`{phone, watchApple}`)으로 **`device_watchApple_1` 과 `device_both_used` 가 동시에 지급**되는 것을
실제 뱃지 지급으로 확인했다 — 중재 문서 §3이 의도한 동작이다.
`watchGarmin` 조건은 같은 세션에서 `false` — 겹침이 무차별 매칭이 아님도 확인.

**D. 주간 스트릭 유예** — 활동 주 오프셋 0, 2·3·4·5, 7 (1과 6 결석)

| 항목 | 기대(수기 추적) | 서버 | 클라이언트 |
|---|---|---|---|
| `longest` | 6 | **6** | **6** |
| `current` | 0 | **0** | — |
| `freeze_credits` | 0 | **0** | — |
| `streak_xp` | 30+60+90+120+150+150 = 600 | **600** | — |
| `last_active_week` | 2026-W26 | **2026-W26** | — |

유예 없이 세면 최장 구간이 4주(오프셋 2~5)다. 6이 나온다는 것이 유예 2회 소모 + 1회 회복이
정확히 작동했다는 뜻이다. 지급 뱃지도 `strk_longest_2w`, `strk_longest_4w` 만(8w 미지급).

**활동 주 하한 검증**: 결석 주에 800m 러닝 1건을 추가해도 `longest` 가 6에서 변하지 않았다
(활동 주로 인정됐다면 0~5가 이어져 8이 됐어야 한다). 400m × 3회는 주 합산 1.2km로 통과.

**E. PB 상한 폐지 + 보간** — 12km 세션(300s/km, 500m 간격 샘플)

| 검사 | 기대 | 실제 |
|---|---|---|
| 10km PB | 3000s(보간) | **3000** |
| 5km PB | 1500s(12km 세션 보간이 직접 5km 세션 1800s보다 빠름) | **1500** |
| 42.2km PB | null | **null** |
| `pb_10km_sub50`(3000s) | true | **true** |
| `pb_10km_sub40`(2400s) | false | **false** |

구 로직(상한 115%)에서는 12km > 11.5km 라 10km PB 후보에서 통째로 제외됐다.

**F. 경로 클러스터링 300m** — 3그룹 배치(같은 지점 4건 / 1.1km 간격 5곳 / 100m 간격 3건)
→ `_route_cluster_count` = **7**. 100m 간격 3건이 1개로 묶이고(반경 300m 병합),
세 번째 지점이 첫 anchor 로부터 200m 인데도 새 클러스터를 만들지 않아 **anchor 미갱신**도 확인됐다.
`route_diverse_5` 지급, `route_diverse_10` 미지급.

**G. 음력 판정** — 2026-02-17(설날) 러닝 → `special_lunar_newyear` 지급.
`chuseok` 은 false(2026-09-25 러닝 없음). 룩업 30행, 중국 기준 날짜 0건.

**H. 최소 모집단** — 전 프로필 × 4티어 × 3버킷 전수 호출 결과 **전부 false**
(현재 티어별 모집단 1~4명 < 최소 10/20). 도메인 밖 버킷(`top5`)도 false + notice.
이미 지급된 `season_weekly_rank_lte` 3건은 **회수하지 않았다**(PRD §8.1, `evaluate_badges` INSERT 전용).

**I. 멱등성** — 전 프로필 `recompute_profile_stats` + `evaluate_badges` 를 한 번 더 돌린 뒤
`(total_xp, level, longest_streak_weeks, 뱃지 수)` 비교 → **변경 행 0개**.

### 4.5 최종 스키마 정합성

| 지표 | 기대 | 실제 |
|---|---|---|
| 뱃지 템플릿 수 | 146 | **146** |
| distinct `condition_type` | 39 | **39** |
| distinct `category` | 14 | **14** |
| `lunar_holidays` 행 | 30 | **30** |
| `evaluate_badge_condition` 내 `보류` 스텁 | 0 | **0** |
| `profiles` 신규 컬럼 5종 | 5 | **5** |
| 구 `total_points`/`awarded_points` 컬럼 | 0 | **0** |

---

## 5. TRD 갱신 (v0.5 → **v0.6**)

| 절 | 변경 |
|---|---|
| 헤더 | 버전 v0.6, 작성일 2026-08-26, 변경 이력 1행 추가 |
| §3.8.2 | `compute_run_xp` 실제 시그니처(활동유형 인자 포함) 명시 |
| §3.8.3 | `xp_level_thresholds()` 저장 방식과 `generate_subscripts` 조회 명시, CHECK 제약명 기재 |
| §3.8.4 | 트리거 3곳을 **실제 이름 표**로 교체, `runnit.badge_eval` 스킵 기전 설명, `challenges.reward_points` 제외 명시 |
| §4.0 | "backend-engineer 적용 대상" → **"✅ 적용 완료, 마이그레이션 36"** + 파서 헬퍼 언급 |
| **§4.2 (신설)** | 음력 룩업 테이블 DDL·RLS·2027/2028 회귀 대상·연휴 3일 미채택 사유 |
| **§4.3 (신설)** | `weekly_ranking_cache` ↔ `leaderboard_entries` 매핑표 + 확정 순위 정렬식 |
| §4.1 | 매핑표에 `total_xp`/`level`/`awarded_xp`/스트릭 4컬럼/`reached_at` 9행 추가 |
| §10.1 | "스텁 0개" 완료 노트 추가 |
| §10.2 | 표 전체가 구현됐음 + 헬퍼 목록 + 구현 노트 2건(클러스터 첫 매칭 / 리플레이 `least()` 가드) |
| §14 | #10 해소 처리, **#11~#14 신설** |

---

## 6. 정본과 의도적으로 다르게 구현한 지점 (전부 문서화됨)

| # | 지점 | 정본 | 구현 | 사유 |
|---|---|---|---|---|
| 1 | 랭킹 캐시 테이블 | `weekly_ranking_cache` 신설 | `leaderboard_entries` 에 `reached_at` 추가 | 라이브에 이미 같은 역할 테이블이 있고 §2.5 컬럼을 전부 갖췄다. 32/33번 판정이 이미 이 테이블을 읽는다. 새 테이블을 만들면 진실 원천이 둘이 된다 |
| 2 | 클러스터 편입 | "가장 가까운 c 에 편입" | 첫 매칭에서 멈춤 | anchor 를 갱신하지 않으므로 어디에 넣든 **개수가 동일**하고 반환값은 개수뿐이다. 결과가 정확히 같고 상수만 줄었다 |
| 3 | 리플레이 시작 주 | 가입 주 | `least(가입 주, 첫 활동 주)` | 시드/임포트 데이터는 러닝이 가입보다 앞선다(a8: 첫 러닝 6/30, 가입 8/21). 프로덕션 불변식(가입 ≤ 첫 러닝)에서는 결과가 동일 |
| 4 | `total_xp` 원천 | 4원천 | 4원천 (챌린지 항 제거) | 구 코드가 더하던 `challenges.reward_points` 는 XP 4원천에 없고 `points` 는 Phase 4 이름이다 |
| 5 | `season_first_long_distance` | (언급 없음) | 33번 그대로 유지(98%) | §5.1의 새 허용오차는 정본이 **PB 2종에 대해서만** 확정했다. 임의 확대하지 않고 미해결로 넘긴다 → §7 #3 |

---

## 7. 다음 라운드로 넘기는 것

| # | 항목 | 상태 | 담당 제안 |
|---|---|---|---|
| 1 | **`season_weekly_rank_lte` 12종이 실데이터로 미검증** | 판정 로직은 정확하지만 티어별 모집단이 1~4명이라 최소 조건(10/20)을 절대 못 넘는다. 시드로는 "항상 false"밖에 확인할 수 없다 | qa-integration-tester — 베타 20명 이상 확보 후 회귀 |
| 2 | **주간 랭킹 확정 배치가 `pg_cron` 에 없다** | 정본(§2.2)은 "매주 월요일 KST 00:10 = `10 15 * * 0` UTC". 현재는 마이그레이션 16의 기존 `refresh_all_leaderboards` 주기 스케줄에 의존해 **확정 시점이 스펙과 다르다**. 이번 범위가 아니라 손대지 않았다 | backend-engineer (Phase 2 랭킹 모듈) |
| 3 | **`season_first_long_distance` 거리 허용오차 불일치** | PB 2종은 `목표 − min(목표×2%, 300m)`, 이 시즌 조건은 고정 98%. 하프 기준이 20,800m vs 20,678m 로 갈린다 | gamification-designer 확인 후 backend |
| 4 | **XP-4(티어 XP)가 아무에게도 적립되지 않고 있다** | `tier_change_history` 0행. 마이그레이션 34가 "상승 이벤트만 기록"으로 정정하며 백필을 취소했고(소급 복원 불가는 의도된 결정), 기존 유저는 이번 시즌에 강등 없이 재상승할 기회가 없다. **2026-Q4 시즌 시작 시 자연 해소**되지만 그때까지 `total_xp` 는 XP-4 만큼 과소 집계 상태다 | 모니터링만 — 조치 불필요 |
| 5 | **`device_*` 뱃지 5종 실지급 미검증** | 판정은 QA 사용자로 검증했으나 실제 `device_vendors` 를 채우는 경로가 P1 웨어러블 연동이라 시드에는 값이 없다(`runs_with_vendors = 0`) | gps-tracking-engineer + qa (P1) |
| 6 | **`ARCHITECTURE.md` 미갱신** | 이번 라운드는 `TRD.md` 만 갱신했다. ARCHITECTURE §4(티어/랭킹 축 분리)·§6.2(하이브리드 세션)에 XP 축과 `leaderboard_entries` 실명 언급이 필요한지 검토 대상 | mobile-architect |
| 7 | **`AppUser` 에 스트릭 주 컬럼이 없다** | 서버는 `current_streak_weeks`/`longest_streak_weeks`/`streak_freeze_credits`/`streak_last_active_week` 를 내려주지만 Dart `AppUser` 에 대응 필드가 없어 `select *` 시 무시된다. 프로필 화면이 "이번 주 스트릭 N주 · 유예 1회 남음"을 표시하려면 모델 확장 필요 | mobile-architect + flutter-ui-designer |

---

## 8. QA 인계 — API 응답 shape 변경점

프론트 훅 교차 검증 시 **깨질 수 있는 필드**:

| 테이블 | 이전 키 | **현재 키** |
|---|---|---|
| `profiles` | `total_points` | **`total_xp`** |
| `runs` | `awarded_points` | **`awarded_xp`** |
| `profiles` | (없음) | `current_streak_weeks`, `longest_streak_weeks`, `streak_freeze_credits`, `streak_last_active_week` |
| `runs` | (없음) | `device_vendors` (`device_vendor[]`, **값 문자열 camelCase**) |
| `leaderboard_entries` | (없음) | `reached_at` |

`profiles.level` 의 값 범위가 **1~100 → 1~60** 으로 좁아졌다. UI가 100을 만렙으로 가정한 곳이 있으면 깨진다
(`LevelCurve.maxLevel` 은 60으로 맞췄고 하드코딩된 100은 코드베이스에 남아 있지 않다).

RPC 인터페이스 변경 없음 — `evaluate_badges`/`evaluate_badge_condition`/`recompute_profile_stats` 는
전부 `revoke execute` 상태로 클라이언트가 직접 부를 수 없다.

---

## 9. 커밋하지 않음

지시대로 `git commit` 하지 않았다. 작업 상태(마이그레이션 6개, 변경된 `lib/`·`test/` 코드, `docs/TRD.md`)를
그대로 두었으니 검토 후 커밋하면 된다. DB에는 이미 전부 적용돼 있다 —
파일과 DB가 어긋나지 않도록 마이그레이션 파일을 수정하지 말고 커밋할 것.
