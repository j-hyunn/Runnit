# Runnit 백엔드 — 게이미피케이션 확정 규칙 반영 보고서

- 작성: backend-engineer
- 일자: 2026-08-20
- 입력 스펙: `_workspace/20260819_210450_badge_rules.md` (v1.0 확정), `_workspace/20260819_210450_badge_catalog_seed.json`
- 선행 스키마 문서: `_workspace/20260819_132600_backend_schema.md` (v1.0) — **이 문서가 그 증분 보고서다. 원본은 수정하지 않았다.**
- 적용 범위: **로컬 마이그레이션 파일 작성까지.** 원격 Supabase 프로젝트에는 적용하지 않았다(사용자 승인 필요).
- 검증: 이 환경에 psql / Supabase CLI / Docker 가 없어 **SQL 실행 검증을 하지 못했다.** §5 리스크 참조.

---

## 1. 신규 마이그레이션 파일

기존 8개 마이그레이션 파일은 **한 줄도 수정하지 않았다.** 모두 증분 파일로 반영했다
(`CREATE OR REPLACE FUNCTION` / `ALTER TABLE ADD CONSTRAINT` / 트리거 재생성).

| 파일 | 내용 |
|---|---|
| `supabase/migrations/20260819220000_08_badge_criteria_check.sql` | `badges.criteria_type` CHECK 제약 (12종) |
| `supabase/migrations/20260819220100_09_badge_seed.sql` | 뱃지 29종 시드 (재실행 가능, `points` 는 갱신 제외) |
| `supabase/migrations/20260819220200_10_points_and_level.sql` | `compute_awarded_points` / `compute_level` 본문 교체, `trg_runs_guard` 호출부 갱신, `recompute_profile_stats` 정합성 수정 |
| `supabase/migrations/20260819220300_11_leaderboard_tiebreak.sql` | `refresh_leaderboard()` 의 `tie_break_value` 지표별 분기 |
| `supabase/migrations/20260819220400_12_challenge_progress.sql` | `recompute_challenge_progress()`, `transition_challenge_statuses()`, 참가 트리거 함수 |
| `supabase/migrations/20260819220500_13_evaluate_badges.sql` | `evaluate_badges()`, runs AFTER 트리거 3종 순서 확정, 백필 |

---

## 2. 규칙서 7개 항목 대비 반영 결과

| # | 규칙서 항목 | 반영 파일 | 규칙서 그대로? | 비고 |
|---|---|---|---|---|
| 1 | `criteria_type` CHECK 12종 (§1.1) | `08_badge_criteria_check.sql` | **그대로** | 반영 위치만 다름: 규칙서는 `02_gamification.sql` 수정을 지시했으나, 이미 작성된 마이그레이션은 건드리지 않는 원칙에 따라 `ALTER TABLE ADD CONSTRAINT` 증분으로 처리 |
| 2 | 뱃지 29종 시드 (§1.2) | `09_badge_seed.sql` | **그대로** | JSON 29종 전량. `ON CONFLICT (id) DO UPDATE` 에서 `points` 만 제외 |
| 3 | `evaluate_badges(uuid, uuid)` (§1.1 비교분기 + §2.2 전량 재평가) | `13_evaluate_badges.sql` | **그대로** | 페이스 NULL 함정은 `v_current IS NOT NULL AND v_current <= threshold` 로 명시. 비페이스 지표도 `IS NOT NULL AND >=` 로 통일(§2.2 의사코드와 동일) |
| 4 | 포인트 산식 (§3.1) | `10_points_and_level.sql` | **수식은 그대로**, 시그니처는 확장 | ↓ §3-A |
| 5 | 레벨 산식 (§4.1) | `10_points_and_level.sql` | **그대로** | `numeric` 계산(§4.3). 지수는 `1.0/1.6` 대신 동치인 리터럴 `0.625` 사용. 역함수는 서버에 구현하지 않음(§4.3 권고) |
| 6 | `tie_break_value` 지표별 (§5.1) | `11_leaderboard_tiebreak.sql` | **그대로** | `duration`/`run_count` 만 `-1 * sum(distance_meters)`. `distance`/`points` 현행 유지 |
| 7 | `recompute_challenge_progress(uuid, uuid)` (§6) | `12_challenge_progress.sql` | **그대로 + 보완 1건** | `joined_at` 필터 없음(§6.2), `upcoming`/`active` 만 대상(§6.3), `end_at + 24h` 유예는 `transition_challenge_statuses()` 에 구현. ↓ §3-C |

