# P0 잔여 백엔드 진단 2건 — F-7 신호등 정지 편향 실측 · `client_reported` 실 왕복 검증

| 항목 | 내용 |
|---|---|
| 일자 | 2026-09-08 |
| 담당 | backend-engineer |
| 대상 | ① TRD §14 #27 잔여 ①(F-7 실측) ② QA UNVERIFIED-1(`client_reported` 서버→클라 실 왕복) |
| 범위 | **읽기 전용 진단만.** 스키마 변경·마이그레이션 적용·코드 수정·커밋 **없음** |
| 대상 프로젝트 | 프로덕션 Supabase `xwtbwexcofcgmbvktwdo` (마이그레이션 64 적용 완료 상태 확인) |
| 근거 문서 | PRD §8.3·§8.4 / TRD §7·§7.1·§7.2·§14 #27 / ARCHITECTURE §9 / `_workspace/20260903_backend_p0-validate-recalc-upload-guard.md` §6 / `_workspace/20260907_qa_p0-group1.md` UNVERIFIED |

## 0. 결론 요약

| # | 판정 |
|---|---|
| 태스크 1 (F-7) | **판정 불가 — 표본이 2026-09-03 1차 실행 이후 단 1건도 늘지 않았다.** `runs` 최신 `created_at` 이 **2026-09-02 09:12 UTC** 로, 마이그레이션 64 적용(2026-09-03) **이후 업로드된 기록이 0건**이다. 재계산 대상은 여전히 5건, 분포도 소수점까지 동일. 현 표본 한정으로는 **F-7 편향 신호 없음**이고 `v_flag_shrink_ratio = 0.8` 현행 유지가 타당하다. 정지 구간 보정 후속은 **착수하지 않는다** |
| 태스크 2 (실 왕복) | **부분 해소.** `client_reported is not null` 행은 여전히 **0건**이라 "이 컬럼의 실 데이터 왕복"은 미검증. 다만 실 REST 호출로 **① PostgREST 스키마 캐시가 `runs.client_reported` 를 인지한다**(G-2 배포 계약의 실질 위험 해소)와 **② PostgREST 가 jsonb 컬럼을 문자열이 아닌 JSON 객체로, timestamptz 를 `+00:00` ISO8601 로 내려준다**를 같은 DB의 다른 테이블로 **실측 확인**했다. Dart 파서 캐스트 예외 위험은 **없다**고 판정 |

---

# 태스크 1 — F-7 신호등 정지 편향 실측

## 1.1 표본 현황 (선행 확인)

```sql
select
  count(*) as total_runs,
  count(*) filter (where status='completed') as completed,
  count(*) filter (where client_reported is not null) as with_client_reported,
  count(*) filter (where is_flagged) as flagged,
  count(*) filter (where flag_reason='distance_mismatch') as flag_distance_mismatch,
  count(*) filter (where flag_reason='sample_time_regression') as flag_time_regression,
  count(*) filter (where status='completed' and activity_type <> 'indoor_run'
                     and jsonb_array_length(samples) >= 2) as recalc_target,
  max(created_at) as latest_created_at
from public.runs;
```

| total_runs | completed | with_client_reported | flagged | distance_mismatch | time_regression | recalc_target | latest_created_at |
|---|---|---|---|---|---|---|---|
| 47 | 47 | **0** | **0** | 0 | 0 | 5 | **2026-09-02 09:12:44 UTC** |

🔴 **이 표의 마지막 칸이 이번 라운드의 핵심이다.** 마이그레이션 64 는 2026-09-03 에 적용됐는데 그 이후 **새 러닝 업로드가 한 건도 없다**. 즉 64 의 재계산 경로는 **프로덕션에서 아직 한 번도 실행된 적이 없고**, F-7 판정에 쓸 신규 데이터도 0건이다. 이것이 두 태스크 모두의 공통 병목이다.

`list_migrations` 로 `20260903081203 / 64_server_distance_recalc` 가 원격 최신 마이그레이션임을 확인했다(그 뒤로 적용된 마이그레이션 없음).

## 1.2 쿼리 B — 분포 요약 (§6.2 원문 그대로)

