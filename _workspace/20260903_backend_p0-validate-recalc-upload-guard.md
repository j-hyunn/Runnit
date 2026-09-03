# P0 베타 blocking 2건 구현 — 서버 거리 재계산(#27) + 업로드 인플라이트 가드·재시도 상한(#29)

| 항목 | 내용 |
|---|---|
| 작성일 | 2026-09-03 |
| 담당 | backend-engineer |
| 브랜치 | `claude/task-list-planning-a51b3a` (기준 커밋 `e469038`) |
| 근거 | PRD §8.3·§8.4 / ARCHITECTURE §6.3·§9 / TRD §7·§14 #27·#29·#16·#26 |
| 상태 | 코드·문서 변경 완료, **커밋하지 않음**. 마이그레이션 64는 **2026-09-03 원격 적용 완료**(Supabase `xwtbwexcofcgmbvktwdo`, §1.4) |

PRD 스펙 변경은 없다. 두 건 모두 **이미 확정된 스펙의 미구현분을 구현**한 것이다.

---

## 1. 작업 1 — TRD §14 #27: 서버 샘플 기반 거리 재계산

### 1.1 문제

`validate_run`(마이그레이션 04)은 클라이언트가 올린 집계값(`distance_meters`·`moving_seconds`)에 **플래그만** 세웠다. 25km/h 구간 필터는 클라이언트(`GpsFilterConfig.maxPlausibleSpeedMps`)에만 존재했으므로, 앱을 개조한 클라이언트는 평균 7.0 m/s 미만이 되도록만 맞추면 임의 거리를 티어·랭킹·XP에 그대로 태울 수 있었다. PRD §8.4 "클라이언트 계산 값을 신뢰하지 않는다"가 코드로 성립하지 않는 상태.

### 1.2 설계

**`public.recalc_run_from_samples(p_samples jsonb, p_activity_type activity_type)` → `public.run_recalc_result`**

인접 샘플 쌍(구간)을 다시 걸어 산출한다. 상수는 전부 클라이언트 1차 필터와 **동일**하다 — 서버가 더 느슨하면 검증이 무의미하고, 더 빡빡하면 정직한 사용자의 거리가 깎인다.

| 규칙 | 값 | 클라이언트 대응 |
|---|---|---|
| 구간 거리 | 인접 샘플 Haversine(`_haversine_meters`). 좌표가 없으면 `cumulative_distance_meters` 차분(음수는 0 클램프)으로 폴백 | `haversineMeters` |
| 구간 제거 | 구간 속도 > **6.944 m/s (= 25km/h)** | `maxPlausibleSpeedMps = 25/3.6` |
| 미산입(정지·노이즈) | 구간 속도 < **0.6 m/s** — 거리·시간 모두 0, "제거"로도 세지 않음 | `minMovingSpeedMps = 0.6` |
| 구간 이동시간 | `min(dt, 20초)` | `signalGapSeconds = 20` |
| 타임스탬프 역행·중복 | `dt ≤ 0` → 구간 제거 + `time_regression = true` | — |

출력: `applied` / `distance_meters` / `moving_seconds` / `max_speed_mps` / `segment_count` / `removed_count` / `time_regression` / `samples`(누적거리 재기입본).

구현은 **집합 연산 1회**다(윈도우 함수로 누적거리 산출 → `jsonb_agg`). 루프 + jsonb 이어붙이기로 쓰면 3,600 샘플에서 배열 복사가 O(n²)로 터지는데, 이 함수는 BEFORE 트리거 안이라 그 비용이 업로드 지연에 그대로 얹힌다.