---

## 3. 규칙서를 그대로 옮기지 않고 **판단을 넣은 3곳**

### A. `compute_awarded_points` 시그니처 — 3인자 → 5인자 오버로드 추가

확정 산식은 페이스 보너스와 고도 보너스를 포함하므로 `moving_seconds` 와
`elevation_gain_meters` 없이는 구현이 불가능하다. 기존 3인자 함수를 지우지 않고
**5인자 오버로드를 정본으로 추가**하고, 3인자 함수는 5인자에 `NULL` 을 넘기는
래퍼로 남겼다(구 호출부 호환). 실제 호출부인 `trg_runs_guard` 는 5인자를 쓰도록 갱신했다.

규칙서 §3.1 이 "시그니처가 다르면 호출부에서 인자만 맞춰주면 된다"고 허용한 범위 안이다.

방어 코드 1건 추가: 고도 보너스에 `greatest(..., 0)`. 기압계 오류로 `elevation_gain_meters`
가 음수로 들어오면 `floor()` 가 음수 점수를 만들어 총점을 깎기 때문이다.

### B. `recompute_profile_stats` 의 `total_points` 정의 변경 — **버그 수정**

규칙서에 명시되지 않았지만, 그대로 두면 확정 규칙이 작동하지 않는 충돌이 있었다.

- 기존 함수: `total_points = sum(runs.awarded_points)` **만**.
- 규칙서 §2.2 / §6.4: `evaluate_badges` 와 `recompute_challenge_progress` 가
  뱃지 포인트·챌린지 보상 포인트를 `profiles.total_points` 에 **가산**한다.
- 충돌: 다음 러닝 업로드 때 `recompute_profile_stats` 가 러닝 포인트만으로 덮어써서
  가산분이 전부 사라진다 → **레벨이 내려간다.**

확정 정의:

```
total_points = sum(runs.awarded_points)            -- completed AND NOT flagged
             + sum(획득한 badges.points)
             + sum(완주한 challenges.reward_points)
```

트리거 순서(01 stats → 02 challenge → 03 badges)상 이 함수가 먼저 돌고 이후 단계가
"새로" 획득한 분만 증분 가산하므로 이중 계상되지 않는다.

함께 수정: 스트릭 일자 귀속을 `coalesce(ended_at, started_at)` → **`started_at`** 으로 변경
(규칙서 §2.3 명시 규약). `last_run_at` 은 의미상 종료 시각이 자연스러우므로 그대로 뒀다.

### C. 챌린지 보상 뱃지의 포인트 가산

규칙서 §6.4 의사코드는 `reward_badge_id` 뱃지를 INSERT 하되 포인트는 더하지 않는다.
그러나 B에서 `total_points` 가 "획득 뱃지 points 합"을 포함하도록 바뀌었으므로,
여기서 더하지 않으면 **다음 러닝 업로드 시점에 포인트가 뒤늦게 튀어오르는** 불일치가 생긴다.
INSERT 가 실제로 일어났을 때만(`ROW_COUNT > 0`) 해당 뱃지의 `points` 를 가산하도록 했다.

---

## 4. 트리거 실행 순서 보장 방법