```sql
with base as (
  select r.id, r.activity_type, r.samples, r.distance_meters as claimed_m
    from public.runs r
   where r.status = 'completed'
     and r.activity_type <> 'indoor_run'
     and jsonb_array_length(r.samples) >= 2
     and r.distance_meters > 0
),
d as (
  select 100 * (x.distance_meters - b.claimed_m) / b.claimed_m as pct,
         abs(x.distance_meters - b.claimed_m) as abs_m, b.claimed_m
    from base b
    cross join lateral public.recalc_run_from_samples(b.samples, b.activity_type) x
   where x.applied
)
select count(*) as runs,
  round(avg(pct)::numeric,2) as mean_pct,
  round((percentile_cont(0.05) within group (order by pct))::numeric,2) as p05_pct,
  round((percentile_cont(0.50) within group (order by pct))::numeric,2) as p50_pct,
  round((percentile_cont(0.95) within group (order by pct))::numeric,2) as p95_pct,
  round((percentile_cont(0.99) within group (order by pct))::numeric,2) as p99_pct,
  count(*) filter (where pct < -20) as would_flag_at_0_80,
  count(*) filter (where pct < -30) as would_flag_at_0_70,
  count(*) filter (where pct < -10) as would_flag_at_0_90
from d;
```

| runs | mean_pct | p05_pct | p50_pct | p95_pct | p99_pct | @0.80 | @0.70 | @0.90 |
|---|---|---|---|---|---|---|---|---|
| 5 | −17.17 | −72.07 | +0.91 | +1.58 | +1.62 | 1 | 1 | 1 |

**2026-09-03 1차 실행 결과와 소수점까지 완전히 동일하다.** 새 표본이 없으므로 당연한 결과이며, 이 일치 자체가 "데이터가 늘지 않았다"의 교차 확인이다.

## 1.3 쿼리 A — 건별 편차 + 정지구간 지표 (§6.1)

§6.1 원문에서 두 곳만 고쳤다(진단 의미는 동일).
- `round(double precision, integer)` 가 Postgres 에 없어 `round((...)::numeric, 2)` 로 캐스트 (원문 그대로면 42883 에러)
- 진단 강화를 위해 `total_segments`(유효 구간 총수)와 `is_flagged`/`flag_reason`(라이브 행의 실제 플래그 상태) 컬럼 추가

```sql
with base as (
  select r.id, r.started_at, r.created_at, r.activity_type, r.samples,
         r.distance_meters as claimed_m, r.moving_seconds as claimed_moving, r.elapsed_seconds,
         r.is_flagged, r.flag_reason
    from public.runs r
   where r.status='completed' and r.activity_type <> 'indoor_run'
     and jsonb_array_length(r.samples) >= 2
),
srv as (
  select b.*, x.distance_meters as server_m, x.moving_seconds as server_moving,
         x.segment_count, x.removed_count, x.time_regression
    from base b
    cross join lateral public.recalc_run_from_samples(b.samples, b.activity_type) x
   where x.applied
),
pts as (
  select b.id, s.ord,
         (s.elem->>'timestamp')::timestamptz as t,
         (s.elem->>'latitude')::double precision as lat,
         (s.elem->>'longitude')::double precision as lon
    from base b cross join lateral jsonb_array_elements(b.samples) with ordinality as s(elem,ord)
),
seg as (
  select id,
         extract(epoch from (t - lag(t) over w))::double precision as dt,
         case when lat is not null and lon is not null
               and lag(lat) over w is not null and lag(lon) over w is not null
              then public._haversine_meters(lag(lat) over w, lag(lon) over w, lat, lon) end as seg_m
    from pts window w as (partition by id order by ord)
),
stops as (
  select id,
    count(*) filter (where dt>0 and seg_m is not null and seg_m/dt < 0.6) as stationary_segments,
    coalesce(sum(case when dt>0 and seg_m is not null and seg_m/dt < 0.6
                      then least(dt,20) else 0 end),0)::numeric as stationary_seconds,
    count(*) filter (where dt>0 and seg_m is not null) as total_segments
  from seg group by id
)
select left(s.id::text,8) as id8, s.created_at::date as created,
  round(s.claimed_m::numeric) as claimed_m, round(s.server_m::numeric) as server_m,
  round((s.server_m - s.claimed_m)::numeric) as delta_m,
  round((100*(s.server_m-s.claimed_m)/nullif(s.claimed_m,0))::numeric,2) as delta_pct,
  (s.server_m < s.claimed_m*0.8) as would_flag,
  s.claimed_moving, s.server_moving, s.server_moving - s.claimed_moving as delta_moving_s,
  st.stationary_segments, round(st.stationary_seconds) as stationary_seconds, st.total_segments,
  s.segment_count, s.removed_count, s.time_regression, s.is_flagged, s.flag_reason
from srv s join stops st using (id)
order by abs(s.server_m - s.claimed_m) desc limit 200;
```

