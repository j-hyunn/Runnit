# 뱃지 시스템 백로그 — 최종 통합 검증 (QA)

검증: qa-integration-tester / 2026-08-26 04:27
대상: 마이그레이션 36~42 + 워킹 트리 미커밋 변경 9파일
Supabase: `xwtbwexcofcgmbvktwdo`

> **결론: 통과.** 기능 결함 0건. 경계면 4축(모델↔스키마, 카탈로그↔CHECK, 클라이언트↔서버 판정,
> XP/레벨)이 전부 일치하고, 회귀 3종(analyze / test / advisors)도 깨끗하다.
> 아래 8건은 전부 **주석·문서 정합성**이거나 **표시 계층의 경계 오차**이며, 커밋을 막을 이유는 없다.
> 다만 #1은 이번 라운드에 새로 쓰인 주석이 코드와 반대를 말하고 있어 커밋 전 정리를 권한다.

---

## 1. 통과 항목 (CONFIRMED PASS)

| # | 경계면 | 검증 방법 | 결과 |
|---|---|---|---|
| P1 | `device_vendor` 4계층 | `pg_enum` ↔ `enums.dart @JsonValue` ↔ `wire_enums.dart` ↔ `badges.condition` 토큰 | `{phone, watchApple, watchGarmin, watchOther, unknown}` — 대소문자·철자·개수·순서 완전 일치 |
| P2 | `RunRecord.deviceVendors` ↔ `runs.device_vendors` | `run_record.g.dart` 직렬화 + 컬럼 타입 | JSON 키 `device_vendors`, 값 camelCase 유지, `_device_vendor[]`. 왕복 무손실 |
| P3 | 카탈로그 ↔ DB 행수 | `badges` group by `season_id` | 템플릿 **146** = CSV 146행. + 2026-Q3 인스턴스 31 = 총 177. **차이 31은 시즌 인스턴스로 전량 설명됨** |
| P4 | `condition_type` 집합 | CSV ↔ `BadgeConditionType.all` ↔ 마이그 37 CHECK | 39종, **대칭차 0** |
| P5 | `category` 집합 | 마이그 37 CHECK ↔ `BadgeCategory` enum | 14종, **대칭차 0** |
| P6 | XP 레벨 곡선 | `xp_level_thresholds()` ↔ `LevelCurve.thresholds` 정수 비교 | **60개 전부 일치**. 추가로 60개 모두 `ceil(50×(L−1)^2.2)` 유도식과 일치. 경계 의미론도 동일(`xp<=0`→1, `xp>393410`→60) |
| P7 | 음력 30행 | Meeus ch.49 삭 계산 + ΔT 보정 + KST 변환으로 **독립 재계산** | 아래 §2 참조 — **30/30 정확** |
| P8 | 마이그 42 배포본 ↔ 파일 | `pg_get_functiondef` 라인별 md5 대조 | 본문 완전 일치(1~6행 키워드 대문자화는 pg 출력 형식). 41 대비 **기능 변경은 허용오차 2줄뿐**, 필터·분기 손실 없음 |
| P9 | 시드 조건 키 무결성 | 177행 × 판정 분기가 읽는 jsonb 키 존재 여부 | **누락 0건**. "키가 없어 NULL 캐스팅 → 조용히 false" 케이스 없음 |
| P10 | device 조건 파싱 | `_device_vendor_tokens()` 를 시드된 5건 전량에 실행 | 전부 파싱 성공. `device_both_used` → `{phone}` AND `{watchApple,watchGarmin}` |
| P11 | 트리거 배선 | `pg_trigger` | `runs_03_evaluate_badges`, `user_badges_02_recompute_xp`, `tier_change_history_01_recompute_xp` 전부 존재 — TRD §3.8.4 표와 일치 |
| P12 | XP 개명 전파 | DB 컬럼 ↔ Dart ↔ `.g.dart` ↔ `_serverOwnedKeys` ↔ UI | `total_points`/`awarded_points` **잔존 0**. `local_run_repository.dart:42`의 `_serverOwnedKeys`도 `awarded_xp`로 갱신됨 |
| P13 | TRD 스키마 주장 | 라이브 대조 | `profiles_level_range CHECK (level>=1 AND level<=60)` ✓ / 헬퍼 함수 10종 ✓ / `leaderboard_entries.reached_at`·`participant_count` ✓ / `tier_change_history` 0행(§14 #14 서술 정확) ✓ |
| P14 | 42번 백필 | `user_badges` 집계 | 재평가 루프 실제 수행됨 — `pb_first_achieved` 31, `session_distance_gte` 16, `level_gte` 11, `season_first_long_distance` 3, `streak_weeks_gte` 3 |
| P15 | 회귀 | 직접 실행 | `flutter analyze` **0건** / `flutter test` **91/91 통과** / `get_advisors(security)` **기존 4건 그대로, 신규 0건** (`lunar_holidays` RLS는 경고 유발 안 함) |

---

## 2. 음력 테이블 독립 검증 (P7 상세)

gamification-designer가 "중국 역법과 다르다"고 경고한 부분이라 **문서를 믿지 않고 재계산**했다.
Meeus 『Astronomical Algorithms』 49장 삭(New Moon) 급수 + Espenak/Meeus ΔT 다항식으로
2026~2040 삭 시각을 구해 KST(UTC+9)로 변환했다.

- **설날 15/15**: 전부 실제 삭이 든 날(음력 1일)이며, 동지월 기준 월 배열과도 일치.
- **추석 15/15**: 전부 `삭 + 14일`(음력 15일)에 정확히 대응.
- **⚠️ 경고 대상 2건 재현 확인**:
  - 2027 설날 — 삭 `02-07 00:56 KST` → 120°E 기준 `02-06 23:56`. **날짜가 갈린다.** 테이블의 `2027-02-07` 정확.
  - 2028 설날 — 삭 `01-27 00:12 KST` → 120°E 기준 `01-26 23:12`. **날짜가 갈린다.** 테이블의 `2028-01-27` 정확.
  - 두 해 모두 삭이 KST 자정 직후 1시간 이내에 들어 마이그레이션 38 주석의 설명이 천문학적으로 정확하다.
- **2033 윤달("2033 문제") 처리 확인**: 2033 동지월 이후 삭이 `11-22 → 12-22(윤11월) → 01-20 → 02-19`로 이어져
  설날 2034 = **동지월 기준 3번째 삭 = 2034-02-19**. 테이블 값과 일치. 설날2033→설날2034 간격 384일(13삭망월)로 윤년 확인.
- 룩업 방식 채택 판단 자체가 타당함을 확인. 범용 음력 라이브러리를 썼다면 2027·2028이 하루씩 틀렸을 것.

---

## 3. 발견 사항 (severity 순)

### [CONFIRMED] #1 — MEDIUM · 코드와 반대를 말하는 주석 (이번 라운드에 새로 작성됨)

- 파일: `lib/features/gamification/domain/badge_condition.dart:162-165`
- 이번 라운드 diff에서 새로 쓰인 주석이다:
  ```dart
  default:
    // levelGte(서버 XP 4원천), streakWeeksGte(유예 리플레이),
    // deviceSource*(runs.device_vendors), season_* 집계류(랭킹/티어/주차 전역) 등 —
    // 서버 전용. districtDiversityGte는 2026-08-26 카탈로그에서 삭제됐다.
    return BadgeEvaluability.serverOnly;
  ```
  그런데 이 주석이 "서버 전용"이라고 지목한 4개 중 **3개(`streakWeeksGte`, `deviceSourceCountGte`,
  `deviceSourceDiversityGte`)는 바로 위에서 명시적으로 `clientEstimable`로 분류돼 있다.**
  실제로 `default`에 도달하는 건 `levelGte` 하나뿐.
- **어느 쪽이 옳은가 → 코드가 옳다.** 이번 라운드에 추가된
  `GamificationStats.computeWeeklyStreak`(`gamification_stats.dart`)가 서버 `_weekly_streak_state`와
  1:1 대응하는 **클라이언트 계산**으로 명시 작성됐고, `RunRecord.deviceVendors`도 로컬에 있다.
  즉 분류는 의도대로이고 **주석만 틀렸다.**
- 동작 영향: **없음**(`currentValueFor`가 이 3종에 대해 어차피 null 반환).
  하지만 다음 작업자가 "이건 서버 전용이니까 클라 계산 붙이지 말자"고 잘못 판단할 소지가 크다.
- 제안: 주석에서 `streakWeeksGte`·`deviceSource*`를 빼고 `levelGte`와 `season_*`만 남긴다.

### [CONFIRMED] #2 — LOW~MEDIUM · 마이그 42 허용오차가 클라이언트 진행률에 반영되지 않음

- 파일: `lib/features/gamification/domain/badge_progress.dart:166`(`currentValueFor`), `:213`(`ratioFor`)
  ↔ 마이그레이션 42 `session_distance_gte` 분기
- 서버는 이제 `목표 − min(목표×2%, 300m)`에서 지급하지만 클라이언트 진행률은 `현재/목표` 그대로다.
  실측 괴리:

  | 뱃지 | 목표 | 서버 지급 시작 | 그 순간 클라 진행률 |
  |---|---|---|---|
  | `session_dist_10km` 텐런 | 10km | 9.8km | **98.00%** |
  | `session_dist_15km` 롱런 | 15km | 14.7km | **98.00%** |
  | `session_dist_half` 하프런 | 21.1km | 20.8km | **98.58%** |
  | `session_dist_full` 풀런 | 42.2km | 41.9km | **99.29%** |
  | `session_dist_ultra50` 울트라런 | 50km | 49.7km | **99.40%** |

- **완화 요인 2개**: ① `forBadge`가 `ratio: isEarned ? 1.0 : ...`이라 서버 획득이 내려오면 즉시 1.0으로 스냅된다
  → 괴리는 "업로드 후 뱃지 재조회 전"까지의 짧은 구간에 한정되고 자가 치유된다.
  ② 허용오차를 쓰는 3종 중 `pbFirstAchieved`(default→null)·`seasonFirstLongDistance`(clientPartial→null)는
  클라이언트가 값을 내지 않으므로 **영향은 `sessionDistanceGte` 1종뿐.**
- 다만 `sessionDistanceGte`는 클라이언트가 실제로 계산하는 4종 중 하나라 **도달 가능한 경로**이고,
  오프라인 상태에서는 "9.85km 달렸는데 98.5%에서 멈춰 있음"이 지속된다.
- 제안(택1): ⓐ `ratioFor`에 허용오차 3종용 유효목표(`target − min(target×0.02, 0.3)`)를 적용,
  또는 ⓑ 클래스 doc의 "추정이 틀릴 수 있는 지점" 목록에 이 항목을 명시.
  **로직 변경이므로 이번 커밋에서는 손대지 말고 별건으로 처리 권장.**

### [CONFIRMED] #3 — LOW~MEDIUM · TRD §4.1이 같은 문서 §4.3과 모순

- 파일: `docs/TRD.md:700-701`
  ```
  | `RankingEntry.weeklyDistanceMeters` | `weekly_ranking_cache.weekly_distance_m`   | numeric |
  | `RankingEntry.tierParticipantCount` | `weekly_ranking_cache.tier_participant_count` | integer |
  ```
- 라이브 대조 결과 **3중 오류**:
  - `to_regclass('public.weekly_ranking_cache')` = **null** — 그런 테이블 없음
  - Dart에도 `weeklyDistanceMeters`/`tierParticipantCount` 필드 없음 (실제는 `score`, `participantCount`)
  - 이번 라운드에 **바로 5줄 위(§4.3, TRD:676)** 에 "라이브 실제 이름은 `leaderboard_entries`"라고
    올바르게 추가해 놓고, 정작 매핑표는 안 고쳤다 → 한 문서 안에서 상충
- §4.1은 개발자·QA가 실제로 참조하는 표라 우선순위가 높다.
- 참고: 같은 표의 `RunRecord.* → run_records.*` 행들도 라이브 테이블명 `runs`와 다르다(기존 이슈,
  TRD:600에 "초안이며 라이브는 `public.runs`"라는 노트는 있음).
- 제안: §4.1의 `weekly_ranking_cache` 2행을 `leaderboard_entries.score` / `.participant_count`로 교체.

### [CONFIRMED] #4 — LOW · Dart 주석의 낡은 개수 (4파일 6곳)

| 파일:라인 | 현재 서술 | 실제 |
|---|---|---|
| `lib/models/enums.dart:163` | "16개 카테고리 … (158종)" | 14개 카테고리 / 146종 |
| `lib/models/badge.dart:11` | "(158종 / 16카테고리)" | 146종 / 14카테고리 |
| `lib/models/badge.dart:38` | "1:1 (현재 40종)" | 39종 |
| `badge_condition.dart:3` | "(158종)" | 146종 |
| `badge_condition.dart:39` | "1:1 (40종)" | 39종 |
| `badge_condition.dart:130` | "client 18 · partial 7 · server 15" | **21 · 7 · 11** |

- 전부 순수 주석이며 동작 영향 없음. 오타 수준이므로 커밋 전 일괄 수정해도 무방.

### [CONFIRMED] #5 — LOW · 마이그 42가 41의 근거 주석을 통째로 소실시킴

- 파일: `supabase/migrations/20260826040000_42_unify_distance_tolerance.sql`
- 42는 `pg_get_functiondef` 출력 형식으로 함수를 재정의했는데, 그 과정에서 41이 담고 있던
  **약 60줄의 판정 근거 주석이 1줄만 남고 전부 사라졌다**(배포본에도 동일하게 1줄만 존재).
  소실된 것 중 운영상 중요한 것들:
  - `season_weekly_rank_lte`의 최소 모집단(top1 N≥10 / 나머지 N≥20)을 **왜** 두는가 (참가상 방지 논리)
  - `loop_course_count_gte`의 150m/2.0km/샘플10 각 임계값의 근거
  - `device_source_*`의 "배열 겹침 단일 규칙 / 서로 다른 세션 제약 없음" 명시
- 41이 git에 남아 있어 복구는 가능하지만, **최신 정의(42)를 읽는 사람은 근거를 못 본다.**
- 제안: 다음 함수 재정의 시 41의 주석 블록을 되살릴 것. (이번 커밋에서 42를 고칠 필요는 없음)

### [CONFIRMED] #6 — LOW · 이번 라운드에 추가한 계산기가 미배선

- 파일: `lib/features/gamification/domain/gamification_stats.dart`(신규 `computeWeeklyStreak`)
  ↔ `lib/features/gamification/domain/badge_progress.dart:174-179`
- `computeWeeklyStreak`/`computeLongestStreakWeeks`가 새로 추가됐지만 `currentValueFor`의
  switch에 연결되지 않아 `streak_weeks_gte` 진행률은 여전히 null이다.
  그리고 `badge_progress.dart:174` 주석은 아직도 "streakWeeksGte … GamificationStats가 아직
  이 값들을 수집하지 않는다"라고 적혀 있다 — 이제 수집은 하는데 배선만 안 된 상태.
- 동작 결함은 아니다(진행률 바가 안 뜰 뿐, 획득 판정은 서버). 후속 작업 항목.

### [CONFIRMED] #7 — TRIVIAL · TRD §14 행 순서

- `docs/TRD.md:1020-1024` — 11, 12, ~~13~~, **~~15~~, 14** 순. 15가 14보다 앞에 있다.
- 지적하신 #13/#15의 "해소" 표기 **내용 자체는 정확**하다(배포본에 `0.98` 잔존 0, 허용오차 3곳 적용 확인).
  §10.2에 추가한 `session_distance_gte` 행도 정확하다 — "대상 필터(완주·비플래그)는 유지"가
  배포된 SQL과 정확히 일치한다(실내 제외 조건 없음).

### [PLAUSIBLE] #8 — LOW~MEDIUM · 실내 러닝 취급의 비대칭 (설계 판단 필요, 결함 아님)

- `session_distance_gte`에는 `activity_type <> 'indoor_run'` 필터가 **없고**,
  `pb_first_achieved`·`season_first_long_distance`에는 **있다.**
- 마이그 42가 이 셋을 "같은 목표 거리 도달 판정"이라고 선언하며 허용오차를 통일했는데,
  실내 취급은 통일하지 않았다. 결과: 트레드밀 42.2km는 `session_dist_full`(풀런)은 받지만
  같은 거리의 시즌 뱃지·PB 뱃지는 못 받는다.
- PRD §8.3이 실내·수동을 누적 통계에 반영하도록 확정했으므로 **현행이 틀렸다고 단정할 수 없다**
  (단일세션거리는 누적계, PB/시즌은 경쟁계로 볼 여지가 있음). 그래서 PLAUSIBLE로 둔다.
- 제안: gamification-designer에게 "42의 통일 범위에 실내 필터도 포함시킬 것인가"를 확인.
  확인 전까지 코드는 건드리지 않았다.

---

## 4. 재현 불가 / 미검증

| 항목 | 사유 |
|---|---|
| `device_source_*` 실지급 | `runs.device_vendors`가 전 행 `{}` (시드 러닝 35건은 `sources='{}'`라 백필 0건 — 정상). P1 웨어러블 연동 후 검증 필요. TRD §14 #10과 일치 |
| `season_weekly_rank_lte` 12종 | 최소 모집단(N≥10/20) 미달로 지급 0. 판정식은 코드 리뷰로만 확인. TRD §14 #11과 일치 |
| `calendar_date_match` 음력 2종 실지급 | 시드 러닝이 설날·추석 당일에 없음. 룩업 데이터 정확성은 §2에서 독립 검증 완료 |
| XP-4(티어 XP) | `tier_change_history` 0행. TRD §14 #14가 이미 정확히 문서화 |

---

## 5. 요약

- **통과 15항 / 결함 0건 / 주석·문서 이슈 7건 / 설계 확인 요청 1건**
- 커밋 차단 사유 없음. 커밋 전 정리를 권하는 것은 **#1(주석이 코드와 반대)** 하나이고,
  나머지는 별건 처리해도 무방하다.
- #2(허용오차 미반영)와 #8(실내 비대칭)은 **로직 변경**이라 이번 검증에서는 손대지 않고 보고만 한다.
