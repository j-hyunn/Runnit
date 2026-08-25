# 뱃지 판정 로직 구현 — 적용 완료 보고

작성: backend-engineer / 2026-08-25
대상 프로젝트: Supabase `xwtbwexcofcgmbvktwdo`
기준 문서: `_workspace/20260825_181914_backend_badge-v2-migration.md` §5/§7.2 ·
`_workspace/20260825_architect_badge-model-v2.md` §4 · `lib/features/gamification/domain/badge_condition.dart` ·
`docs/badge-catalog.csv` · `docs/TRD.md` §3.6/§5/§10

작업 위치: 공유 체크아웃 `/Users/jehyun/Runnit/.claude/worktrees/phase-0-start-0f9ff3`(격리 worktree 아님 — `lib/`·`pubspec.yaml` 등이 이 체크아웃에만 untracked로 존재하기 때문).

---

## 1. 적용한 마이그레이션

| 파일 | 이름 | 상태 |
|---|---|---|
| `supabase/migrations/20260825190000_27_badge_evaluation_logic.sql` | `27_badge_evaluation_logic` | ✅ 적용 |

새 헬퍼 함수 6개(`_haversine_meters`, `_run_km_split_seconds`, `_run_negative_split`,
`_run_final_km_faster_pct`, `_run_pace_variance_pct`) + `evaluate_badge_condition`/`evaluate_badges`
재작성. 둘 다 `EXECUTE`는 `postgres`/`service_role`만(anon/authenticated 회수 — 변경 없음).

---

## 2. 이번에 구현한 condition_type (21종)

| condition_type | 판정 로직 요지 |
|---|---|
| `cumulative_distance_gte` | `profiles.total_distance_meters >= distanceKm*1000` |
| `cumulative_count_gte` | `profiles.total_run_count >= count` |
| `session_distance_gte` | 완료·비플래그 세션 중 `distance_meters >= distanceKm*1000` 존재 |
| `session_duration_gte` | 동상, `moving_seconds >= seconds` |
| `session_start_hour_count_gte` | `after`/`before`/`between`/`weekdayOnly` 조합, KST 로컬시각 매칭 건수 |
| `weekday_full_week_count_gte` | ISO 주(KST) 중 월~금 모두 러닝이 있었던 주의 개수 |
| `weekend_both_days_count_gte` | 동상, 토·일 모두 |
| `day_of_week_count_gte` | 특정 요일(`MON` 등) 러닝 건수 |
| `day_of_week_diversity_gte` | distinct 요일 수 |
| `route_diversity_count_gte` | 시작점(샘플[0] 위경도) distinct 클러스터 수 — 가정: 소수 3자리(~100m) 반올림 |
| `elevation_gain_cumulative_gte` | `sum(elevation_gain_meters)` |
| `loop_course_count_gte` | 출발-도착 haversine 거리 ≤200m + 거리 ≥1km 인 세션 수 |
| `calendar_date_match` | 양력 고정일(`MM-DD`) + `type=birthday`(profiles.birth_date). **음력(`chuseok`/`lunar_newyear`) 2건은 그대로 false** |
| `membership_anniversary_run` | `profiles.created_at` 기준 연차·MM-DD 매칭 |
| `pace_avg_lte` | `avg_pace_sec_per_km <= secPerKm` 세션 존재 |
| `pace_negative_split_count_gte` | 신규 `_run_km_split_seconds` 기반 후반<전반 판정 건수 |
| `pace_final_km_faster_pct_gte` | 동일 헬퍼, 마지막 1km이 나머지 평균보다 pct% 이상 빠른 세션 존재 |
| `pace_variance_lte` | 동일 헬퍼, km 스플릿 변동계수(CV%) ≤ pct |
| `pb_first_achieved` | 실외(`activity_type<>'indoor_run'`)·검증통과 세션 중 목표거리의 98% 이상 존재 |
| `pb_time_lte` | 동일 필터 + 거리 [98%,115%] 구간에서 `min(moving_seconds) <= seconds` |
| `streak_weeks_gte` | **신규 함수** — KST ISO 주 단위 최장 연속 스트릭(유예 없음) |