| id8 | created | claimed_m | server_m | delta_m | delta_pct | would_flag | claimed_moving | server_moving | Δmoving | stationary_seg | stationary_s | total_seg | removed | time_regr | is_flagged |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `9e050888` | 2026-08-28 | 766 | 75 | −691 | **−90.20** | ✅ | 122 | 15 | −107 | 1 | 20 | 40 | **32** | false | false |
| `ba2b5a9b` | 2026-09-02 | 165 | 167 | +2 | +1.36 | — | 59 | 59 | 0 | 0 | 0 | 58 | 0 | false | false |
| `ec370c73` | 2026-08-26 | 233 | 236 | +2 | +0.91 | — | 82 | 82 | 0 | 0 | 0 | 81 | 0 | false | false |
| `6d7afcd5` | 2026-08-27 | 502 | 505 | +2 | +0.42 | — | 189 | 175 | −14 | 1 | 20 | 172 | 0 | false | false |
| `5620c9f6` | 2026-09-02 | 130 | 132 | +2 | +1.63 | — | 46 | 46 | 0 | 0 | 0 | 46 | 0 | false | false |

`is_flagged` 가 전건 false 인 것은 정상이다 — 64 는 과거 행을 **백필하지 않는다**(TI-08 시즌 중 강등 금지 + AFTER 트리거 폭발 회피). 위 `would_flag` 는 "지금 다시 올라오면 어떻게 되는가"의 시뮬레이션이다.

## 1.4 F-7 판정

**편향은 확인되지 않는다. 단, 표본 부족으로 "확인 안 됨"이지 "없음"이 아니다.**

| 근거 | 관찰 |
|---|---|
| 방향성 | 정상 4건의 `delta_pct` 가 전부 **양수**(+0.42 ~ +1.63%). F-7 이 예측하는 것은 서버가 **짧게** 나오는 것(음수)인데, 실제로는 서버가 미세하게 **길게** 나와 `least(recalc, claimed)` 클램프로 무변화 처리된다 |
| 정지구간 상관 | `stationary_segments` 가 1인 `6d7afcd5`(172구간 중 1개)의 `delta_pct` 가 **+0.42%** 로, 정지구간 0인 3건(+0.91 ~ +1.63%)과 같은 대역이다. 편향이 있다면 정지구간이 있는 건이 음수 쪽으로 밀려야 하는데 그렇지 않다 |
| `mean_pct = −17.17` 의 해석 | **F-7 신호가 아니다.** 전부 `9e050888` 한 건이 만든다. 이 건은 40구간 중 **32구간이 25km/h 초과**(구간 평균 7.06 m/s, 최대 8.38 m/s)인 GPS 글리치/개발 테스트 아티팩트로, **#27 이 잡으라고 만든 바로 그 케이스**다. `p50 = +0.91%` 가 실제 중심이다 |
| 이동시간(§5.2 열린 항목) | `6d7afcd5` 의 `delta_moving_s = −14`(189→175초, −7.4%)만 유의미하다. 정지구간 1개(20초)를 서버가 미산입해 생긴 차이로 §5.2 서술과 정확히 일치한다. 거리를 덮어쓰지 않는 클램프 경로라 실제 영향은 없었다 |

### ⚠️ 이 판정의 한계 — 그대로 신뢰하면 안 되는 이유

- **n = 5**, 최장 766m. **도심 장거리 러닝(신호등·횡단보도 다수)이 표본에 단 한 건도 없다.** F-7 은 정의상 그 상황에서만 발생하는 편향이므로, 현 표본은 F-7 을 반증할 **검정력이 없다**.
- 정지구간 총량이 5건 합쳐 **2개 / 40초**다. 편향을 관측할 사건 자체가 거의 발생하지 않았다.
- 64 적용 이후 실제 재계산이 프로덕션에서 **0회 실행**됐다. 위 결과는 전부 `recalc_run_from_samples` 를 진단용으로 **직접 호출한 시뮬레이션**이며, 트리거 경로를 통과한 실측이 아니다.