Postgres 는 같은 테이블·같은 이벤트의 트리거를 **이름 알파벳순**으로 실행한다.
기존 트리거 `runs_recompute_stats` 를 DROP 하고, 세 트리거를 **공통 접두사 + 2자리 번호**로
재생성했다. 접두사가 `runs_0N_` 로 동일해 콜레이션과 무관하게 숫자 자리에서 순서가 결정된다.

| 순서 | 트리거 이름 | 함수 | 하는 일 |
|---|---|---|---|
| 1 | `runs_01_recompute_stats` | `trg_runs_recompute_stats()` | `profiles` 캐시 갱신 (`total_*`, `longest_streak_days`, `level`) |
| 2 | `runs_02_challenge_progress` | `trg_runs_challenge_progress()` | 참가 챌린지 진척 + 완주 확정(보상 포인트/뱃지) |
| 3 | `runs_03_evaluate_badges` | `trg_runs_evaluate_badges()` | 1·2 결과를 읽어 미획득 뱃지 전량 재평가 |

순서가 뒤집히면 `evaluate_badges` 가 갱신 전 캐시와 `completed_at` 을 읽어
마일스톤이 **한 세션씩 밀려서** 지급된다(규칙서 §2.1, §7-B1).

BEFORE 트리거 `runs_guard`(05 파일)는 그대로 먼저 돈다 — `is_flagged` 와 `awarded_points`
가 확정된 뒤에 위 세 개가 실행되는 구조는 변하지 않았다.

추가 트리거: `challenge_participations_recompute` (AFTER INSERT) — 규칙서 §6.3 의
"참가 시에도 1회 호출"을 구현한다. 이게 없으면 §6.2 의 "참가 즉시 과거 기록 반영"이 성립하지 않는다.
재귀 위험 없음(INSERT 에만 걸리고 함수는 UPDATE 만 수행).

---

## 5. 백필

`13_evaluate_badges.sql` 마지막 `DO` 블록에 포함했다. 순서:

1. `runs` 트리거를 잠시 끄고(`alter table ... disable trigger user`) 모든 러닝의
   `awarded_points` 를 새 5인자 산식으로 재계산 → 트리거 연쇄 발화 방지
2. 트리거 재활성화
3. 프로필별로 `recompute_profile_stats` → `recompute_challenge_progress` → `evaluate_badges`
   → `recompute_profile_stats`(가산분 확정) 순서로 1회 실행
4. `refresh_all_leaderboards()` 로 리더보드 재집계

> **운영 주의:** 러닝 데이터가 이미 대량으로 쌓인 환경이라면 이 `DO` 블록을 마이그레이션에서
> 떼어내 점검 시간대에 별도 배치로 돌릴 것. 현재는 신규 프로젝트 전제라 그대로 뒀다.

---

## 6. 필드 매핑 (이번 변경분)

이번 작업은 새 컬럼을 만들지 않았으므로 Dart ↔ Postgres 매핑에 **변경이 없다.**
서버 함수의 값이 흘러가는 기존 컬럼만 정리한다.

| Dart 필드 | Postgres 컬럼 | 이번 변경의 영향 |
|---|---|---|
| `RunRecord.awardedPoints` | `runs.awarded_points` | 값 산식 변경(§3.1). 컬럼/타입 동일 |
| `AppUser.totalPoints` | `profiles.total_points` | **정의 변경**: 러닝 + 뱃지 + 챌린지 보상 합 |
| `AppUser.level` | `profiles.level` | 산식 변경(체증형, 상한 100) |
| `AppUser.longestStreakDays` | `profiles.longest_streak_days` | 일자 귀속이 `started_at` 기준으로 변경 |
| `RankingEntry.tieBreakValue` | `leaderboard_entries.tie_break_value` | `duration`/`run_count` 에서 **음수** 저장. UI 노출 금지 |
| `UserBadge.*` | `user_badges.*` | 서버 자동 INSERT 경로 신설(클라이언트 INSERT 경로는 여전히 없음) |
| `ChallengeParticipation.progressValue` / `completedAt` | `challenge_participations.progress_value` / `completed_at` | 서버 자동 갱신 경로 신설 |