**스킵 분기 (⚠️ 의도됨 — TRD §14 #26 ② 와 연동)**

- `activity_type = 'indoor_run'` → 스킵
- 샘플 2개 미만(또는 `samples`가 배열이 아님) → 스킵

스킵 시 `applied = false`이고 **클라이언트 값을 그대로 유지**한다. 샘플 기반 재계산을 그대로 적용하면 경로 없는 기기 측정 거리가 0으로 깎이기 때문. 최종 취급은 #26 ②(웨어러블 실내 거리의 티어·랭킹 반영 범위)와 함께 결정한다.

**덮어쓰기 · 플래그 · 클램프는 분리된 결정이다** (2026-09-03 사용자 확정 — QA F-3/F-7/F-8). 허용 밴드 개념은 **폐기**했다: PRD §8.4의 "구간 제거 후 재계산"은 *수용 조치*이지 *예외 조치*가 아니고, 밴드를 두면 그 폭이 그대로 우회 여지가 된다.

| 결정 | 규칙 | 근거 |
|---|---|---|
| **① 덮어쓰기** | **항상.** `applied`면 `distance_meters`·`moving_seconds`·`max_speed_mps`·`samples[].cumulative_distance_meters`를 서버 값으로 확정. 이 값이 티어·주간랭킹·XP·뱃지의 근거 | PRD §8.4 원칙을 예외 없이 코드로 성립시킨다 |
| **② 플래그** | 서버 값 < 클라 주장 **× 0.8**(20% 초과 축소)일 때만 `distance_mismatch`. 그 이하 축소는 조용히 덮어쓰기만 | 정직한 기록도 스무딩 차이·신호등 정지(F-7)로 조금 짧게 나온다. 부정으로 낙인찍지 않기 위한 보수적 임계 |
| **③ 늘리는 방향** | **채택하지 않는다** = `least(recalc, claimed)`. 플래그도 안 함 | 사용자가 주장한 적 없는 거리를 서버가 만들어 랭킹에 실을 이유가 없다 (F-8) |

임계는 `trg_runs_guard`의 `v_flag_shrink_ratio constant double precision := 0.8` **한 곳**에만 있다 — 실데이터를 보고 조정할 때 고칠 곳은 그 한 줄이다.

③이 발동할 때(재계산 > 주장) **거리·이동시간·샘플을 하나도 건드리지 않는다.** 거리만 클라 값으로 두고 샘플 누적거리만 서버 값으로 재기입하면 `distance_meters`와 `max(cumulative_distance_meters)`가 어긋나 스플릿·PB가 확정 거리와 다른 근거로 산출되기 때문. 채택하지 않기로 한 이상 그 기록은 클라이언트 값 한 벌로 일관되게 남는 것이 옳다.

`runs.client_reported`는 **최초 확정 때만** 쓴다(`client_reported is null`일 때만). §1.5의 되받기가 붙으면서 재 upsert는 이미 서버 확정 거리를 실어 오므로, 매번 덮어쓰면 "원래 얼마를 주장했는가"가 서버 값으로 세탁된다. HI-07 되돌리기 분기가 `old.client_reported`를 복원해 주므로 null 검사만으로 충분하다.

**플래그 사유 우선순위**

1. `validate_run(...)` 결과 (04의 물리적 상한 검사 — 재계산 **이후** 값으로 평가)
2. `sample_time_regression` (신규)
3. `distance_mismatch` (신규 — 서버 값 < 클라 주장 × 0.8 일 때만)

**거부(422)가 아니라 플래그인 이유**: 오프라인 큐는 같은 id 재 upsert로 멱등성을 얻는데, 여기서 예외를 던지면 그 큐가 영구 실패한다(마이그레이션 05·51 헤더와 같은 방침). TRD §7 표의 "기록 거부(422)"는 플래그로 구현했고 그 사실을 §7.1에 적었다.

**스플릿 정합**: 별도 `run_splits` 테이블은 없다 — km 스플릿·PB 시각·네거티브 스플릿은 전부 `samples[].cumulative_distance_meters`를 읽어 즉석 계산한다(`_run_time_at_distance`, 마이그레이션 41). 그래서 거리를 덮어쓸 때 **샘플의 누적거리도 서버 기준으로 재기입**해 확정 거리와 스플릿이 같은 근거를 쓰게 했다. 늘리는 방향이라 채택하지 않은 경우(③)에는 샘플도 건드리지 않으므로 역시 정합적이다.

### 1.3 마이그레이션 64 구성

`supabase/migrations/20260903120000_64_server_distance_recalc.sql`

| 절 | 내용 | 줄 |
|---|---|---|
| 64-1 | `runs.client_reported jsonb` 컬럼 추가(`add column if not exists`) | 38~49 |
| 64-2 | 복합 타입 `public.run_recalc_result` (조건부 생성) | 51~74 |
| 64-3 | `recalc_run_from_samples(jsonb, activity_type)` + `revoke execute` | 76~234 |
| 64-4 | `trg_runs_guard()` 재정의 — 51-2 판본 + 재계산 블록 | 237~403 |
| 64-5 | 과거 행 백필을 하지 않는 이유 + 점검용 읽기 전용 쿼리 | 406~419 |

`trg_runs_guard` 안의 실행 순서가 계약이다: **HI-07 되돌리기 → 재계산 → 페이스 → `validate_run` → XP.** 재계산을 앞에 둬야 페이스·플래그·XP가 전부 서버 확정 거리를 근거로 산정된다.

부수 방어: INSERT 경로에서 `new.client_reported := null`(서버 전용 컬럼이므로 클라이언트가 위조한 "원본 주장값"을 남기지 않는다). 서버 쓰기 경로(`is_server_write()`)에서는 재계산 자체를 건너뛴다 — 재집계·백필이 임의 사용자의 거리를 흔들면 안 되기 때문.

**백필 안 함**: `runs`의 AFTER 트리거 4종에 `WHEN` 절이 없어 대량 UPDATE가 전 사용자 티어 재계산 + 챌린지 진척 + 미획득 뱃지 전량 재평가 + 알림 인큐를 돌린다. 게다가 재계산으로 거리가 줄면 이미 지급된 뱃지·티어의 근거가 사라지는데 **시즌 중 강등은 금지**다(PRD TI-08). 64는 앞으로 올라올 기록에만 적용된다.

### 1.3.1 QA 지적 반영 (2026-09-03 2차 — 코드 결함)

| ID | 결함 | 수정 |
|---|---|---|
| **F-1** 🔴 | `revoke execute ... from authenticated` 가 `recalc_run_from_samples` 에 걸려 있었다. `trg_runs_guard()` 는 security definer 가 아니라 **호출자 권한**으로 실행되므로, 원격 적용 즉시 트리거 안의 호출이 42501 로 죽고 **러닝 업로드가 전면 실패**한다 | `from public, anon;` 으로 완화(마이그레이션 39 `compute_run_xp` 선례와 동일). `security definer` 로 바꾸지 않았다 — 순수 함수라 인자로 받은 jsonb 외에 아무것도 읽지 않는다 |
| **F-2** 🔴 | **플래그 세탁.** 최초 INSERT 에서 `distance_mismatch` 로 플래그된 뒤 제목/메모 편집(`updateMeta`)이나 오프라인 큐 재 upsert 로 UPDATE 가 한 번 돌면, `new := old` 로 서버값이 복원돼 재계산 차이가 0 → 밴드 안 → `is_flagged := false` → `compute_run_xp` 가 만점 XP 재산정 → AFTER 트리거가 티어·랭킹·뱃지에 편입 | HI-07 되돌리기 분기에서 `v_keep_flag := true` 를 세우고, 플래그 대입부에서 `old.is_flagged`/`old.flag_reason` 를 **승계**한다. `validate_run` 기반 사유는 old 값에서 결정적으로 재현되므로 승계해도 결과 동일. 재계산발 사유만 상태에서 재현 불가라 이 보존이 필수 |
| **F-9** | 스킵 분기가 `a is null or jsonb_typeof(a) <> 'array' or jsonb_array_length(a) < 2` — Postgres 는 OR 피연산자 **평가 순서를 보장하지 않아** 스칼라 jsonb 에서 `jsonb_array_length` 가 먼저 평가돼 에러를 던질 수 있다 | 순차 평가가 문법으로 보장되는 `CASE` 로 재작성 |
| **F-10** | `immutable` 선언인데 본문이 `text → timestamptz` 캐스트를 한다(DateStyle/TimeZone 의존) | `stable` 로 정정 |
| **F-14** | `new.moving_seconds := least(recalc, elapsed_seconds)` — `elapsed_seconds` 가 0/null 인 외부 임포트 기록에서 moving 이 0 이 되고 `zero_moving_time` 이 **오발**된다 | `elapsed_seconds > 0` 일 때만 상한을 건다 |

### 1.3.2 사용자 결정 반영 (2026-09-03 3차 — 설계)

| QA ID | 결정 | 반영 |
|---|---|---|
| **F-3** | 덮어쓰기와 플래그를 분리. 덮어쓰기는 항상(밴드 폐기), 플래그는 20% 초과 축소에서만 | §1.2 표 ①② / `v_flag_shrink_ratio` |
| **F-8** | 서버가 거리를 늘리는 경우는 클라 값으로 클램프, 플래그 안 함 | §1.2 표 ③ |
| **F-7** | 20% 임계가 대부분 흡수. 실측 후 필요하면 **서버 재계산에 정지 구간 보정을 넣는 별도 후속** | §4 열린 항목 + §6 진단 쿼리 유지 |
| **F-4** | 클라이언트가 서버 확정 거리를 되받는다 — 이번 범위 포함 | §1.5 |

### 1.3.3 QA 지적 반영 (2026-09-03 4차 — 재검증)

| ID | 결함 | 수정 |
|---|---|---|
| **G-1** 🔴 (latent) | **서버 쓰기 경로가 재계산발 플래그를 지운다** — F-2의 나머지 절반. 재계산 블록이 `is_server_write()`에서 통째로 스킵되므로 `v_applied = false`이고, `v_keep_flag`는 클라이언트 되돌리기 분기에서만 세워진다. 그래서 서버측 UPDATE 한 번이 `distance_mismatch`/`sample_time_regression`(= `validate_run`이 만들 수 없는 사유)을 지우고 `compute_run_xp`가 만점 XP를 다시 매긴다. 51-1이 이미 `set_config('runnit.server_write','on') + update runs` 패턴을 쓰므로 **다음 백필/재집계 마이그레이션이 그대로 밟는다** | 규칙을 "**재계산이 실제로 다시 돈 경우에만 재계산발 플래그를 재판정**"으로 명시. `tg_op = 'UPDATE' and not v_applied and old.flag_reason in ('distance_mismatch','sample_time_regression')`이면 `v_inherited`로 승계하고 `v_reason := coalesce(v_reason, v_inherited)` — `validate_run` 사유가 새로 잡히면 그쪽이 우선 |
| **G-5** | `[1, 2]` 같은 **비-객체 원소** 배열이 길이 검사를 통과한 뒤 `jsonb_set(elem, ...)`에서 `cannot set path in scalar`로 죽는다. BEFORE 트리거 예외 = 오프라인 큐 영구 실패이므로, 이 파일 헤더의 "거부하지 않는다" 원칙이 바로 그 경로에서 깨진다 | 스킵 조건에 **객체 원소 개수 < 2** 검사를 추가하고, `pts` CTE에 `where jsonb_typeof(elem) = 'object'` 필터를 걸어 예외를 원천 차단 |
| **G-6** | TRD §4.1 매핑표에 `client_reported` 없음 | `client_reported` 행 + `distance_meters`(양방향 컬럼) 행 추가 |

### 1.5 클라이언트의 서버 확정 거리 되받기 (F-4)

덮어쓰기가 상시 경로가 되면서 "앱 요약 10.0km / 랭킹 반영 9.7km" divergence가 **플래그 없는 정상 기록에서도** 생긴다. 그래서 클라이언트가 서버 확정값을 되받아 표시한다.

**두 집합으로 나눈 이유** — 코디네이터 지시는 `_serverOwnedKeys`에 `distance_meters`를 추가하는 것이었으나, 그 집합은 "페이로드에서 **뺀다**"가 절반의 의미다. 거리·이동시간은 **서버 재계산의 입력**이라 반드시 실어야 한다 — 빼면 서버가 비교할 원본 주장값 자체가 사라지고 `client_reported`도 무의미해진다(기존 페이로드 경계 테스트도 두 컬럼의 존재를 단언한다). 그래서 "보내고 또 받는" 집합을 따로 만들었다.

| 상수 | 의미 | 컬럼 |
|---|---|---|
| `_serverOwnedKeys` | 보내지 않고 받기만 | 기존 6개 + `client_reported` |
| `_serverAdjustedKeys` | **보내고 또 받는다** | `distance_meters` · `moving_seconds` |
| `_adoptedKeys` | 응답에서 채택할 전체(= 위 둘의 합) | — |
| `_confirmationColumns` | PostgREST `select=` 인자 (`id` + `_adoptedKeys`) | — |

**`summaryJson`의 거리를 서버 값으로 갱신한다**(별도 필드로 두지 않는다). 표시만 클라 값으로 유지하면 히스토리·월간 통계·공유 카드·성취 판정이 전부 랭킹과 다른 숫자를 말하게 되고, 그 divergence를 소비 지점마다 따로 해소해야 한다. 서버 값이 단일 진실이고, 원래 주장값은 `client_reported`로 함께 내려와 로컬에 남는다.

⚠️ `samplesJson`은 갱신하지 않는다 — 서버가 `cumulative_distance_meters`를 재기입하지만 되받으려면 3,600 샘플을 다시 내려받아야 하고, 로컬 스플릿 표시는 이미 로컬 샘플 기준으로 일관되다.

⚠️ `client_reported`는 `RunRecord`의 필드가 아니라 `summaryJson`에만 얹혀 있다(json_serializable이 미지 키를 무시하므로 `fromJson`은 깨지지 않는다). **다음 전체 로컬 재기록(`toRow()`)에서 사라진다** — UI가 이 값을 실제로 쓰게 될 때 모델 필드로 승격해야 한다. 지금은 "컬럼만 확보" 단계다.

| 위치 | 내용 |
|---|---|
| `lib/features/tracking/data/local_run_repository.dart:83~110` | `_serverOwnedKeys`(+`client_reported`) · `_serverAdjustedKeys` · `_adoptedKeys` · `_confirmationColumns` |
| 같은 파일 `applyServerConfirmation` | 채택 루프를 `_adoptedKeys` 기준으로 |

### 1.4 원격 적용 절차 → ✅ **적용 완료 (2026-09-03)**

> ✅ **적용 완료** — `apply_migration(name='64_server_distance_recalc')` 로 라이브 Supabase(`xwtbwexcofcgmbvktwdo`)에 적용했다. 아래 절차·쿼리는 기록으로 남긴다.
>
> **적용 후 검증 결과**
> - `runs.client_reported jsonb` 컬럼 생성 확인
> - `recalc_run_from_samples(jsonb, activity_type)` — volatility `stable`, `authenticated` 실행 권한 유지(F-1 수정이 정상 반영 — `public`·`anon` 만 revoke)
> - `trg_runs_guard()` — 전 롤 실행 권한 revoke(트리거 함수라 정상)
> - **G-5 방어 회귀** — `[1,2]` / `[{},1]` / `'null'::jsonb` 모두 예외 없이 `applied=false` 반환
> - **마이그레이션 63 회귀 가드** — 앵커 2개(`finalized_at is not null`, `runnit.badge_season`)가 라이브 `evaluate_badge_condition` 정의에 그대로 존재
> - `runs` 트리거 5개 정상 — `runs_guard`(BEFORE) + `runs_01_recompute_stats` · `runs_02_challenge_progress` · `runs_03_evaluate_badges` · `runs_04_notifications`(AFTER)
> - security advisor — 기존 6건 그대로, **신규 0건**
>
> **잔여**: F-7 실측(§6 진단 쿼리) 미실시 — 편향 확인 시 정지 구간 보정 후속 필요.


> ## 🛑 배포 순서 계약 — **마이그레이션 64 원격 적용 → 그다음 앱 실행** (QA G-2)
>
> **64가 라이브 DB에 적용되기 전에는 이 브랜치로 라이브 Supabase에 접속하지 말 것.**
>
> `local_run_repository.dart`가 `client_reported`를 PostgREST `select=` 인자
> (`_confirmationColumns`)에 넣는다. 서버에 그 컬럼이 없으면 PostgREST가
> **42703(undefined column)** 으로 응답하고, `_push()`가 그것을 다른 실패와
> 똑같이 흡수해 모든 기록이 `failed`로 떨어진다 — **업로드 전면 실패**다.
> 재시도 상한(10회)까지 소진되면 자동 큐에서도 빠진다.
>
> 커밋/머지 자체는 안전하다(로컬 테스트는 가짜 서버를 쓴다). 위험한 것은
> **"64 미적용 상태의 라이브 DB" + "이 브랜치의 앱"** 조합 하나뿐이다.
>
> | 순서 | 작업 |
> |---|---|
> | 1 | 브랜치 DB에서 64 검증(아래 절차) |
> | 2 | 라이브 DB에 64 적용 + `client_reported` 컬럼 존재 확인 |
> | 3 | 그 뒤에 앱 빌드/배포 |
>
> 되돌릴 때도 역순이다 — 앱을 먼저 이전 버전으로 내리고 나서 컬럼을 손댄다.

로컬에 Postgres·Docker·supabase CLI가 없어 **구문 실행 검증은 하지 못했다**(리뷰 검증만). 아래 순서로 브랜치 DB에서 먼저 확인할 것을 권한다.

```
# 0) 적용 전 — 영향 규모 확인 (읽기 전용, 원격에서 바로 실행 가능)
select count(*)                                    as completed_with_samples,
       count(*) filter (where jsonb_array_length(samples) >= 2) as recalc_target
  from public.runs
 where status = 'completed' and activity_type <> 'indoor_run';

# 1) 브랜치 DB에 적용해 구문·동작 확인 (비용 발생 — 승인 필요)
#    supabase MCP: create_branch → apply_migration(파일 내용) → 아래 검증 → delete_branch

# 2) 편차 분포 — §6 의 "그대로 붙여넣어 돌리는" 쿼리 2개를 사용할 것.

# 3) 스킵 분기 회귀 — 실내/샘플 없는 기록은 applied=false 여야 한다
select (public.recalc_run_from_samples('[]'::jsonb, 'outdoor_run')).applied;      -- false
select (public.recalc_run_from_samples(samples, 'indoor_run')).applied            -- false
  from public.runs where jsonb_array_length(samples) >= 2 limit 1;

# 4) 신규 업로드 스모크 — 테스트 계정으로 러닝 1건 upsert 후
select id, distance_meters, moving_seconds, is_flagged, flag_reason, client_reported
  from public.runs order by created_at desc limit 1;

# 4b) F-1 회귀 — authenticated 권한으로 업로드가 되는지. 이게 막히면 전면 장애다.
#     테스트 계정 JWT 로 runs upsert 1건. 42501 이 나오면 즉시 롤백.
select has_function_privilege('authenticated',
  'public.recalc_run_from_samples(jsonb, public.activity_type)', 'execute');   -- true 여야 함

# 4c) F-2 회귀 — 플래그 세탁이 막혔는지. 플래그된 행의 title 을 바꿔 본다.
--    (아래는 서비스 롤이 아니라 **그 행의 소유자 세션**으로 실행해야 의미가 있다)
update public.runs set title = 'F-2 회귀' where id = '<플래그된 run id>';
select is_flagged, flag_reason, awarded_xp from public.runs where id = '<같은 id>';
--    기대: is_flagged=true, flag_reason 유지, awarded_xp 0 유지.
--    false 로 바뀌면 F-2 가 되살아난 것 — 즉시 롤백.

# 4d) G-1 회귀 — 서버 쓰기 UPDATE 가 재계산발 플래그를 지우지 않는지.
--    51-1 이 쓰는 것과 같은 패턴으로 플래그된 행을 건드려 본다.
do $$
begin
  perform set_config('runnit.server_write', 'on', true);
  update public.runs set note = note where id = '<distance_mismatch 로 플래그된 run id>';
  perform set_config('runnit.server_write', 'off', true);
end; $$;
select is_flagged, flag_reason, awarded_xp from public.runs where id = '<같은 id>';
--    기대: is_flagged=true, flag_reason='distance_mismatch' 유지, awarded_xp 0 유지.

# 4e) G-5 회귀 — 비-객체 원소 배열이 예외를 던지지 않고 스킵되는지.
select (public.recalc_run_from_samples('[1, 2]'::jsonb,        'outdoor_run')).applied;  -- false
select (public.recalc_run_from_samples('["a", "b"]'::jsonb,    'outdoor_run')).applied;  -- false
select (public.recalc_run_from_samples('[{}, 1]'::jsonb,       'outdoor_run')).applied;  -- false (객체 1개)
select (public.recalc_run_from_samples('"scalar"'::jsonb,      'outdoor_run')).applied;  -- false
--    어느 것도 예외를 던지면 안 된다 — 던지면 오프라인 큐가 영구 실패한다.

# 5) 적용 후 advisor
#    supabase MCP: get_advisors(type='security'), get_advisors(type='performance')
#    기준선은 기존 6건 — 신규 WARN 이 뜨면 되돌린다.
```

원격 적용은 `apply_migration(name='64_server_distance_recalc', query=<파일 내용>)`.

---

## 2. 작업 2 — TRD §14 #29 / L-2: 인플라이트 가드 + 재시도 상한

### 2.1 인플라이트 가드

`save()`가 띄우는 백그라운드 업로드(`_schedulePush` 체인)와 `RunSyncCoordinator.syncPending()`은 서로를 모르는 별개 실행 경로였다. 러닝 종료 직후 연결이 회복되면 같은 행을 동시에 두 번 올린다(서버 행은 클라 UUID upsert라 중복되지 않지만, 3,600 샘플이 두 번 나가고 두 응답이 같은 로컬 행에 `applyServerConfirmation`을 경쟁적으로 써 넣는다).

| 위치 | 내용 |
|---|---|
| `lib/features/tracking/data/local_run_repository.dart:102` | `final Set<String> _inFlight` — 두 경로가 공유 |
| 같은 파일 `:211` | `_push()` 진입부 `if (!_inFlight.add(record.id)) return false;` — **판정은 여기 하나** |
| 같은 파일 `:220` | `finally { _inFlight.remove(record.id); }` |
| 같은 파일 `:342` | `syncPending()` 루프의 사전 스킵(샘플 역직렬화 비용 절약용, 최종 판정 아님) |
| 같은 파일 `:105` | `@visibleForTesting Set<String> get inFlightIds` |

`Set.add`의 반환값 하나로 원자적으로 판정한다 — Dart는 단일 스레드라 `add`와 그 뒤 첫 `await` 사이에 다른 코드가 끼어들 수 없다. 인플라이트로 스킵된 건은 **실패가 아니므로 시도 횟수를 올리지 않는다**(올리면 코디네이터가 자주 발화하는 것만으로 상한이 소진된다).

### 2.2 재시도 상한 (L-2)

| 위치 | 내용 |
|---|---|
| `lib/features/tracking/data/local_run_database.dart:55` | `IntColumn get syncAttempts` (기본 0) |
| 같은 파일 `:59` | `DateTimeColumn get lastSyncAttemptAt` (nullable) |
| 같은 파일 `:73` | `schemaVersion` 1 → **2** |
| 같은 파일 `:81~90` | `MigrationStrategy.onUpgrade` — v2에서 두 컬럼 `addColumn` |
| `local_run_repository.dart:90` | `static const int maxSyncAttempts = 10` |
| 같은 파일 `:287` | `_markUploadFailed(id)` — `failed` + `syncAttempts + 1` + `lastSyncAttemptAt`(트랜잭션) |
| 같은 파일 `:276` | 성공 시 `syncAttempts: 0` 복원(`applyServerConfirmation`) |
| 같은 파일 `:306` | `resetSyncAttempts(id)` — 수동 재시도 진입점 |
| 같은 파일 `:330` | `syncPending()` 질의에 `syncAttempts < maxSyncAttempts` 추가 |

**왜 백오프가 아니라 횟수 상한인가**: 재시도 *간격*은 이미 코디네이터의 4신호(로그인/복귀/연결 회복/2분 주기)가 정하고 있다. 여기서 필요한 것은 "언젠가 멈추는 것"뿐이고, 벽시계 기반 백오프를 넣으면 `syncPending()`이 시간에 의존하게 되어 오프라인 회귀 테스트 전체가 시간에 묶인다.

상한에 걸린 행은 **지워지지 않는다** — `failed`로 로컬에 남고 `resetSyncAttempts`로 되살아난다. PRD TR-08("100% 업로드")과 충돌하지 않도록 데이터는 보존한다.

### 2.3 회귀 테스트

`test/sync/offline_sync_test.dart`에 §6 절 신설(기존 §6 페이로드 경계는 §7로 번호 이동). `_FakePostgrest`에 `Completer<void>? gate`(응답 보류 장치) 추가 — `hang`(영원히 매달림, 타임아웃 검증)과 달리 "업로드가 진행 중인 순간"을 테스트가 붙잡기 위한 것.

| 테스트 | 검증 |
|---|---|
| `업로드가 진행 중인 기록은 syncPending()이 다시 올리지 않는다` | 게이트로 인플라이트 상태를 붙잡고 `syncPending()` 호출 → 반환 0, `requestCount` 불변, 최종 `upsertedIds == ['run-race']`, 종료 후 `inFlightIds` 비어 있음 |
| `재시도는 maxSyncAttempts에서 멈춘다 — 무한 재전송 차단 (L-2)` | 서버가 계속 거부 → 10회에서 `requestCount` 정지, 행은 `failed`로 보존, `resetSyncAttempts` 후 정상 업로드 |
| `업로드에 성공하면 재시도 예산이 0으로 돌아온다` | 실패 1회 후 성공 → `syncAttempts == 0` |

---

## 3. 변경 파일

| 파일 | 변경 |
|---|---|
| `supabase/migrations/20260903120000_64_server_distance_recalc.sql` | **신규**(2026-09-03 원격 적용 완료) |
| `lib/features/tracking/data/local_run_repository.dart` | 인플라이트 set, `maxSyncAttempts`, `_markUploadFailed`, `resetSyncAttempts`, `syncPending` 필터 + **F-4 되받기**(`_serverAdjustedKeys`·`_adoptedKeys`·`_confirmationColumns`, `applyServerConfirmation`) |
| `lib/features/tracking/data/local_run_database.dart` | drift 스키마 v1→v2 (`sync_attempts`·`last_sync_attempt_at` + `MigrationStrategy`) |
| `test/sync/offline_sync_test.dart` | `gate`·`recalculatedDistanceMeters` 추가, 회귀 테스트 **5건**(#29 3건 + F-4 2건), `_runsColumns`에 `client_reported` |
| `docs/TRD.md` | v0.26. §7 ⚠️ 노트 → **§7.1 실제 구현**(2층 검증 표·덮어쓰기/플래그/클램프 3결정·스킵 분기·백필 정책·플래그 승계) + **§7.2 클라이언트 되받기** 신설. §14 #27(구현 완료·원격 적용 대기)·#29(해소) |
| `docs/ARCHITECTURE.md` | v0.20. §9 재시도 전략 항목 갱신(횟수 상한) + 인플라이트 가드 항목 신설 + **서버 확정 거리 되받기**(두 집합 구분) |

생성 코드(`*.g.dart`)는 `.gitignore` 대상이라 `git status`에 안 잡힌다 — `dart run build_runner build` 실행 완료.

## 4. 검증 결과

| 항목 | 결과 |
|---|---|
| `flutter analyze` | **No issues found!** (3.6s) |
| `flutter test` (전체) | **293개 전부 통과** |
| `flutter test test/sync/` | 28개 통과(기존 23 + #29 3건 + F-4 2건) |
| 마이그레이션 64 구문 실행 검증 | ✅ **완료(2026-09-03)** — 라이브 `apply_migration` 실행 성공, 후속 검증 쿼리 전건 통과(§1.4) |
| 원격 적용 | ✅ **완료(2026-09-03)** — `xwtbwexcofcgmbvktwdo`. advisor 신규 0건 |
| QA 2차(코드 결함) | F-1 · F-2 · F-9 · F-10 · F-14 수정 완료(§1.3.1) |
| QA 3차(사용자 결정) | F-3 · F-8 반영(§1.2), F-4 구현(§1.5), F-7은 실측 대기(§5.3) |
| QA 4차(재검증) | G-1 · G-5 · G-6 수정 완료(§1.3.3). G-2는 §1.4 배포 순서 계약으로, G-3 · G-4는 §4 열린 항목으로 등록 |

커밋하지 않았다.

**아직 열려 있는 항목** (최종본)

| # | 항목 | 내용 | 담당 · 시점 |
|---|---|---|---|
| 1 | **F-7 실측**(🔴 미실시 — 64 적용 완료로 이제 실행 가능) | §6 진단 쿼리로 편차 분포 확인. 서버 값이 체계적으로 짧으면(정지 앵커 변위 미반영) **재계산에 정지 구간 보정**을 넣는 별도 후속 + `v_flag_shrink_ratio` 재조정. ⚠️ 임계를 완화하는 것으로 덮지 말 것 — 완화한 만큼 부정 우회 여지가 넓어진다 | backend, 원격 적용 후 |
| 2 | **G-3 — 확정 거리 ↔ 랩 합계 divergence** | `summaryJson`의 거리만 서버 값으로 갱신하고 `samplesJson`은 로컬 원본을 유지하므로, 상세 화면에서 **거리는 9.7km인데 랩·페이스·경로는 10.0km 기준**으로 그려진다. 해소안 둘 중 하나: ⓐ 상세 화면에 "확정 거리" 안내 UI(기기 기록 ↔ 확정값 병기) ⓑ 서버가 재기입한 샘플을 되받기(3,600 샘플 재다운로드 비용) | ⓐ flutter-ui / ⓑ backend, F-4 잔여와 함께 |
| 3 | **F-4 잔여** | `client_reported`를 `RunRecord` 필드로 승격 + 상세 화면 표시. 지금은 `summaryJson`에만 얹혀 있어 다음 전체 로컬 재기록(`toRow()`)에서 사라진다 | flutter-ui |
| 4 | **G-4 — 업로드 중 로컬 메타 편집 유실** | 기존 결함, 이번 변경과 무관. 업로드가 도는 동안 사용자가 제목/메모를 고치면 `applyServerConfirmation`이 `synced`로 올려 버려 그 편집이 서버에 반영되지 않는다. 제안: `updatedAtLocal`을 업로드 시작 시각과 비교해 **업로드 시작 후 로컬 변경이 있었으면 `pending` 유지** | backend, 별도 라운드 |
| 5 | **F-5** | `resetSyncAttempts` 수동 재시도 UI — 상한(10회)에 걸린 행이 사용자에겐 영원히 "동기화 대기"로 보인다 (§5.5) | flutter-ui |
| 6 | **F-6** | drift v1→v2 업그레이드 경로 테스트 (`onUpgrade`가 실제 기존 DB에서 도는지) | 다음 라운드 |
| 7 | **실내 판정** | `hasRouteSamples` 도입 — 현재는 `activity_type <> 'indoor_run'` 대리 기준 (§5.4) | Phase 4 웨어러블 |

### 4.1 커밋 · 원격 적용 순서 권고

1. **커밋/머지** — 지금 상태로 안전하다. 로컬 테스트는 가짜 PostgREST를 쓰므로 라이브 DB와 무관하다.
2. **브랜치 DB에서 64 검증** — §1.4 절차 (구문·G-1/G-5 회귀·advisor).
3. **라이브 DB에 64 적용** — 사용자 승인 필요. `client_reported` 컬럼 생성 확인.
4. **그 뒤에 앱 배포.** 🛑 3번 전에 이 브랜치로 라이브에 접속하면 `client_reported` 42703으로 **업로드 전면 실패**한다(§1.4 상단 배포 순서 계약, QA G-2).
5. **적용 후 §6 진단 쿼리 실행** → F-7 판정 → 필요 시 `v_flag_shrink_ratio` 조정 또는 정지 구간 보정 후속 착수.

## 5. 사용자 확인 필요 — 미해결·불확실한 판단

### 5.1 ~~서버가 확정한 거리를 클라이언트가 되받지 않는다~~ → **해소**(F-4, §1.5)

이번 범위에 포함해 닫았다. 남은 것은 `client_reported`를 `RunRecord` 필드로 승격하고 상세 화면에 "기기 기록 10.0km → 확정 9.7km"를 표시하는 일 — flutter-ui 후속이며, 그때까지 값은 `summaryJson`에만 임시로 남는다(§1.5 두 번째 ⚠️).

### 5.2 재계산 시 "이동시간"의 정의

서버는 `sum(min(dt, 20))` over 유효 구간(0.6 ≤ v ≤ 6.944 m/s)으로 정의했다. 클라이언트의 상태기계(정지 앵커·이탈 임계·복귀 판정)와 **완전히 같지는 않다** — 특히 정지 → 출발 전이에서 클라이언트는 앵커→현재 변위를 통째로 더하는데 서버에는 그 개념이 없다. 결과적으로 서버 이동시간이 클라이언트보다 다소 짧게 나올 수 있고, 그러면 페이스가 빨라져 `implausible_avg_speed`(7.0 m/s) 쪽으로 밀린다.

현재는 거리를 덮어쓸 때만 이동시간도 함께 덮어쓰므로(두 값은 한 쌍) 영향 범위가 좁다. **§1.4 (2)번 쿼리로 실데이터 편차를 본 뒤 확정할 것.**

### 5.3 ~~허용 밴드 5% / 100m~~ → **결정 완료**(F-3/F-8), F-7만 실측 대기

밴드는 폐기하고 "덮어쓰기 항상 / 플래그 20% 초과 축소에서만 / 늘리는 방향 미채택"으로 확정했다(§1.2). 남은 것은 **F-7 실측** 하나다.

> **F-7**: 신호등 정지에서 클라이언트는 정지 앵커→현재 변위를 통째로 더하는데 서버에는 그 개념이 없어, 서버 값이 **체계적으로** 짧게 나올 수 있다. 20% 임계면 대부분 흡수되지만, 원격 적용 후 §6 진단 쿼리로 편차 분포를 보고 편향이 확인되면 **서버 재계산에 정지 구간 보정을 넣는 별도 후속**이 필요하다. 그때 `v_flag_shrink_ratio`도 함께 조정한다.

### 5.4 실내 판정 기준 — `activity_type = 'indoor_run'`

ARCHITECTURE §6.3의 정본 기준은 "기기 종류가 아니라 **경로 샘플 존재 여부**"(`hasRouteSamples`)인데, 그 필드는 아직 코드에 없다. 64는 `activity_type <> 'indoor_run'` + `샘플 ≥ 2`라는 기존 대리 기준을 그대로 따랐다. 폰 GPS 단독인 동안 두 기준은 동치이므로 지금은 안전하지만, **웨어러블 연동(Phase 4) 착수 전에 `hasRouteSamples` 도입과 함께 정리**해야 한다(TRD §14 #26 ②·⑤, PRD §10.2 #14).

관련해 TRD §14 **#16**(`session_distance_gte`는 실내를 제외하지 않는데 `pb_first_achieved`/`season_first_long_distance`는 제외한다)도 같은 뿌리이며 #26으로 이관된 상태다 — 이번 작업은 그 불일치를 **건드리지 않았다**(PRD v1.8 "그때까지 실내 러닝 관련 코드·스키마·뱃지 카탈로그는 손대지 않는다").

### 5.5 재시도 상한 도달 상태를 사용자에게 보여 줄 UI가 없다

`sync_attempts >= 10`인 행은 자동 큐에서 빠지는데, 히스토리의 "동기화 대기" 칩(커밋 `9ded58f`, `isSyncPending()`)은 그 상태를 구분하지 않는다. 사용자에겐 영원히 "동기화 대기"로 보인다. `resetSyncAttempts(id)`를 태울 "다시 시도" 진입점이 필요하다 — flutter-ui-designer 라운드 대상.

### 5.6 `max_speed_mps` 취급

재계산이 적용되면 유효 구간의 최댓값(≤ 6.944 m/s)으로 덮어쓴다. 그러면 `validate_run`의 `implausible_max_speed`(> 15.0 m/s)는 재계산이 적용된 기록에서 **구조적으로 발화하지 않는다**. 순간 이상은 이미 구간 제거 + `distance_mismatch`가 잡으므로 의도한 결과지만, 두 검사의 역할 분담을 명시적으로 승인받는 편이 좋다.

---

## 6. F-3 / F-7 결정용 진단 쿼리 (브랜치 DB에서 그대로 실행)

**목적**: **F-7 시나리오 — 신호등 정지(앵커 변위 미반영)로 서버 값이 체계적으로 짧게 나오는가** — 를 실데이터로 확인하고, 그 결과로 `v_flag_shrink_ratio`(현재 0.8)를 조정한다. 둘 다 **읽기 전용**이며 행을 바꾸지 않는다.

전제: 마이그레이션 64가 브랜치 DB에 적용돼 있을 것(`recalc_run_from_samples`가 있어야 한다). 아직 재계산이 반영되지 않은 기존 행을 대상으로 하므로, `runs.distance_meters`는 순수한 **클라이언트 보고값**이다 — 그래서 비교가 성립한다.

> ⚠️ 64를 적용한 뒤 **새로 업로드된 행**은 이미 서버 확정값이 들어 있어(그리고 F-4 되받기로 클라이언트도 그 값을 쓴다) 편차가 0으로 나온다. 이 진단은 `created_at < '<64 적용 시각>'` 인 행에만 의미가 있다. 아래 쿼리의 `-- [적용시각 필터]` 주석 자리에 조건을 넣어 좁힐 것.

### 6.1 쿼리 A — 건별 편차 + 정지구간 지표 (F-7 신호를 직접 본다)

```sql
with base as (
  select r.id, r.user_id, r.started_at, r.activity_type, r.samples,
         r.distance_meters as claimed_m,
         r.moving_seconds  as claimed_moving,
         r.elapsed_seconds
    from public.runs r
   where r.status = 'completed'
     and r.activity_type <> 'indoor_run'
     and jsonb_array_length(r.samples) >= 2
     -- [적용시각 필터] and r.created_at < timestamptz '2026-09-03 00:00+09'
),
srv as (                                  -- 서버 재계산 결과
  select b.id, b.user_id, b.started_at,
         b.claimed_m, b.claimed_moving, b.elapsed_seconds,
         x.distance_meters as server_m,
         x.moving_seconds  as server_moving,
         x.segment_count, x.removed_count, x.time_regression
    from base b
    cross join lateral
      public.recalc_run_from_samples(b.samples, b.activity_type) x
   where x.applied
),
pts as (                                  -- 구간 분해(정지 구간을 따로 세기 위해)
  select b.id, s.ord,
         (s.elem ->> 'timestamp')::timestamptz      as t,
         (s.elem ->> 'latitude')::double precision  as lat,
         (s.elem ->> 'longitude')::double precision as lon
    from base b
    cross join lateral
      jsonb_array_elements(b.samples) with ordinality as s(elem, ord)
),
seg as (
  select id,
         extract(epoch from (t - lag(t) over w))::double precision as dt,
         case when lat is not null and lon is not null
               and lag(lat) over w is not null
               and lag(lon) over w is not null
              then public._haversine_meters(
                     lag(lat) over w, lag(lon) over w, lat, lon)
         end as seg_m
    from pts
  window w as (partition by id order by ord)
),
stops as (
  select id,
         count(*) filter (
           where dt > 0 and seg_m is not null and seg_m / dt < 0.6
         ) as stationary_segments,
         coalesce(sum(
           case when dt > 0 and seg_m is not null and seg_m / dt < 0.6
                then least(dt, 20) else 0 end
         ), 0) as stationary_seconds
    from seg
   group by id
)
select
  s.id,
  s.started_at,
  round(s.claimed_m)                                    as claimed_m,
  round(s.server_m)                                     as server_m,
  round(s.server_m - s.claimed_m)                       as delta_m,
  round(100 * (s.server_m - s.claimed_m)
        / nullif(s.claimed_m, 0), 2)                    as delta_pct,
  -- 현재 설계에서 distance_mismatch 플래그가 붙는 조건(v_flag_shrink_ratio = 0.8).
  -- 덮어쓰기는 이것과 무관하게 항상 일어난다.
  (s.server_m < s.claimed_m * 0.8)                      as would_flag,
  s.claimed_moving,
  s.server_moving,
  s.server_moving - s.claimed_moving                    as delta_moving_s,
  st.stationary_segments,                               -- F-7 신호 ①
  round(st.stationary_seconds)                          as stationary_seconds,
  s.segment_count,
  s.removed_count,
  s.time_regression
from srv s
join stops st using (id)
order by abs(s.server_m - s.claimed_m) desc
limit 200;
```

**읽는 법**

| 관찰 | 해석 | 액션 |
|---|---|---|
| `delta_pct`가 대체로 −5 ~ 0% | 정상. 0.8 임계에 한참 못 미친다 | 현행 유지 |
| `delta_pct`가 음수 쪽으로 몰리고 **`stationary_segments`와 상관** | **F-7 확정** — 정지 앵커 변위를 서버가 못 세고 있다 | 임계를 낮추는 것으로 덮지 말고, **서버 재계산에 정지 구간 보정을 도입**(별도 후속) |
| `would_flag = true`가 정직해 보이는 기록에서 다수 | 0.8이 너무 빡빡하다 | `v_flag_shrink_ratio`를 0.7 등으로 완화 |
| `would_flag`가 사실상 0건 | 임계가 느슨할 수 있다 | 부정 샘플이 없는 것인지 임계가 무른 것인지 구분 필요 — 조작 시나리오를 별도로 넣어 검증 |
| `time_regression = true`가 흔함 | 클라이언트가 중복 타임스탬프를 올리고 있다 | 별도 이슈 — 트래킹 쪽 확인 |

### 6.2 쿼리 B — 분포 요약 한 줄 (`v_flag_shrink_ratio` 결정용)

```sql
with base as (
  select r.id, r.activity_type, r.samples, r.distance_meters as claimed_m
    from public.runs r
   where r.status = 'completed'
     and r.activity_type <> 'indoor_run'
     and jsonb_array_length(r.samples) >= 2
     and r.distance_meters > 0
     -- [적용시각 필터] and r.created_at < timestamptz '2026-09-03 00:00+09'
),
d as (
  select 100 * (x.distance_meters - b.claimed_m) / b.claimed_m as pct,
         abs(x.distance_meters - b.claimed_m)                  as abs_m,
         b.claimed_m
    from base b
    cross join lateral
      public.recalc_run_from_samples(b.samples, b.activity_type) x
   where x.applied
)
select
  count(*)                                                     as runs,
  round(avg(pct)::numeric, 2)                                  as mean_pct,
  round((percentile_cont(0.05) within group (order by pct))::numeric, 2) as p05_pct,
  round((percentile_cont(0.50) within group (order by pct))::numeric, 2) as p50_pct,
  round((percentile_cont(0.95) within group (order by pct))::numeric, 2) as p95_pct,
  round((percentile_cont(0.99) within group (order by pct))::numeric, 2) as p99_pct,
  -- 플래그 임계 후보별 적중 건수(덮어쓰기는 임계와 무관하게 항상 일어난다)
  count(*) filter (where pct < -20) as would_flag_at_0_80,   -- 현행
  count(*) filter (where pct < -30) as would_flag_at_0_70,
  count(*) filter (where pct < -10) as would_flag_at_0_90
from d;
```

**임계 결정 기준**: `p05_pct`(가장 많이 깎인 5%)가 −20%에 얼마나 가까운지를 본다. 정직한 기록의 `p05_pct`가 −20% 근처면 오탐이 나므로 완화해야 한다.

⚠️ `mean_pct`가 뚜렷하게 음수(예: −3% 이하)면 그것은 임계 문제가 아니라 **F-7의 체계적 편향**이다. 임계를 완화하는 것으로 덮지 말 것 — 완화한 만큼 부정 우회 여지가 같이 넓어진다. 그 경우의 올바른 조치는 **서버 재계산에 정지 구간 보정을 넣어 편향 자체를 없애는 것**이다.