### 액션

| 항목 | 결론 |
|---|---|
| `v_flag_shrink_ratio` (현행 0.8) | **변경하지 않는다.** 정상 기록 오탐 0건, 이상치 1건만 적중 |
| 정지 구간 보정 후속 | **착수하지 않는다.** 근거 데이터가 없다 |
| 다음 실측 시점 | 아래 §1.5 |

## 1.5 다음 실측 시점 · 트리거 조건 (제안)

1차 실행(2026-09-03) 때의 "베타 20건" 기준은 **모수만 말하고 조건을 말하지 않아** 이번처럼 0건이 쌓인 채 시간만 지나면 재실행이 무의미해진다. 다음 조건을 **전부** 만족할 때 §6.1/§6.2 를 재실행할 것을 제안한다.

| 조건 | 값 | 이유 |
|---|---|---|
| ① 재계산 대상 행 수 | `created_at > '2026-09-03'` 인 행 **20건 이상** | 64 적용 이후 트리거를 실제로 통과한 기록만 유효 |
| ② 거리 조건 | 그중 `distance_meters >= 3000` 이 **10건 이상** | 신호등 정지가 실제로 여러 번 발생하는 길이. 766m 표본으로는 영원히 판정 불가 |
| ③ 정지구간 조건 | `stationary_segments >= 3` 인 행이 **5건 이상** | F-7 사건 자체가 관측돼야 편향을 논할 수 있다 |

**판정 기준**(그때 적용):
- `p50_pct <= -3%` 또는 `mean_pct <= -3%`(이상치 제외 후) → **F-7 확정.** 임계 완화가 아니라 **정지 구간 보정** 착수
- `stationary_segments` 와 `delta_pct` 가 음의 상관 → 이상치가 없어도 **F-7 확정**
- 위 둘 다 아니고 `p05_pct` 가 −20% 에 근접 → 그때는 임계(`v_flag_shrink_ratio`) 조정 논의

⚠️ 어느 경우에도 **임계 완화로 덮지 않는다** — 완화한 폭이 그대로 부정 우회 여지가 된다(§6.2 원문 경고 유지).

**대기만 하지 말 것**: 위 조건은 클로즈드 베타 없이는 만족되지 않는다. 조건 충족 전이라도 **도심 코스 실기기 러닝 3~5건**(신호등 다회 정지 포함)을 QA 계정으로 확보하면 방향성 판단은 가능하다 — 메모리의 `simulator-run-config` / 실기기 검증 묶음에 이 항목을 같이 넣을 것을 권한다.

## 1.6 편향 확인 시 후속 작업 규모 스케치 (착수 아님 — 참고용)

지금 착수하지 않지만, ①~③ 충족 후 편향이 확인될 경우의 규모는 아래 정도다.

| 항목 | 내용 |
|---|---|
| 변경 대상 | `recalc_run_from_samples` **한 함수의 CTE 한 곳**. `trg_runs_guard` 는 호출부라 무변경 |
| 보정 방식(안) | 현재는 구간속도 < 0.6 m/s 를 **거리·시간 모두 0** 으로 버린다. 클라이언트는 정지 진입 시 **앵커를 잡고 이탈할 때 앵커→현재 변위를 한 번에 더한다**. 서버에 같은 개념을 넣으려면 "연속된 미산입 구간을 하나의 정지 블록으로 묶고, 블록 진입점↔이탈점 Haversine 을 **블록 전체 소요시간 기준 속도가 6.944 m/s 이하일 때만** 1회 가산"하는 윈도우 하나가 추가된다 |
| 구현 난이도 | 중. 기존 구조가 **집합 연산 1회**(윈도우 → `jsonb_agg`)라 정지 블록 그룹핑(`sum(case when moving then 1 else 0 end) over (...)` 형태의 gaps-and-islands)을 CTE 하나로 얹을 수 있다. **루프로 가면 안 된다** — BEFORE 트리거 안이라 3,600 샘플에서 O(n²) 가 업로드 지연에 그대로 얹힌다 |
| 부수 영향 | ⚠️ 보정으로 서버 거리가 **늘어나면** `least(recalc, claimed)` 클램프(F-8) 때문에 대부분 무변화가 되고, 실제로 달라지는 것은 "덜 깎이는" 케이스뿐이다. 즉 **보정의 효과는 오탐 감소이지 거리 증가가 아니다** — 이 점을 후속 설계 시 먼저 확인할 것 |
| 백필 | **하지 않는다**(64 와 동일 방침 — TI-08 + AFTER 트리거 4종 폭발) |
| 검증 | 정지 블록이 있는 실측 샘플 3건 + 합성 케이스(정지 블록 0개/1개/연속 2개, 블록 내 GPS 드리프트)로 회귀. `v_flag_shrink_ratio` 재검토를 같은 라운드에서 |
| 규모 | 마이그레이션 1개 + 진단 재실행. **1 라운드** 분량 |