---

## 7. 검증하지 못한 것 / 리스크

| # | 리스크 | 심각도 | 근거 / 완화 |
|---|---|---|---|
| R1 | **SQL 문법·실행 미검증.** psql / Supabase CLI / Docker 가 없어 한 줄도 실행해보지 못했다 | 높음 | 원격 적용 전 반드시 Supabase 브랜치(`create_branch`)나 로컬 CLI 에서 `08~13` 순차 적용을 1회 돌려볼 것 |
| R2 | `count(*) FILTER (...)` 캐스팅, `CASE <enum변수>` 분기, `DO` 블록 내 `ALTER TABLE` 등 파서 의존 구문이 여럿 있다 | 중 | 괄호로 감싸 모호성을 줄였으나 실행 검증 전까지 확정 불가 |
| R3 | `power(numeric, 0.625)` 경계값. 규칙서 §4.3 이 지적한 부동소수 문제 | 중 | `numeric` 으로 계산했고 규칙서 검산표(레벨 2/3 경계 1516pt)를 손으로 재검산해 일치 확인. 다만 **레벨 1~100 전 구간 전수 검증은 못 했다** — 적용 후 `select l, public.compute_level(ceil(500*power(l-1,1.6))::int) from generate_series(1,100) l;` 로 확인할 것 |
| R4 | `total_points` 정의 변경(§3-B)은 규칙서에 없는 판단이다. gamification-designer 재확인 필요 | 중 | 확인하지 않으면 뱃지 포인트가 다음 러닝에서 소멸하는 기존 버그가 남는다 |
| R5 | `runs` UPDATE 마다 AFTER 트리거 3종이 모두 발화한다. 러닝 중 실시간 upsert(status=`recording`)가 잦으면 프로필 전량 재집계가 반복된다 | 중 | 기존 구조에서 이미 1종은 그러했다. 개선안: `status='completed'` 로 전이될 때만 발화하도록 `WHEN` 절 추가 — 이번 범위 밖이라 넣지 않았다 |
| R6 | 백필 `DO` 블록이 대량 데이터에서 장시간 잠금을 유발할 수 있다 | 중 | §5 운영 주의 참조 |
| R7 | `transition_challenge_statuses()` 를 pg_cron 에 등록하지 않으면 챌린지가 영원히 `upcoming` 에 머물러 §6.3 필터가 무의미해진다 | 높음 | 원격 적용 시 함수 주석의 `cron.schedule` 을 리더보드 갱신과 함께 등록할 것 (규칙서 §7-B5) |
| R8 | 뱃지 아이콘 에셋 `assets/badges/*.png` 29개가 없다 | 낮음 | flutter-ui-designer 작업 필요 (규칙서 §7-B4) |
| R9 | `get_advisors` 보안/성능 점검을 돌리지 못했다(원격 미적용) | 중 | 원격 적용 직후 반드시 실행 |

---

## 8. 다음 담당자에게

- **qa-integration-tester**: `evaluate_badges` 의 페이스 뱃지 NULL 경로(5km 미만만 뛴 사용자가
  페이스 뱃지 4종을 받지 않는지), 트리거 순서(첫 러닝에서 `first_run` 이 같은 트랜잭션에
  지급되는지), `tie_break_value` 음수 경로를 우선 검증 대상으로 잡을 것.
- **gamification-designer**: §3-B(`total_points` 정의)와 §3-C(보상 뱃지 포인트 가산)가
  의도와 맞는지 확인 요청.
- **원격 반영**: 사용자 승인 후 `08 → 09 → 10 → 11 → 12 → 13` 순서로만 적용할 것.
  `13` 은 `12` 의 `trg_participation_recompute()` 와 `evaluate_badges` 양쪽에 의존한다.
