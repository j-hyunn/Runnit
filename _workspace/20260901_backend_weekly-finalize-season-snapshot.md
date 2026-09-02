# 백엔드 — 주간 랭킹 확정 배치 + 과거 시즌 랭킹 스냅샷

| 항목 | 내용 |
|---|---|
| 작업일 | 2026-09-01 |
| 담당 | backend-engineer |
| 대상 | Supabase `Runnit` / `xwtbwexcofcgmbvktwdo` (ap-southeast-1) |
| 신설 마이그레이션 | **57** `20260901120000_57_weekly_ranking_finalization.sql`<br>**58** `20260901120100_58_season_leaderboard_snapshots.sql`<br>**59** `20260901130000_59_season_snapshot_rls_fix.sql` (QA C-1 수정)<br>**60** `20260901140000_60_snapshot_is_voided_column.sql` (TRD #32 해소)<br>**61** `20260901150000_61_season_boundary_short_week.sql` (PRD §8.5 구현 / TRD #30·C-2 해소) |
| 원격 적용 | 57~61 전부 `apply_migration` 완료 |
| 해소한 오픈 이슈 | TRD §14 **#12**·**#23**·**#30**·**#32** (남은 것: **#31**) |
| 근거 | PRD §5.4 / §5.5 GM-07 / §8.2 / §8.5 / §8.6 / RK-06·RK-09·RK-10, ARCHITECTURE §5.3·§13, TRD §2.2·§6.3·§6.4·§9·§14 |

---

## 0. 사전 확인 결과 (선행 조사 확인)

- 로컬·원격 마이그레이션 **00~56 전량 적용 완료**. 추가로 적용할 기존 마이그레이션 없음.
- `docs/ARCHITECTURE.md` §13-1의 "마이그레이션 51 원격 적용만 남음"은 **stale**이었다.
  51은 2026-08-31 적용 완료(TRD v0.13이 이미 정정). **§13-1 서술을 실제 상태로 갱신했다.**
  51 관련 잔여 작업 없음.
- 첫 시즌 2026-Q3 종료는 2026-09-30 → **마감된 시즌 0개**. `season_histories` 0행.
  시즌 스냅샷은 소급 백필 불필요, 전진 구축만.
- `runs` 45건(2026-06-30 ~ 2026-08-28), `leaderboard_entries` weekly/distance/global 18행.

---

## 1. 작업 1 — 주간 랭킹 확정 배치 (TRD §14 #12)

### 1.1 "확정" 신호를 어디에 둘 것인가 — 두 곳에 둔 근거

과제가 "컬럼 또는 별도 테이블 중 하나"를 요구했으나 **둘 다** 두었다. 역할이 다르고,
하나만으로는 둘 중 한쪽 소비자가 답을 못 얻는다.

| 신호 | 위치 | 왜 필요한가 |
|---|---|---|
| 행 단위 확정 도장 | `leaderboard_entries.finalized_at timestamptz` | 뱃지 판정(`evaluate_badge_condition`)이 **술어 한 줄**로 쓰는 hot path. 이 함수는 미획득 뱃지 전량(최대 146종)을 도는 루프 안에서 호출되므로 매번 별도 테이블을 조인하면 비용이 곱해진다 |
| 주×티어 확정 원장 | `weekly_ranking_finalizations(period_start, tier_key, tier, week_id, participant_count, finalized_at, recomputed_at)` PK `(period_start, tier_key)` | **참가자 0명인 티어**를 표현할 수 있는 유일한 곳. 그런 티어는 `leaderboard_entries`에 행 자체가 없으므로 "그 주 플래티넘 보드가 확정됐는데 아무도 없었다"와 "아직 확정 안 됨"을 컬럼만으로는 구분할 수 없다. 작업 2·TRD #23·클라이언트의 "지난 주 확정 랭킹" 질의가 이 테이블을 안정적 신호로 삼는다 |

`finalized_at`이 `refresh_leaderboard`의 upsert `do update set …` 목록에 **없다**는 점이
설계의 핵심이다 — 5분 주기 재집계가 도장을 지우지 않는다.

### 1.2 신설 함수

**`finalize_weekly_ranking(p_at timestamptz default now()) → jsonb`** (SECURITY DEFINER)

1. **대상 주**: `leaderboard_period_bounds('weekly', p_at)`의 시작 − 1시간을 앵커로 직전 주를 잡는다.
   `p_at - interval '1 week'`를 쓰지 않은 이유: 주 중간 수동 실행에서 엉뚱한 주를 잡는다.
2. **(a) 최종 재집계**: 티어 4개 + 통합 보드에 대해 `refresh_leaderboard('weekly','distance','global', null, v_prev_anchor, tier)`.
   타이브레이크는 **기존 로직 재사용** — PRD §8.2 3단계(`run_count asc → reached_at asc → total_moving_seconds asc`) + `user_id asc` 폴백. 확정 시점에 규칙이 갈라지면 주중에 보던 순위와 확정 순위가 달라진다.
3. **(b) 확정 마킹**: `finalized_at = coalesce(finalized_at, now())` + 원장 upsert(전 티어 + `_all`, 0명 포함).
4. **(c) RK-06 지급**: 확정된 그 주의 티어 보드에서 최소 모집단 게이트를 통과하는 사용자만 골라 `evaluate_badges(uid, null)`. 판정 정본은 여전히 `evaluate_badge_condition`이고 여기서는 후보만 좁힌다.
5. **(d) NT-06**: `notify_weekly_rank_badges(p_at)` 호출.

**`notify_weekly_rank_badges(p_at) → integer`** (SECURITY DEFINER)
- dedupe 키 `badge_level:weekly:{week_id}` (사용자당 주 1건), route `/history?tab=badges`(TRD §6-N.7).
- `_batch_hours_ok`로 **자가 게이트**(KST 08~22).
- 대상은 가장 최근 확정된 주. 확정 후 7일이 지나면 발행하지 않는다(배치가 멈췄다 돌아왔을 때 철 지난 알림 차단).

**`_badge_grade_rank(text) → integer`** — 45/50이 인라인 `case`로 쓰던 등급 정렬을 함수화(대표 뱃지 선정용).

### 1.3 NT-06을 확정 시각에 보내지 않은 결정

TRD §6-N.5 "방해 금지"는 배치 계열을 KST 08~22로 제한한다. NT-06이 트리거 계열일 때 심야가
허용된 근거는 "사용자가 방금 러닝을 끝낸 순간"인데, **월요일 00:10 확정은 그 문맥이 아니다.**
그래서 확정(뱃지 지급 포함)과 알림 발행을 분리하고 cron job을 2개 등록했다.
확정 배치도 같은 알림 함수를 호출하지만 그 시각엔 게이트에 걸려 0을 반환하며,
dedupe 키가 같으므로 두 번 호출돼도 알림은 1건이다.

### 1.4 TRD §14 #23 — 실제로 남아 있던 것은 결함 #2 하나

| 결함 | 상태 |
|---|---|
| #1 최소 모집단 게이트 (top1 N≥10 / top10·top10pct N≥20) | **이미 해소돼 있었다 — 마이그레이션 41.** 라이브 `evaluate_badge_condition` 정의를 덤프해 확인함. §14 #23 항목이 stale했다 |
| #2 "확정된 지난 주" 필터 | **미해소였다.** 57이 `season_weekly_rank_lte` 분기에 `and le.finalized_at is not null` 한 줄을 추가해 닫았다 |

> 과제 지시가 참고하라고 한 `_workspace/20260826_000340_gamification_badge-backlog-decisions.md` §6.2는
> 실제로는 **음력 명절 날짜 목록**이었다(문서 구조가 바뀌어 §번호가 어긋난 것으로 보인다).
> 수정 SQL은 그 문서 대신 마이그레이션 41의 라이브 정의를 정본으로 삼아 작성했다.

**패치 방식**: `evaluate_badge_condition`은 24KB·800줄 디스패치 함수라 전문을 다시 싣지 않고,
`pg_get_functiondef`를 읽어 앵커 문자열 한 곳만 치환하는 `DO` 블록으로 적용했다(마이그레이션 42도
같은 함수를 전문 복사한 전례가 있으나 24KB 중복을 피했다). 앵커가 없으면 `raise exception`으로
실패시키고, 이미 적용됐으면 조용히 건너뛴다 — 재실행 안전.

### 1.5 소급 백필 (57-6)

`finalized_at is null`인 과거 주를 그냥 두면 이미 종료된 주까지 판정 대상에서 빠져
정상적으로 받았어야 할 뱃지가 영원히 막힌다. **진행 중인 주를 제외한** 모든 과거 주에
`finalized_at = period_end`를 소급 도장하고 원장에도 적재했다.
현 시드 규모(티어당 1~5명)에서는 아무도 모집단 게이트를 넘지 못하므로 **실제 지급 변화 0건**.

### 1.6 멱등성 (전 단계 확인)

| 단계 | 멱등 장치 |
|---|---|
| 재집계 | `refresh_leaderboard`의 upsert (기존 경로) |
| 확정 도장 | `coalesce(finalized_at, now())` — 최초 확정 시각 보존 |
| 원장 | `on conflict (period_start, tier_key) do update` — `finalized_at` 보존, `recomputed_at`만 갱신 |
| 뱃지 | `evaluate_badges` → `user_badges on conflict (user_id, badge_id) do nothing` |
| 알림 | `enqueue_notification` → `notifications (user_id, dedupe_key)` unique |

---

## 2. 작업 2 — 과거 시즌 전체 랭킹 스냅샷 (PRD RK-10 / HI-06)

### 2.1 테이블

```
public.season_leaderboard_snapshots
  season_id text, user_id uuid → profiles(id) on delete cascade,
  tier public.tier, rank integer,
  season_distance_meters double precision,
  run_count integer, moving_seconds integer, reached_at timestamptz,
  participant_count integer, computed_at timestamptz
  PK (season_id, user_id)
  idx (season_id, tier, rank) / (user_id, season_id desc)
```

RLS: `season_snapshots_select_visible` — `season_histories_select_visible`와 **동일 공개 범위**.
`authenticated`에게 타인 행 공개하되 그 사용자의 해당 시즌 `season_histories.is_voided`면 본인만,
`anon` 차단. INSERT/UPDATE/DELETE 정책 없음 = SECURITY DEFINER 배치만 쓴다.

### 2.2 적재 경로 — `recompute_season_tier`의 `season_histories` 마감 지점

`snapshot_season_leaderboard(p_season_id text) → integer`를 신설하고,
`recompute_season_tier`의 `season_histories` insert **직후**에 존재 검사와 함께 연결했다.

```
if not exists (select 1 from season_leaderboard_snapshots where season_id = v_prev_season) then
  perform snapshot_season_leaderboard(v_prev_season);
end if;
```

- `season_histories`와 **같은 트랜잭션·같은 멱등 규약**(`on conflict do nothing`).
- 존재 검사가 없으면 `reset_stale_seasons`가 N명을 도는 동안 전체 재집계가 N번 돈다.
  PK 선두 컬럼 인덱스 조회라 검사 비용은 사실상 0.

**순서 의존과 그 근거**: 스냅샷은 **가장 먼저 마감되는 사용자의 호출**에서 전체 모집단에 대해
한 번 찍힌다. 그 시점에 나머지 사용자의 `profiles.current_tier`는 아직 지난 시즌 티어이므로
"마감 시점 티어"가 정확히 잡힌다. 그래도 호출 순서에 기대지 않도록 티어를 3단 폴백으로 결정:

1. `season_histories.final_tier` — 이미 마감된 사용자의 불변 정본
2. `profiles.current_tier` (단 `tier_season_id = 그 시즌`일 때만)
3. `tier_for_distance(시즌 거리)` — 티어는 절대평가라 재현 가능
   (⚠️ 강등 없음 규칙(43) 때문에 부정 판정으로 거리가 깎인 사용자는 실제보다 낮게 나올 수 있으나,
   1·2가 동시에 비는 경로는 정상 운영에 없다)

### 2.3 랭킹 산정 기준

주간과 동일한 필터·타이브레이크로 통일: 그 시즌 `runs`의 누적 거리
(`started_at` 귀속(§8.5), `status='completed'`, `is_flagged=false`, `activity_type<>'indoor_run'`(§8.3)),
`tier` 파티션, `거리 desc → run_count asc → reached_at asc → moving_seconds asc → user_id asc`.
`user_id` 폴백이 있어 공동 순위가 없다(§8.2).

### 2.4 클라이언트 매핑 (TRD §4.1 반영)

`RankingEntry` / `SeasonHistory`와 어긋나지 않게 컬럼명을 지었다.
`rank`·`participant_count`·`season_id`는 그대로 대응되고,
`season_distance_meters`만 주간의 `score`와 이름이 다르다 — 시즌 스냅샷은 지표가 거리 하나로
고정(`metric` 컬럼 없음)이라 이름에 단위를 박았다. **클라이언트 소비는 이번 범위 밖.**

### 2.5 첫 마감 자동 적재 경로 추적 (확인 완료)

```
cron jobid 4  runnit-season-reset-30  '5 15 30 6,9 *'   (UTC)
  = 2026-09-30 15:05 UTC = 2026-10-01 00:05 KST
  → reset_stale_seasons(now())
      season_id_at(now()) = '2026-Q4'
      profiles.tier_season_id('2026-Q3') <> '2026-Q4' → 전원 루프
      → recompute_season_tier(uid, now())
          v_prev_season = '2026-Q3'  (profiles.tier_season_id)
          → season_histories insert (on conflict do nothing)
          → [58] not exists → snapshot_season_leaderboard('2026-Q3')
```
스모크 테스트로 이 경로 전체를 실제 실행해 검증했다(§3.2).

---

## 3. 스모크 테스트 결과 (원격, `execute_sql`)

### 3.1 주간 확정 배치

```
select public.finalize_weekly_ranking();
→ {"week_id":"2026-W35","period_start":"2026-08-23T15:00:00+00:00",
   "period_end":"2026-08-30T15:00:00+00:00",
   "entries_marked":2,"badges_awarded":0,"notifications":0}
```
- 대상 주가 정확하다: 실행 시각 2026-09-01(화) KST → 현재 주 8/31~9/6 → 직전 주 8/24~8/30 = W35.
- `badges_awarded=0` — 모집단이 티어당 1~5명이라 게이트(N≥10/20) 미충족. 정상.
- `notifications=0` — 지급된 뱃지가 없어서. `_batch_hours_ok(now())`는 `true`였다(KST 17:31).

**재실행(멱등성)**: 두 번째 호출 결과가 첫 호출과 **완전히 동일**.
원장에서 `finalized_at`은 유지되고 `recomputed_at`만 갱신됨을 확인:

| week_id | tier_key | N | finalized_at | recomputed_at |
|---|---|---|---|---|
| 2026-W35 | _all | 1 | 2026-08-30 15:00 (백필) | 2026-09-01 08:31:44 |
| 2026-W35 | bronze | 1 | 2026-08-30 15:00 (백필) | 2026-09-01 08:31:44 |
| 2026-W35 | gold/platinum/silver | 0 | 2026-09-01 08:31:35 | 2026-09-01 08:31:44 |
| 2026-W34 | _all / bronze / silver / gold / platinum | 8 / 4 / 2 / 1 / 1 | 2026-08-23 15:00 (백필) | 2026-09-01 08:31:15 |

- `select public.notify_weekly_rank_badges();` → `0` (에러 없음, 대상 뱃지 없음).
- 백필 확인: weekly/distance/global 18행 전부 `finalized_at is not null`
  (진행 중인 주에는 애초에 행이 없다 — 마지막 러닝이 8/28).
- 패치 확인: `evaluate_badge_condition` 라이브 정의에 `and le.finalized_at is not null` 존재 → `true`.

### 3.2 시즌 스냅샷 (자가 롤백 테스트)

`DO` 블록 안에서 2026-Q3 마감 시각으로 실제 경로를 태우고 마지막에 `raise exception`으로
전체를 롤백시켰다 — 원격 데이터를 오염시키지 않으면서 실경로를 검증하기 위함.

```
perform public.recompute_season_tier(<첫 profiles.id>, timestamptz '2026-10-05 00:05:00+09');
→ SMOKE snapshot_rows=9 season_histories_rows=1 detail=[
    bronze #1 20100m N=5 | bronze #2 12400m N=5 | bronze #3 9800m N=5 |
    bronze #4 8100m N=5 | bronze #5 1502m N=5 |
    silver #1 33000m N=2 | silver #2 32200m N=2 |
    gold #1 115300m N=1 | platinum #1 252500m N=1 ]
```

검증된 것:
- **사용자 1명의 recompute가 전체 모집단(9명) 스냅샷을 찍는다** — 나머지 8명은 아직
  `season_histories` 행이 없었고 폴백 ②(`profiles.current_tier`)로 마감 시점 티어가 잡혔다.
- 티어별 파티션(bronze 5 / silver 2 / gold 1 / platinum 1), 티어 내 순위 1..N **중복 없음**,
  `participant_count`가 티어별로 정확.
- `season_histories`는 호출한 그 1명만 마감(정상 — 나머지는 자기 차례에 마감된다).

**롤백 확인**: `season_leaderboard_snapshots` 0행, `season_histories` 0행,
`profiles where tier_season_id <> '2026-Q3'` 0명 → 원격 상태 무변화.

### 3.3 cron 등록 확인

```
runnit-weekly-finalize            @ 10 15 * * 0   (월 00:10 KST)
runnit-weekly-rank-badge-notify   @ 0 23 * * 0    (월 08:00 KST)
```
기존 `runnit-leaderboard`(`*/5 * * * *`), `runnit-rank-notify`, 시즌 리셋 job 2개는 **그대로 유지**.

### 3.4 advisors

| 종류 | 결과 |
|---|---|
| security | (57·58 시점) WARN 6건 — 전부 **기존 항목**(`rls_auto_enable`, `mark_notifications_read`, `register_push_token`, `sync_my_season`의 SECURITY DEFINER 노출 + leaked password protection). **신규 경보 0건** — 신설 함수 4종은 전부 `revoke execute … from public, anon, authenticated` 적용됨. **59 적용 후 신규 1건** — `_season_history_voided`의 RPC 노출(불가피, §4-A 참조, TRD §14 #32) |
| performance | 신규는 INFO `unused_index` 2건뿐(`idx_weekly_ranking_finalizations_week`, `idx_season_snapshots_user`) — 새 테이블이라 아직 질의된 적이 없어 당연하다. WARN은 기존 `user_badges` multiple permissive policies 1건 |

### 3.5 Flutter

- `flutter analyze` → **No issues found**
- `flutter test` → **279/279 통과**
- (주의: 이 워크트리는 `build_runner` 산출물이 없어 최초 `flutter analyze`가 578 에러를 냈다.
  `dart run build_runner build --delete-conflicting-outputs` 후 정상. 스키마 변경과 무관한 환경 이슈)
- 이번 변경은 **Dart 코드 무수정**. 신설 컬럼/테이블은 `wire_enums` 대조 대상이 아니다
  (새 enum 값이 없고, `leaderboard_entries.finalized_at`은 `json_serializable`이 미지 키로 무시).

---

## 4. 변경 파일 (커밋하지 않음)

```
?? supabase/migrations/20260901120000_57_weekly_ranking_finalization.sql
?? supabase/migrations/20260901120100_58_season_leaderboard_snapshots.sql
?? supabase/migrations/20260901130000_59_season_snapshot_rls_fix.sql
?? supabase/migrations/20260901140000_60_snapshot_is_voided_column.sql
?? supabase/migrations/20260901150000_61_season_boundary_short_week.sql
 M docs/TRD.md            (v0.22)
 M docs/ARCHITECTURE.md   (v0.16)
```

문서 갱신 내역:
- **TRD** v0.21 — (v0.20)  §6.3 전면 재작성(신선도/확정 2층 구조 + job 표), §6.4 전면 재작성
  (폐기된 `seasons`/`user_season_tier` 초안 명시 + 실제 경로 + 스냅샷 연결),
  §9에 확정 배치·시즌 스냅샷 2항목 추가, §4.1 매핑표에 7행 추가,
  §14 #12·#23 **취소선 처리(해소)**, 변경 이력. **v0.21**: §14 #11 정정(레거시 지급 3건), #30(C-2 시즌 말 걸친 주)·#31(무효 시즌 rank 구멍) 신규 등재.
- **ARCHITECTURE** v0.15 — (v0.14)  §5.3에 확정 배치·시즌 스냅샷 서술 추가, §5.5 RLS 표에 2행 추가,
  §13 도입부 마이그레이션 범위 00~48 → 00~58, **§13-1 stale 정정**(51 적용 완료),
  §13-4 갱신(스냅샷 백엔드 완료, 남은 것은 클라이언트 UI), 변경 이력. **v0.15**: §5.5 `season_leaderboard_snapshots` 행 정정 — "동일 공개 범위"가 정책 **형태**의 차이를 가렸다는 점 명시 + 인라인 서브쿼리 되돌림 금지 경고.

---

## 4-A. QA 지적 반영 (`_workspace/20260901_qa_weekly-finalize-season-snapshot.md`)

QA 판정: PASS 12 / CONFIRMED 3(blocking 1) / PLAUSIBLE 4 / 관측 대기 3.

### 🔴 C-1 (blocking) — 수정 완료, 마이그레이션 59

58의 `season_snapshots_select_visible`가 무효 시즌 차단을 **정확히 반대로** 하고 있었다.

정책이 `season_histories`를 **인라인 서브쿼리**로 조회했는데, **RLS 정책식 안의 서브쿼리는
참조 테이블의 RLS를 그대로 받는다**(정책 소유자가 아니라 호출자 권한으로 평가).
`season_histories_select_visible`가 `(is_voided = false) or (user_id = auth.uid())`이므로
타인의 무효 시즌 행은 그 서브쿼리에게도 보이지 않는다 → `not exists`가 항상 참 →
**무효 시즌 스냅샷이 전원에게 공개**. `season_histories`가 감추는 결과를 스냅샷이 대신
노출해 무효 처리의 의미가 사라지는 상태였다.

내가 이걸 놓친 이유는 **"`season_histories`와 동일 공개 범위"를 목표로 삼으면서 정책의
형태 차이를 보지 않았기 때문**이다 — `season_histories` 쪽은 같은 테이블의 컬럼 술어라
서브쿼리가 없고, 이쪽만 교차 테이블 참조였다. 범위가 같다는 서술이 그 구조 차이를 가렸다.

수정: SECURITY DEFINER 헬퍼 `_season_history_voided(uuid, text)`로 그 평가를 RLS 밖으로
빼고 정책을 교체. `revoke … from public, anon` + `grant … to authenticated`(정책 평가에
호출자 EXECUTE가 필요). 58은 이미 적용됐으므로 amend하지 않고 **59로 신설**했다.

**재현·검증 (트랜잭션 내 삽입 후 롤백, 타인/본인 계정 전환)**

| 지표 | 59 이전 | 59 이후 |
|---|---|---|
| `snapshot_visible_to_other` (타인의 **무효** 시즌 스냅샷) | **1** 🔴 | **0** ✅ |
| `history_visible_to_other` (대조군, `season_histories`) | 0 | 0 |
| `valid_season_visible_to_other` (타인의 **정상** 시즌 — 과차단 회귀 확인) | — | **1** ✅ |
| `voided_visible_to_owner` (본인의 무효 시즌 — 본인 열람 유지) | — | **1** ✅ |

즉 차단이 정상화되면서 정상 시즌 공개도, 본인의 무효 시즌 열람도 깨지지 않았다.

### 🟠 C-2 — 수정하지 않고 등재만 (지시대로)

시즌 말 "걸친 주"의 RK-06이 `season_id_at(now())` 때문에 영영 지급되지 않는다.
근본 원인은 **PRD §8.5 "시즌 말 단축 주간"이 미구현**이라는 것이고 스펙 확정이 필요한
사용자 확인 사항이라 코드를 건드리지 않았다. **TRD §14 #30**으로 등재(수정 방향 후보
A/B 포함). 57 이전에도 같은 `now()` 기준 시즌을 썼으므로 신규 결함은 아니지만, 57이
지급 시점을 확정 배치로 못박으면서 누락이 **결정적**이 됐다.

### 🟡 C-3 — 문구 정정 완료

57-6 백필 주석의 "아무도 이 뱃지를 못 받은 상태"는 사실이 아니었다. 라이브에
`season_weekly_rank` 뱃지 **3건**이 이미 있다(user `…00a8`, 2026-08-25 부여, 플래티넘
위클리킹/탑텐/라이징 — 전부 `participant_count = 1` 보드에서 나간 **마이그레이션 41
이전의 레거시 지급**). 57이 만든 문제가 아니고 백필로 추가 지급도 없었다(멱등 확인).
57 파일 주석 + 이 보고서 R-2 + TRD §14 #11을 사실에 맞게 정정했다. 회수 여부는
gamification-designer 판단이라 데이터는 건드리지 않았다.

### 부수 논점 — TRD §14 #31 등재

무효 시즌 사용자를 **숨기기만 하면** 그 티어의 `rank`·`participant_count`에 구멍이 남는다
(3위가 무효면 1·2·4위로 보이고 모집단은 그대로 센다). 진짜 무효 처리라면 재산정 또는
재랭크가 필요하다 — 소비 UI가 없어 실피해는 없고 RK-10 UI 라운드에서 확정한다.

### C-1 수정이 남긴 것 — advisor 신규 WARN 1건 (수용, TRD §14 #32)

`get_advisors(security)`에 **신규 1건**이 생겼다:
`_season_history_voided(uuid, text)` can be executed by `authenticated` via `/rest/v1/rpc/...`.

**불가피하다.** RLS 정책식은 **호출자 권한**으로 평가되므로 정책이 부르는 SECURITY DEFINER
헬퍼에는 `grant execute to authenticated`가 필수이고, `public` 스키마 함수는 PostgREST가
자동 노출한다. 결과적으로 uuid를 아는 사용자가 임의 `(user_id, season_id)`의 무효 여부를
boolean으로 조회할 수 있다 — 좁지만 **부정 판정 플래그의 노출**이고, 하필 `season_histories`
RLS가 감추려던 바로 그 사실이다.

근본 해법은 헬퍼를 **PostgREST에 노출되지 않는 별도 스키마**(`private` 등)로 옮기는 것인데,
이 프로젝트에는 그런 스키마 규약이 아직 없다(확인함 — `public` 외 앱 스키마 없음).
도입은 `db reset`·브랜치 DB·PostgREST 노출 스키마 설정에 영향을 주는 **별도 결정**이라
blocking 수정을 붙잡아 두지 않고 `public` 유지 + **TRD §14 #32 등재**로 처리했다.
`get_advisors(performance)`는 신규 WARN 없음(INFO `unused_index`만).

### QA의 PLAUSIBLE 4건 — 수정 없음, 판단 근거

| # | 판단 |
|---|---|
| L-1 (확정 시 "월 00:10 시점 티어"로 재파티션) | 57 이전 5분 배치도 동일 동작이라 신규 아님. PRD §8.6 이관 규칙의 연장이고 창이 10분 |
| L-2 (일요일 시작 + 월 00:10 이후 업로드 러닝은 어느 주에도 안 들어감) | ARCHITECTURE §9.1의 확정 정책과 일관. 다만 §9.1 문구가 "현 주에 귀속"이라 정밀하지 않다는 지적은 타당 — **오프라인 동기화 문맥의 서술이라 이번 라운드 범위 밖으로 두고 남긴다** |
| L-3 (`season_histories.distance_meters`는 profiles 스냅, 스냅샷은 runs 재집계) | 타당. 어느 쪽이 정본인지는 HI-06 UI 라운드에서 정할 사항 |
| L-4 (NT-06이 08:00 job 1회라 그 사이 획득분만 알림) | 확정 배치가 자격자를 전원 선평가하므로 정상 경로에 빈틈 없음. 57 이전엔 발화점 자체가 없었으므로 순개선 |

---

## 4-B. 후속 라운드 — 마이그레이션 60·61 (사용자 승인)

### 마이그레이션 60 — TRD §14 #32 해소 (옵션 B)

59는 C-1을 SECURITY DEFINER 헬퍼로 고쳤지만 대가가 있었다: **RLS 정책식은 호출자 권한으로
평가**되므로 헬퍼에 `grant execute to authenticated`가 필수이고, `public` 스키마 함수는
PostgREST가 자동 노출한다 → uuid를 아는 사용자가 임의 `(user_id, season_id)`의 무효 여부를
boolean으로 조회할 수 있었다(= 부정 판정 플래그 probe, advisor 신규 WARN 1건).

**옵션 B: 교차 테이블 참조 자체를 없앤다.**

| 변경 | 내용 |
|---|---|
| 컬럼 | `season_leaderboard_snapshots.is_voided boolean not null default false` — 적재 시점에 `season_histories.is_voided`를 복사 |
| 정책 | `is_voided = false or user_id = (select auth.uid())` — `season_histories_select_visible`와 **같은 형태의 순수 컬럼 술어** |
| 헬퍼 | `_season_history_voided()` **DROP** → RPC 노출 소멸 |
| 정합 | `set_season_history_voided(user_id, season_id, voided)` 신설 — 두 테이블을 한 트랜잭션에서 갱신하는 **단일 진입점** |

부수 효과로 두 테이블의 정책이 **같은 모양**이 되어, 59가 지적한 "형태가 달라서 생긴 반전"
함정 자체가 사라졌다(다시 서브쿼리를 쓸 유인이 없다).

**왜 단일 진입점까지 만들었나**: `is_voided`는 마감 **이후에** 세워질 수 있는데, 검색 결과
이 프로젝트에는 그 플래그를 **세우는 코드 경로가 아예 없다**(읽기 2곳 + RLS뿐, 쓰기는 순수
수동 SQL). "무효 판정 시 스냅샷도 같이 갱신하라"를 주석으로만 남기면 반드시 잊히고, 그때
스냅샷은 계속 공개된 채 남는다. 함수 하나가 그 실수를 구조적으로 막는다.

**검증** (트랜잭션 삽입 → `set_season_history_voided()` 호출 → 계정 전환 조회 → 롤백):

| 지표 | 결과 |
|---|---|
| `snapshot_visible_to_other` (타인의 무효 시즌) | **0** ✅ |
| `history_visible_to_other` (대조군) | 0 ✅ |
| `valid_season_visible_to_other` (타인의 정상 시즌 — 과차단 회귀) | **1** ✅ |
| `voided_visible_to_owner` (본인의 무효 시즌) | **1** ✅ |
| `helper_fn_remaining` | **0** ✅ |
| advisor security | **기존 6건으로 원복** ✅ |

---

### 마이그레이션 61 — PRD §8.5 "시즌 말 단축 주간" 구현 (TRD #30 / QA C-2)

PRD §8.5에 스펙이 있었으나 구현된 적이 없었다(= PRD 변경 아님, 미구현 스펙의 구현).

**설계 1 — 주를 새 개념으로 만들지 않고 시즌으로 자른다.**
`leaderboard_period_bounds('weekly', anchor)` = `[max(주시작, 시즌시작), min(주끝, 시즌끝))`.
이 한 줄이 나머지를 전부 자동으로 만든다 — 주는 분기 경계를 최대 1번 넘으므로 조각은 2개
이하이고, 조각마다 `period_start`가 달라 `leaderboard_entries`의 유니크 키가 **스키마 변경
없이** 별개 기간으로 다룬다. `season_id_at(period_start)`가 조각의 시즌을 유일 결정하고,
`recompute_season_tier`의 `best_weekly_rank` 서브쿼리·러닝 귀속(`started_at`)·§8.6 승급 이관은
손대지 않아도 맞는다. **weekly만** 클램프한다(`all_time`은 클램프하면 망가진다).

**설계 2 — 주 키 충돌.** 두 조각은 같은 ISO 주라 dedupe 키(`rank_change:{week}`,
`badge_level:weekly:{week}`)가 충돌해 **둘째 조각의 알림이 조용히 사라진다.** `week_id_at()`이
걸친 주에만 `@{season_id}`를 붙이도록 바꿨다 — 안 걸친 주는 **출력이 한 글자도 안 바뀌어**
기존 이력·dedupe와 호환된다.

**설계 3 — C-2의 진짜 원인.** 클램프만으로는 부족했다. `evaluate_badge_condition`은
`season_id_at(now())`, 즉 **판정을 실행하는 순간의 시즌**을 봤다. 정답은 **판정 중인 뱃지
인스턴스의 시즌**이다(`srank_gold_top1@2026-Q3`는 `badges.season_id`를 들고 있는데 디스패치가
`(user_id, condition_type, condition)`만 넘겨 그 정보가 도달하지 못했다). `evaluate_badges`가
뱃지마다 `runnit.badge_season` GUC에 실어 넘기게 했다(§6-N `_notify_ctx`와 같은 관용 — 4번째
인자를 추가하면 3인자 호출이 모호해지고 24KB 함수를 통째로 재정의해야 한다).

> 🔴 **C-2보다 넓은 잠재 결함을 함께 닫았다.** 미획득으로 남은 과거 시즌 인스턴스가 현재
> 시즌 데이터로 재판정되고 있었다 — `evaluate_badges`는 미획득 뱃지를 매 러닝마다 다시
> 돌므로 **Q4 성적으로 Q3 뱃지가 발급될 수 있었다.** `season_*` 조건 전체가 대상이었다.

**설계 4 — 확정 배치가 "직전 1개"로는 성립하지 않는다.** 클램프 후 월요일 배치의 직전 기간은
**신시즌 조각**이라, 구시즌 조각은 어떤 월요일 실행의 직전 기간도 되지 못해 **영영 확정되지
않는다.** 그래서 "끝났는데 미확정인 모든 주간 기간"을 확정하도록 바꿨다(KST 자정 앵커 되짚기,
**14일** 폭). 이미 확정된 기간은 **건너뛴다** — 재집계하면 그 시점의 티어로 과거 순위가 다시
쓰여 확정의 의미가 사라진다(QA L-1이 과거 주로 번지는 것도 이걸로 막힌다). 14일보다 길게
잡지 않는 이유: 한 번도 집계된 적 없는 오래된 주의 보드를 **오늘의 티어로 합성**하게 된다.

**확정 시점 (PRD 미명시 → 결정)**: `reset_stale_seasons()`(분기 첫날 00:05 KST)가 **리셋 루프
보다 먼저** 확정 배치를 부른다. 순서가 중요하다 — 루프가 `profiles.current_tier`를 신시즌
bronze로 내리기 전에 확정해야 티어 파티션이 구시즌 값으로 잡힌다. 그러면 구시즌 조각이 시즌
마감과 같은 순간에 확정되고 RK-06도 그때 나간다. 월요일 배치의 되짚기는 안전망.

**NT-06**: 시즌 경계에서 두 조각이 다른 날 확정되므로 "가장 최근 1개"만 보면 한쪽이 통째로
누락된다. **최근 7일 안에 확정된 주 전부**를 돌며 각 주의 **시즌 인스턴스 뱃지만** 귀속하도록
바꿨다(`b.season_id = season_id_at(period_start)`).

#### 스모크 결과 — 2026-Q3 종료 주

> ⚠️ 지시문에 "2026-09-30 화요일 / 주 9/29~10/5"로 적혀 있었으나 **실제로는 09-30이 수요일**이고
> 그 주는 **09-28(월) ~ 10-05(월)**이다. 아래는 DB로 확인한 실제 값이다.

기간 클램프 / 주 키:

| 앵커 | period | 기간(KST) | 길이 | 시즌 | week_id |
|---|---|---|---|---|---|
| 09-29 | weekly | `[09-28 00:00, 10-01 00:00)` | 3일 | 2026-Q3 | `2026-W40@2026-Q3` |
| 10-02 | weekly | `[10-01 00:00, 10-05 00:00)` | 4일 | 2026-Q4 | `2026-W40@2026-Q4` |
| 08-26 | weekly | `[08-24, 08-31)` | 7일 | 2026-Q3 | `2026-W35` (**불변**) |
| 10-07 | weekly | `[10-05, 10-12)` | 7일 | 2026-Q4 | `2026-W41` (**불변**) |
| 09-30 | daily | `[09-30, 10-01)` | 1일 | — | 클램프 안 됨 ✅ |
| 09-30 | monthly | `[09-01, 10-01)` | 30일 | — | 클램프 안 됨 ✅ |
| 09-30 | all_time | `1970-01-01 ~ 10000-01-01` | — | — | **보존** ✅ |

확정·판정·지급 (러닝 2건 삽입 → 롤백):

| 단계 | 결과 |
|---|---|
| ① 롤오버 `reset_stale_seasons('2026-10-01 00:05+09')` | 구시즌 조각 `2026-W40@2026-Q3` 확정(원장 5행 = 4티어 + `_all`), Q3 스냅샷 9행 |
| ② 월요일 `finalize_weekly_ranking('2026-10-05 00:10+09')` | `2026-W40@2026-Q4` 확정, `shortened: true`, `entries_marked=2` |
| ③ 판정 시즌 컨텍스트 | Q3 조각을 **Q3 인스턴스로 판정 = true**, **Q4 인스턴스로 판정 = false** — 시즌 컨텍스트가 실제로 결과를 가른다 |
| ④ 실지급 | `srank_bronze_top1@2026-Q3` 발급 (before 0 → after 1). **구 코드에서는 불가능했던 경로** |

회귀·라이브 상태:

| 항목 | 결과 |
|---|---|
| 평범한 주 확정 경로 | `2026-W35`, `shortened: false`, 원장 5행 재생성 ✅ (롤백) |
| 라이브 `finalize_weekly_ranking()` 2연속 | `weeks_finalized=0` 동일 — 이미 확정된 주 건너뜀, 과거 보드 합성 없음 ✅ |
| 라이브 데이터 무변화 | snapshots 0 / histories 0 / user_badges 199 / runs 45 / ledger 10 / off_season 0 / helper 0 ✅ |
| cron | `runnit-weekly-finalize @ 10 15 * * 0`, `runnit-weekly-rank-badge-notify @ 0 23 * * 0`, `runnit-season-reset-30/31` 유지 ✅ |
| advisor security | WARN **6건**(전부 기존), 신규 0 ✅ |
| advisor performance | 신규 WARN 0 (INFO `unused_index`만) ✅ |
| `flutter analyze` / `flutter test` | No issues / **279 통과** ✅ |

---

## 5. 남은 리스크 · 미해결

| # | 항목 | 성격 |
|---|---|---|
| R-1 | **확정 배치가 실제 주 경계에서 도는 것은 아직 관측되지 않았다.** 첫 정시 실행은 2026-09-07(월) 00:10 KST. 수동 호출로 로직은 검증했으나 cron 실행 자체는 `cron.job_run_details`로 그때 확인해야 한다 | 관측 대기 |
| R-2 | **RK-06 뱃지 지급은 실데이터로 검증되지 않았다** — TRD §14 #11과 동일 제약. 모집단이 티어당 1~5명이라 게이트(N≥10/20)를 넘는 사용자가 없다. 판정·지급 경로는 코드로 확인했으나 **57 경로로** `user_badges` 삽입이 일어난 적은 없다. ⚠️ **정정(QA C-3)**: 초판에 쓴 "지급된 적 없다"는 틀렸다 — 라이브에 마이그레이션 41 이전의 레거시 지급 3건이 존재한다(§4-A C-3). 베타 20명 확보 시 재검증 | #11에 종속 |
| R-3 | **NT-06 주간 알림도 같은 이유로 미발화.** dedupe 키 `badge_level:weekly:{week_id}`의 실사용 검증은 R-2 이후. TRD §14 #25(알림 실기기 검증)에 이 항목을 추가하는 것이 맞다 | #25 확장 |
| R-4 | 시즌 스냅샷의 **첫 실적재는 2026-09-30**. 롤백 테스트로 경로·순위·모집단을 검증했으나 실제 마감은 아직 없다. 그날 `season_leaderboard_snapshots` 행 수와 `season_histories` 행 수가 일치하는지(정확히는 거리>0인 사용자 수와) 확인 필요 | 관측 대기 |
| R-5 | 티어 3단 폴백 ③(`tier_for_distance`)은 **강등 없음 규칙과 어긋날 수 있다** — 부정 판정으로 거리가 깎인 사용자에게 실제 마감 티어보다 낮은 값이 나온다. ①②가 동시에 비는 경로가 정상 운영에 없으므로 실피해는 없지만, 폴백이 실제로 쓰이면 그건 이상 상황이라는 신호다 | 설계상 수용 |
| R-6 | 57-5의 `DO` 블록 패치는 `evaluate_badge_condition` 본문의 앵커 문자열에 의존한다. 앞으로 이 함수를 전문 재정의하는 마이그레이션(42 같은)이 오면 **`finalized_at` 필터가 조용히 사라질 수 있다** — 그 마이그레이션 작성자가 필터를 포함시켜야 한다. 앵커 부재 시 예외를 던지도록 해 두었으나 그건 재적용 때만 걸린다 | 운영 주의 |
| R-7 | `weekly_ranking_finalizations` / `season_leaderboard_snapshots` 모두 **클라이언트 소비자가 아직 없다.** 별도 UI 라운드가 필요하며(HI-06 "과거 시즌 전체 랭킹" 탭, RK-10), 그때 `RankingEntry` 재사용 여부를 mobile-architect와 확정해야 한다 | 후속 UI 라운드 |
| R-9 | **`week_id_at()`의 `@{season}` 접미사는 걸친 주에만 붙는다.** 걸치지 않는 주는 출력이 불변이라 기존 이력과 호환되지만, **클라이언트가 week_id를 파싱한다면** `2026-W40@2026-Q3` 형태를 처리해야 한다. 현재 소비자는 서버(원장·dedupe 키)뿐이고 클라이언트는 이 값을 읽지 않는다(확인함) — RK-10/HI-06 UI 라운드에서 노출한다면 그때 파싱 규약을 정할 것 | 후속 UI 라운드 |
| R-10 | **확정 배치의 14일 되짚기는 그보다 오래 멈춘 크론을 복구하지 못한다.** 의도된 상한이다(더 길게 잡으면 한 번도 집계된 적 없는 과거 주의 보드를 오늘의 티어로 합성한다). 크론이 2주 넘게 멈추면 그 구간의 주는 영구 미확정으로 남고 RK-06도 안 나간다 — `cron.job_run_details` 모니터링이 실질적 방어선 | 운영 모니터링 |
| R-11 | **`runnit.badge_season` GUC는 `evaluate_badges` 경유 호출에만 실린다.** `evaluate_badge_condition`을 직접 부르는 경로가 생기면 GUC가 비어 `season_id_at(now())`로 폴백한다(구 동작). 현재 직접 호출부는 없다 | backend-engineer |
| R-12 | **앵커 치환 패치가 이제 2건이다**(57-5 `finalized_at` 필터, 61-3 `badge_season` GUC). `evaluate_badge_condition`을 전문 재정의하는 마이그레이션이 오면 **둘 다** 조용히 사라진다. R-6의 확대판이며, QA가 권고한 회귀 가드(두 문자열의 존재를 검사하는 테스트)를 두는 것이 맞다 | 🔴 backend-engineer, 회귀 가드 |
| R-8 | 확정 배치는 `weekly`/`distance`/`global` 보드만 확정한다. `crew` 스코프와 `duration`/`run_count` 지표는 확정 대상이 아니다 — PRD가 요구하는 주간 랭킹이 "티어 내 주간 누적 거리" 단독이고 크루는 P2이기 때문. 의도된 범위 한정 | 설계상 수용 |