---

# 태스크 2 — `client_reported` 서버→클라 실 왕복 검증

## 2.1 대상 행 재확인 — 여전히 0건

§1.1 표의 `with_client_reported = 0`. 원인은 F-7 과 같다: **64 적용 이후 업로드가 0건**이라 트리거의 `client_reported` 채움 분기(`new.client_reported is null and abs(diff) >= 1.0`, 마이그레이션 64 L366)가 한 번도 실행되지 않았다. 기존 5건은 전부 클램프 경로(재계산 ≥ 주장)라, 설령 지금 재 upsert 돼도 `9e050888` 을 제외하면 이 컬럼은 채워지지 않는다.

## 2.2 실 REST 호출 — 실행 전문과 응답

엔드포인트 `https://xwtbwexcofcgmbvktwdo.supabase.co/rest/v1`, 키는 publishable(anon) 을 사용했다.

### A) 목표 쿼리

```
GET /rest/v1/runs?select=id,client_reported&client_reported=not.is.null&limit=5
```
```json
{"code":"42501","details":null,
 "hint":"Grant the required privileges to the current role with: GRANT SELECT ON public.runs TO anon;",
 "message":"permission denied for table runs"}
```
HTTP **401**

`runs` 는 RLS 이전에 **테이블 GRANT 자체가 `authenticated` 전용**이라 anon 키로는 도달할 수 없다(설계대로다 — 남의 러닝 기록이 익명에게 열리면 안 된다). MCP 로는 사용자 JWT 를 발급할 수 없어 **인증 세션 왕복은 이 라운드에서 불가능**하다.

### B) 스키마 캐시 인지 여부 — 대조 실험

```
GET /rest/v1/runs?select=id,definitely_no_such_column&limit=1
```
```json
{"code":"42703","details":null,"hint":null,
 "message":"column runs.definitely_no_such_column does not exist"}
```
HTTP **400**

🟢 **의미가 있다.** 없는 컬럼은 **권한 오류보다 먼저** 42703 으로 떨어지는데, `client_reported` 는 42703 이 아니라 **42501** 로 떨어졌다. 즉 **PostgREST 와 Postgres 가 `runs.client_reported` 를 실재 컬럼으로 해석했다** — 스키마 캐시가 마이그레이션 64 이후로 갱신돼 있다는 뜻이다.

이것으로 **QA G-2 / 배포 순서 계약의 실질 위험(`_confirmationColumns` 의 `client_reported` 가 42703 을 유발해 업로드 전면 실패)은 해소**된다. 컬럼은 REST 층에서 정상 인지되고 있다.

### C) jsonb · timestamptz 렌더링 형태 — 같은 DB의 다른 테이블로 실측

`runs` 를 못 읽으므로, **같은 PostgREST 인스턴스**의 anon 읽기 가능 테이블로 직렬화 규약을 확인했다.

```
GET /rest/v1/badges?select=*&limit=1
```
```json
[{"id":"cnt_cum_1","name":"첫 러닝","description":"검증된 러닝 세션 누적 1회 달성 시 획득",
  "category":"cumulative_count","scope":"permanent","trigger_type":"cumulative",
  "condition_type":"cumulative_count_gte","condition":{"count": 1},
  "badge_grade":"bronze","season_id":null}]
```
HTTP **200**

→ `badges.condition` 은 **jsonb 컬럼**인데 응답에서 `{"count": 1}` **JSON 객체**로 왔다. 문자열(`"{\"count\": 1}"`)이 아니다.

```
GET /rest/v1/leaderboard_entries?select=*&limit=1
```
```json
[{..., "period_start":"2026-09-01T15:00:00+00:00",
       "computed_at":"2026-09-02T14:55:00.094353+00:00",
       "reached_at":"2026-09-02T09:10:37.574925+00:00", ...}]
```
HTTP **200**