`streak_weeks_gte`는 지시서대로 신규 구현했다. 기존 `recompute_profile_stats`의
`current_streak_days`/`longest_streak_days`는 **일 단위**라 그대로 못 쓴다 — 별도로
`evaluate_badge_condition` 내부에서 주 단위 gaps-and-islands 쿼리를 새로 짰다(주별 프로필
캐시 컬럼을 새로 만들지는 않았음 — 평가 시점 계산이라 스키마 변경 없이 가능했다).

---

## 3. 계속 스텁(false)으로 남긴 것 — 지시서 명시분 (5개 그룹)

| condition_type | 이유 |
|---|---|
| `level_gte`(9종) | GM-04 XP/레벨 공식 미정 |
| `scope='seasonal'` 19개 condition_type(41종 템플릿) | `seasons`/`user_season_tier`/`weekly_ranking_cache` 테이블 없음 |
| `district_diversity_gte`(2종) | 역지오코딩 소스 미정(§7.1) |
| `device_source_diversity_gte`(1종) | `"watchApple_or_watchGarmin"` OR 표현식 파서 규약 미정 |
| `calendar_date_match`의 `date='chuseok'`/`'lunar_newyear'` (같은 condition_type 내 2건) | 음력 변환 함수/데이터 없음 |

`evaluate_badges`의 스코프 필터(`scope='permanent' or (scope='seasonal' and season_id is not null)`)가
현재 모든 seasonal 행을 자동으로 걸러내므로(전부 `season_id is null` 템플릿),
seasonal 19종은 실질적으로 이중 차단된다 — 방어적으로 `evaluate_badge_condition`에도 명시 분기를 남겼다.

---

## 4. 이번 라운드에서 새로 발견한 차단 사유 — `device_source_count_gte`(4종)

**지시서의 차단 목록에는 없었지만 구현 중 발견한 진짜 데이터 부재.**
`run_sample_source` enum이 `phone`/`watch`/`external` 3종뿐이고, `runs.sources`도 이 enum의
배열이다. Apple Watch와 Garmin을 구분할 컬럼이 DB 어디에도 없다(`samples` jsonb의
`RunSample.source`도 동일 enum). 카탈로그 조건은 `{"source":"watchApple","count":1}` 같은
값을 요구하는데 원천 데이터가 없어 판정 불가능하다.

→ **`device_source_count_gte`도 false 스텁으로 남겼다.** 해결하려면 gps-tracking-engineer가
워치 브랜드를 기록하는 컬럼(예: `runs.device_vendor` 또는 샘플 내 vendor 키)을 추가해야 한다.
`device_source_diversity_gte`(OR 표현식)와 근본 원인이 겹치므로 두 조건을 함께 다음 라운드로
넘기는 편이 효율적이다.

---

## 5. 검증

### 5.1 개별 조건 유닛 테스트 (SQL, 실제 시드 프로필/러닝 데이터)

프로필 `...a8`(러닝 25건, 10.5km×23 + 3km + 8km, 실외, 페이스 ~309.5초/km, GPS 샘플 없음)로
26개 케이스를 직접 호출해 대조:
`cumulative_distance_gte`/`cumulative_count_gte`(true/false 각각), 차단 5종(모두 false),
`pb_first_achieved`/`pb_time_lte`(경계값 true/false), `session_distance_gte`, `pace_avg_lte`,
`elevation_gain_cumulative_gte`(샘플 없어 false), `day_of_week_diversity_gte`,
`streak_weeks_gte`(경계값 true/false), `membership_anniversary_run`, `calendar_date_match`(음력 false),
`route_diversity_count_gte`(GPS 샘플 없어 false) — **전부 기대값과 일치**.

### 5.2 `evaluate_badges` 전수 실행 (시드 프로필 10명 전원)

| 프로필 | 지급 뱃지 수 |
|---|---|
| a1 | 10 |
| a2 | 12 |
| a3 | 8 |
| a4 | 13 |
| a5 | 17 |
| a6 | 15 |
| a7 | 25 |
| a8 | 21 |
| 6c27...(신규 가입, 러닝 없음) | 0 |
| 4286...(신규 가입, 러닝 없음) | 0 |