→ **timestamptz 는 `YYYY-MM-DDTHH:MM:SS.ffffff+00:00`** 형태다(마이크로초 6자리 + `+00:00` 오프셋).

## 2.3 트리거가 만드는 jsonb 렌더링 — 재현 SELECT

행이 0건이라 트리거 출력물을 실 데이터로 재현했다(마이그레이션 64 L366-372 의 `jsonb_build_object` 를 그대로).

```sql
select left(r.id::text,8) as id8,
       jsonb_build_object(
         'distance_meters', r.distance_meters,
         'moving_seconds',  r.moving_seconds,
         'max_speed_mps',   r.max_speed_mps,
         'recalculated_at', now()
       ) as would_be_client_reported,
       jsonb_typeof(jsonb_build_object('d', r.distance_meters) -> 'd') as distance_json_type,
       jsonb_typeof(jsonb_build_object('m', r.moving_seconds)  -> 'm') as moving_json_type,
       jsonb_typeof(jsonb_build_object('s', r.max_speed_mps)   -> 's') as maxspeed_json_type,
       jsonb_typeof(jsonb_build_object('t', now())             -> 't') as recalc_at_json_type
  from public.runs r
 where r.id::text like '9e050888%' or r.id::text like '6d7afcd5%';
```

| id8 | would_be_client_reported | distance | moving | max_speed | recalculated_at |
|---|---|---|---|---|---|
| `9e050888` | `{"max_speed_mps": 8.37837255256609, "moving_seconds": 122, "distance_meters": 765.991325560386, "recalculated_at": "2026-09-08T05:58:47.305696+00:00"}` | number | number | number | string |
| `6d7afcd5` | `{"max_speed_mps": 3.22036769928776, "moving_seconds": 189, "distance_meters": 502.434610393494, "recalculated_at": "2026-09-08T05:58:47.305696+00:00"}` | number | number | number | string |

`recalculated_at` 이 §2.2-C 의 `leaderboard_entries.computed_at` 과 **동일한 형식**(마이크로초 6자리 + `+00:00`)임을 확인. jsonb 내부 timestamptz 도 같은 규약을 따른다.

## 2.4 Dart 파서 대조 — 캐스트 예외 판정

`lib/models/run_record.dart:35-53` `ClientReportedRun` 은 `@JsonSerializable(fieldRename: FieldRename.snake)` + 4필드 전부 nullable 이다.

| 서버 JSON | 타입 | Dart 필드 | 생성 파서 | 판정 |
|---|---|---|---|---|
| `distance_meters` | number (정수로 렌더될 수 있음) | `double? distanceMeters` | `(json[...] as num?)?.toDouble()` | ✅ `num` 경유라 `0` 이 와도 안전 |
| `moving_seconds` | number | `int? movingSeconds` | `(json[...] as num?)?.toInt()` | ✅ |
| `max_speed_mps` | number 또는 **null** | `double? maxSpeedMps` | `(json[...] as num?)?.toDouble()` | ✅ nullable |
| `recalculated_at` | string `...+00:00` | `DateTime? recalculatedAt` | `DateTime.parse(...)` | ✅ `DateTime.parse` 는 마이크로초 + `±HH:MM` 오프셋을 지원 |
| 컬럼 자체 null | JSON null | `ClientReportedRun?` | 필드 통째 null | ✅ |

**jsonb 가 문자열로 오는 경우 방어도 이미 양쪽에 들어 있다** (QA PLAUSIBLE-1 은 이후 라운드에서 해소된 상태):
- `local_run_repository.dart:749-755` — `_fromRemote` 의 `client_reported is String → jsonDecode` (`samples` 방어와 대칭)
- 같은 파일 `:386-390` — `applyServerConfirmation` 의 `_adoptedKeys` 루프 안 `_jsonbKeys.contains(key) && value is String → jsonDecode`

→ **캐스트 예외 가능성 없음.** §2.2-C 로 PostgREST 가 jsonb 를 객체로 준다는 것이 실측 확인됐고, 설령 문자열로 오더라도 두 경로 모두 방어가 걸려 있다.

## 2.5 UNVERIFIED-1 최종 판정

| 하위 항목 | 판정 |
|---|---|
| PostgREST 가 `runs.client_reported` 컬럼을 인지하는가 | ✅ **실측 확인**(§2.2-B, 42501 vs 42703 대조). G-2 배포 계약 위험 해소 |
| PostgREST 가 jsonb 를 `Map<String,dynamic>` 으로 내려주는가 | ✅ **실측 확인**(§2.2-C, 같은 인스턴스의 `badges.condition`). 컬럼별 차이가 없는 PostgREST 전역 규약이므로 `runs` 에도 동일 적용 |
| `recalculated_at` 이 ISO8601 `+00:00` 인가 | ✅ **실측 확인**(§2.2-C + §2.3) |
| Dart 파서가 캐스트 예외 없이 받는가 | ✅ **판정 완료**(§2.4). 문자열 폴백 방어까지 존재 |
| **`runs.client_reported` 실 데이터 왕복** | 🟡 **여전히 미검증** — non-null 행 0건. **실제 거리 조정이 발생한 기록 1건이 생긴 뒤 재확인 필요** |

남은 🟡 는 **코드 위험이 아니라 관측 공백**이다. 위 4건이 전부 실측으로 닫혔으므로 실 왕복에서 새로 드러날 수 있는 것은 "트리거가 정말 그 분기를 타는가" 하나이며, 그것은 §1.5 의 도심 실기기 러닝 확보와 **같은 시점에 같은 계정으로** 확인하면 된다.

### 실 왕복을 확인할 최소 재현 절차 (제안 — 이번에 실행하지 않음)

64 적용 후 업로드가 0건인 상태를 깨는 것이 유일한 조건이다. **정상 러닝으로는 `client_reported` 가 채워지지 않는다**(클램프 경로) — 재계산이 주장값보다 **작게** 나와야 한다.

1. QA 계정으로 실기기 러닝 1건(도심, 신호등 정지 2회 이상) 업로드
2. `select id, distance_meters, is_flagged, flag_reason, client_reported from public.runs order by created_at desc limit 1;`
3. `client_reported` 가 null 이면 정상(클램프). 채워졌다면 그 id 로 앱 상세 화면 진입 → "기기 기록 N km" 병기가 뜨는지 확인 = **실 왕복 성립**
4. 같은 러닝 데이터로 §1.2/§1.3 재실행 → F-7 신호 축적

⚠️ **프로덕션에 인위적 조작 기록을 넣어 `client_reported` 를 강제로 채우는 방식은 권하지 않는다.** 그 행이 티어·주간랭킹·뱃지 집계에 그대로 편입되고, 64 는 백필을 하지 않으므로 되돌리기가 지저분해진다. 필요하면 **브랜치 DB**(비용 발생 — 사용자 승인 필요)에서 할 것.

---

## 3. 코드·스키마 변경 제안 (이번 라운드에서 실행하지 않음)

| # | 제안 | 우선순위 | 근거 |
|---|---|---|---|
| 1 | **없음 — 이번 진단으로 발생한 변경 제안이 없다** | — | F-7 미확인 → 보정 미착수. 실 왕복의 코드 측 위험은 전부 닫힘 |
| 2 | (문서) `_workspace/20260903_...md` §6.3 과 TRD §14 #27 잔여 ① 의 "베타 20건" 재실행 기준을 **§1.5 의 3조건**으로 구체화 | 낮음 | 이번처럼 "시간은 지났는데 표본이 0" 인 상태에서 재실행이 반복되는 것을 막는다 |
| 3 | (운영) 실기기 도심 러닝 확보를 메모리 `simulator-run-config` / 실기기 검증 묶음에 **F-7 실측 · `client_reported` 실 왕복 겸용 항목**으로 등록 | 중 | 두 잔여 항목의 병목이 동일하다 — 한 번의 실기기 세션으로 둘 다 진전된다 |

## 4. 실행 내역

| 도구 | 대상 | 건수 |
|---|---|---|
| `list_migrations` | `xwtbwexcofcgmbvktwdo` | 1회 (64 가 최신임을 확인) |
| `execute_sql` (읽기 전용) | 표본 현황 / 쿼리 B / 쿼리 A / jsonb 재현 | 4회 (+ 쿼리 A 1회 `round` 타입 에러로 재작성) |
| REST `GET` (anon 키) | `runs`(×3, 401/400) · `badges` · `leaderboard_entries` | 5회 |

**스키마 변경 0건 · 마이그레이션 적용 0건 · 코드 수정 0건 · 커밋 0건.**