**총 121건**, 전부 `verified=true, revoked=false`. 사용자별 러닝 이력 규모에 비례하는
합리적인 분포 — 대량 오지급 패턴(전원 158개 동일 지급 등) 없음을 확인했다.

차단 카테고리(seasonal/level/district/device_source_*) 뱃지가 단 한 건도 지급되지
않았음을 별도 쿼리로 확인했다(`count(*)=0`).

이 121건은 테스트 후 **정리하지 않고 그대로 두었다** — 이전 RLS 검증(마이그레이션 25)처럼
가짜로 심은 더미 데이터가 아니라, 시드된 실제 러닝 기록에 대해 시스템이 설계대로 동작한
결과물이기 때문이다(재현 가능하고, 삭제해도 다음 `evaluate_badges` 호출에서 동일하게 재지급됨).

### 5.3 `get_advisors(security)`

신규 경고 **0건**. 기존 4건(비관련)만 그대로 — `rls_auto_enable`/`sync_my_season` anon/authenticated
실행 가능(선재 이슈), Auth leaked-password protection 비활성(대시보드 설정).

---

## 6. 문서화되지 않은 가정 (구현 중 스스로 채운 것 — gamification-designer 확인 권고)

| 대상 | 가정 |
|---|---|
| PB 판정(`pb_first_achieved`/`pb_time_lte`) | 목표 거리의 98~115% 구간 세션만 그 거리 기록으로 인정 |
| `route_diversity_count_gte` | 시작점 위경도 소수 3자리(~100m) 반올림 클러스터링(정식 알고리즘 아님) |
| `loop_course_count_gte` | 출발-도착 ≤200m + 총거리 ≥1km |
| `streak_weeks_gte` | KST ISO 주, 유예 없음, "최장 기록"(한 번 달성하면 이후 끊겨도 유지 — 기존 daily 스트릭과 동일 철학) |
| pace 3종(negative split/final km/variance) | `_run_km_split_seconds`가 보간 없이 "경계를 처음 넘는 샘플 시각"으로 근사. `RunSample`이 실제로 촘촘히 기록되는 프로덕션 환경 전제 — 현재 시드 데이터엔 샘플이 없어 이 3종은 시드 프로필 기준 전부 false(정상 동작, 미검증 상태는 아님) |

TRD `§10.1`(신규 절, 이번에 추가)에 위 표와 함께 실제 구현이 Edge Function이 아니라
Postgres 트리거(`runs_03_evaluate_badges`)라는 사실도 명시해 뒀다 — 기존 §10 서술과의
괴리를 메웠다.

---

## 7. TRD 갱신

`docs/TRD.md` §10 뒤에 **§10.1 "실제 구현 노트"** 신규 추가:
- 실제 트리거 경로(Postgres AFTER 트리거, Edge Function 아님)
- 21/44종 구현 현황과 문서 링크
- 위 §6 가정표

그 외 TRD 구조 변경은 없음 — §3.6/§4.1/§5는 이전 라운드(25/26번 마이그레이션)에서
이미 갱신됐고 이번 구현과 계속 일치한다.

---

## 8. 다음 라운드로 넘기는 것

1. `device_source_count_gte`/`device_source_diversity_gte` — 워치 브랜드 구분 컬럼 신설(gps-tracking-engineer)
2. `level_gte` — GM-04 XP 공식 확정 후 구현(gamification-designer)
3. `seasons`/`user_season_tier`/`weekly_ranking_cache` 테이블 설계·구현 → seasonal 19종 condition_type + 시즌 인스턴스 발급 잡(§7.3, 이전 보고서)
4. `district_diversity_gte` — 역지오코딩 소스 결정(§7.1, 이전 보고서) — 사용자 확인 대기 중
5. `calendar_date_match`의 음력 2건 — 음력 변환 테이블/함수 필요(작은 스코프, 원하면 다음 라운드에 바로 처리 가능)
6. §6의 가정들(PB 거리 허용오차, 루프 코스 임계값, 스트릭 유예 규칙, 클러스터링 정밀도) —
   gamification-designer의 공식 확인을 받아 카탈로그 문서 또는 TRD에 정본화 권고
