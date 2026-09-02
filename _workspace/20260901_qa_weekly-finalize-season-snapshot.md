# QA 경계 정합성 검증 — 마이그레이션 57·58 (주간 랭킹 확정 배치 / 시즌 랭킹 스냅샷)

| 항목 | 내용 |
|------|------|
| 검증일 | 2026-09-01 |
| 검증자 | qa-integration-tester |
| 대상 | 미커밋 변경 5건 (마이그레이션 57·58, TRD v0.20, ARCHITECTURE v0.14, backend 보고서) |
| 원격 DB | `xwtbwexcofcgmbvktwdo` (57·58 모두 `supabase_migrations` 에 적용 완료 확인) |
| 최종 판정 | 🔴 **커밋 전 1건 수정 필요** (C-1). 나머지는 커밋 후 후속 |

---

## 0. 요약

| 분류 | 건수 |
|------|------|
| PASS | 12 |
| CONFIRMED (코드로 재현) | 3 (blocking 1) |
| PLAUSIBLE | 4 |
| 검증 불가 / 관측 대기 | 3 |

**blocking: C-1 하나뿐이다.** `season_leaderboard_snapshots` 의 RLS 정책이 의도와 **정반대로 동작**하는 것을 라이브에서 재현했다. 나머지 CONFIRMED 2건은 지급 누락·문서 부정확이라 커밋을 막지 않는다.

---

## 1. CONFIRMED

### 🔴 C-1 (blocking) — `season_snapshots_select_visible` 의 무효 시즌 차단이 반전된다

**위치**: `supabase/migrations/20260901120100_58_season_leaderboard_snapshots.sql:86-97`
**문서 모순**: `docs/ARCHITECTURE.md:318` — "그 사용자의 해당 시즌 `season_histories.is_voided`면 본인만"

정책이 `season_histories` 를 **서브쿼리로 조회**한다:

```sql
or not exists (
  select 1 from public.season_histories sh
  where sh.user_id = season_leaderboard_snapshots.user_id
    and sh.season_id = season_leaderboard_snapshots.season_id
    and sh.is_voided
)
```

RLS 정책식 안의 서브쿼리는 **참조 테이블의 RLS 를 그대로 받는다**(정책 소유자가 아니라 호출자 권한으로 평가). `season_histories_select_visible` 는 `(is_voided = false) OR (user_id = auth.uid())` 이므로, **타인의 무효 시즌 행은 서브쿼리에게도 안 보인다** → `not exists` 가 `true` → 스냅샷 행이 **모두에게 공개**된다.

**라이브 재현** (트랜잭션 내 삽입 후 rollback):

```
snapshot_visible_to_other = 1   ← 타인의 무효 시즌 스냅샷이 보인다 (버그)
history_visible_to_other  = 0   ← season_histories 는 정상 차단
```

즉 `season_histories` 는 감추는 무효 시즌 결과를, 스냅샷이 대신 노출한다. 부정 판정 사용자의 시즌 순위가 그대로 남는 셈이라 무효 처리의 의미가 사라진다.

`season_histories_select_visible` 는 **같은 테이블의 컬럼 검사**라 이 문제가 없다 — "동일 공개 범위"라는 표현이 정책 형태의 차이를 가렸다.

**수정 SQL 제안** (SECURITY DEFINER 헬퍼로 서브쿼리를 RLS 밖으로 뺀다):

```sql
create or replace function public._season_history_voided(p_user_id uuid, p_season_id text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.season_histories sh
     where sh.user_id   = p_user_id
       and sh.season_id = p_season_id
       and sh.is_voided
  );
$$;

revoke execute on function public._season_history_voided(uuid, text) from public, anon;
grant  execute on function public._season_history_voided(uuid, text) to authenticated;  -- 정책 평가에 필요

drop policy if exists season_snapshots_select_visible on public.season_leaderboard_snapshots;
create policy season_snapshots_select_visible
  on public.season_leaderboard_snapshots
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or not public._season_history_voided(user_id, season_id)
  );
```

검증 방법: 위 재현 쿼리를 다시 돌려 `snapshot_visible_to_other = 0` 을 확인.

> ⚠️ 부수 논점(설계): 무효 시즌 사용자가 스냅샷에서 **숨겨지기만 하면 그 티어의 `rank`·`participant_count` 에 구멍이 남는다**(3위가 안 보여서 1,2,4위로 보임). 진짜 무효 처리라면 스냅샷 재산정 또는 `is_voided` 반영 후 재랭크가 필요하다. RK-10 UI 라운드에서 gamification-designer 와 확정할 것.

---

### 🟠 C-2 — 시즌 말 "걸친 주"의 RK-06 뱃지는 영영 지급되지 않는다

**위치**: `evaluate_badge_condition` 라이브 정의 (`v_season := public.season_id_at(now())`) ↔ `finalize_weekly_ranking()` 의 확정 시점

- 시즌 경계는 분기 1일(10/1), 주 경계는 월요일. **거의 매 시즌 마지막 주가 두 시즌에 걸친다.**
- 예: 2026-Q3 종료 = 10/1 00:00 KST. 주 `2026-09-28 ~ 10-04` 의 `period_start` 는 9/28 → Q3 소속.
- 이 주의 확정 배치는 **10/5(월) 00:10** 에 돈다. 그 시각 `evaluate_badge_condition` 의 `v_season` 은 이미 **Q4** 이므로 `le.period_start >= v_season_start`(10/1) 를 통과하지 못한다.
- 결과: 그 주의 1위/탑텐/상위10%는 Q3 뱃지도 Q4 뱃지도 받지 못한다.

57 이전에도 "다음 러닝 때 평가" 경로가 같은 `now()` 기준 시즌을 썼으므로 **신규 결함은 아니다.** 다만 57 이 지급 시점을 확정 배치로 못박으면서 이 누락이 **결정적(deterministic)** 이 됐다.

추가로 **PRD §8.5 "시즌 종료일이 주 중간이면 해당 주간 랭킹은 단축 운영"이 아직 구현되어 있지 않다** — `leaderboard_period_bounds('weekly', ...)` 는 항상 완전한 월~일 주를 돌려준다. C-2 는 이 미구현의 파생 증상이다.

**권고**: 커밋을 막지 않는다. TRD §14 에 신규 이슈로 등재하고(§8.5 단축 주간 미구현 + RK-06 누락), 스펙 확정이 필요하면 사용자 확인 후 처리. 수정 방향 후보 2가지:
- (A) `evaluate_badge_condition` 이 `season_id_at(now())` 대신 **판정 대상 뱃지 인스턴스의 `badges.season_id`** 를 쓰도록 시그니처 확장 — 근본 수정이지만 파급이 크다.
- (B) `finalize_weekly_ranking` 이 시즌 경계에 걸린 주를 감지해 `season_end` 로 잘린 **단축 주**를 별도 `period_start` 로 확정 — PRD §8.5 정본에 맞지만 `leaderboard_entries` 의 주 키 규약을 바꾼다.

---

### 🟡 C-3 — 마이그레이션 57-6 백필 주석의 사실관계가 틀렸다

**위치**: `20260901120000_57_weekly_ranking_finalization.sql:388`
> "현 시드 규모에서는 아무도 이 뱃지를 못 받은 상태라 실제 지급 변화는 없지만"

라이브에는 **`season_weekly_rank` 뱃지 3건이 이미 지급되어 있다** (`user_id 0000…00a8`, 2026-08-25 13:42:03 부여, `revoked=false`, `verified=true`):

| 뱃지 | bucket | 당시 보드 |
|------|--------|-----------|
| 플래티넘 위클리킹 | top1 | platinum `participant_count = 1` |
| 플래티넘 탑텐 | top10 | platinum `participant_count = 1` |
| 플래티넘 라이징 | top10pct | platinum `participant_count = 1` |

모집단 1명 보드에서 나간 **마이그레이션 41(모집단 게이트) 이전의 레거시 지급**이다. 57 이 새로 만든 문제는 아니고, 백필로 인해 추가 지급이 일어나지도 않는다(멱등 테스트에서 3건 유지 확인). 다만 **주석·backend 보고서 R-2 의 "지급된 적 없다"는 전제는 사실이 아니다.**

**권고**: 코드 수정 불필요. 보고서/TRD 문구만 정정하고, 이 3건을 회수할지(시드 데이터라 무해하다면 방치) gamification-designer 와 판단.

---

## 2. PASS (라이브 대조 완료)

| # | 항목 | 근거 |
|---|------|------|
| P-1 | **R-6 앵커 치환이 실제 적용됨** | `pg_get_functiondef(evaluate_badge_condition)` 덤프에 `and le.finalized_at is not null` 이 `season_weekly_rank_lte` 분기에만 정확히 삽입되어 있음 |
| P-2 | **최소 모집단 게이트 생존** | 같은 덤프에 `top1: pc>=10 and rank=1` / `top10: pc>=20 and rank<=10` / `top10pct: pc>=20 and rank<=ceil(pc*0.10)` 원형 유지 |
| P-3 | **cron 스케줄 시각 정확** | `runnit-weekly-finalize` `10 15 * * 0` = 일 15:10 UTC = **월 00:10 KST** ✓ / `runnit-weekly-rank-badge-notify` `0 23 * * 0` = 일 23:00 UTC = **월 08:00 KST** ✓. 둘 다 `active=true` |
| P-4 | **`_batch_hours_ok` 게이트 정합** | 라이브 정의 `hour(KST) between 8 and 21`. 00:10 KST → false(확정 배치의 NT-06 호출이 무음), 08:00 KST → true ✓ |
| P-5 | **기존 job 과 중복 집계 없음** | `runnit-leaderboard`(*/5) 와 `runnit-rank-notify` 는 `refresh_all_leaderboards(now())` — 앵커가 `now()` 라 **현재 주만** 건드린다. `refresh_leaderboard` 의 꼬리 DELETE 도 `period_start = v_start` 한정. 확정 배치가 찍은 지난 주 `finalized_at` 을 지우는 경로 없음 |
| P-6 | **`finalized_at` 이 upsert 로 지워지지 않음** | `refresh_leaderboard` 의 `do update set` 목록에 `finalized_at` 없음 (라이브 정의 확인) |
| P-7 | **주 귀속 앵커 정확** | `v_prev_anchor = v_cur_start - 1h` → `leaderboard_period_bounds('weekly')` 가 `date_trunc('week', at KST)` 라 항상 직전 주를 가리킨다. 수동 실행 결과 `week_id=2026-W35`, `period_start=2026-08-23 15:00+00`(= 8/24 00:00 KST 월) ✓. KST 는 DST 없음 |
| P-8 | **finalize 멱등** | 롤백 트랜잭션에서 2회 연속 실행: `r1 == r2` (`entries_marked=2`, `badges_awarded=0`), 원장 행 수 10 유지, `rk06` 뱃지 3건 유지. `coalesce(finalized_at, now())` + `on conflict (period_start, tier_key) do update`(finalized_at 미갱신) 동작 확인 |
| P-9 | **snapshot 멱등** | `s1=9, s2=0` — `on conflict (season_id, user_id) do nothing` 확인 |
| P-10 | **notify 멱등 근거** | `notifications_dedupe_unique (user_id, dedupe_key)` UNIQUE 인덱스 실재. `badge_level:weekly:{week_id}` 로 사용자·주당 1건 보장. (실발화는 미검증 — §4 U-2) |
| P-11 | **스냅샷 티어 파티션·타이브레이크 정확** | 롤백 실행 결과 bronze 5명(최대 20.1km) / silver 2명(33.0·32.2km) / gold 1명(115.3km) / platinum 1명(252.5km) — PRD §5.3 임계(0/25/100/250km)와 일치. `rank()` + `user_id` 최종 폴백이라 공동 순위 없음. `activity_type <> 'indoor_run'`·`is_flagged=false`·`status='completed'` 필터가 `refresh_leaderboard` 와 동일 |
| P-12 | **camelCase↔snake_case 매핑 안전 (TRD §4.1)** | `finalized_at→finalizedAt`, `season_distance_meters→seasonDistanceMeters` 등 전부 `FieldRename.snake` 규약에 부합. 클라 소비자 없음(`grep` 확인). `SupabaseRankingRepository._scoped` 가 `.select()`(= `select *`)라 `finalized_at` 이 응답에 실려 오지만, `RankingEntry` 는 `@JsonSerializable(fieldRename: FieldRename.snake)` 이고 `build.yaml` 부재 → `disallowUnknownKeys` 기본 false, `.g.dart` 에 `$checkedCreate` 없음 → **미지 키 무시, 파싱 깨지지 않음** |

**RLS 나머지**:
- `weekly_ranking_finalizations_select_all` → `{anon, authenticated}` / `using(true)`. `leaderboard_entries` 는 `authenticated` 전체 + `anon` 은 `scope='global'` 만. 원장에는 `scope` 개념이 없고 개인정보도 없으므로 **범위 확대로 볼 문제 없음** — PASS.
- 두 테이블 모두 **INSERT/UPDATE/DELETE 정책 0건** → SECURITY DEFINER 함수(`finalize_weekly_ranking`, `snapshot_season_leaderboard`)만 쓴다. 두 함수·`notify_weekly_rank_badges`·`_badge_grade_rank` 모두 `revoke execute ... from public, anon, authenticated` 확인 — PASS.

---

## 3. PLAUSIBLE

| # | 항목 | 비고 |
|---|------|------|
| L-1 | **확정 시 지난 주 보드가 "월요일 00:10 시점 티어"로 재파티션된다.** `refresh_leaderboard` 는 `p.current_tier` 로 나누고 꼬리 DELETE 가 옛 티어 행을 지운다. 일 24:00~월 00:10 사이에 승급하면 끝난 주의 순위가 새 티어로 옮겨간다 | PRD §8.6(주중 승급 이관)의 자연스러운 연장이고 창이 10분이라 실피해 희박. 57 이전 5분 배치도 동일 동작 — **신규 아님** |
| L-2 | **일요일에 시작해 월요일 00:10 이후 업로드된 러닝은 어느 주 보드에도 안 들어간다.** `started_at` 이 지난 주라 새 주 집계에서 빠지고, 지난 주는 이미 확정돼 재집계되지 않는다 | ARCHITECTURE §9.1 "마감된 과거는 소급 변경하지 않는다"(정책 확정)와 **일관**. 다만 §9.1 은 "현 주에 귀속"이라 표현하는데 실제로는 **어느 주에도 귀속 안 됨** — 문구 정밀화 필요 |
| L-3 | **`season_histories.distance_meters` 와 `season_leaderboard_snapshots.season_distance_meters` 의 산출원이 다르다.** 전자는 `profiles.season_distance_meters` 스냅, 후자는 `runs` 재집계 | 마감 직전 `is_flagged` 전환 등으로 profiles 카운터가 stale 하면 HI-06 한 화면에 두 값이 어긋나 보인다. 좁은 경로지만 UI 라운드 전에 어느 쪽을 정본으로 볼지 정할 것 |
| L-4 | **NT-06 은 "월 00:10~08:00 에 획득한 뱃지"만 알린다.** `notify_weekly_rank_badges` 는 상한 없는 `ub.earned_at >= v_fin - 1min` 을 쓰지만 08:00 job 이 한 번만 돌기 때문 | 확정 배치가 자격자를 전원 선평가하므로 정상 경로에서는 빈틈이 없다. 57 이전엔 발화점 자체가 없었으므로 **순개선** |

---

## 4. 검증 불가 / 관측 대기 (backend R-1·R-2·R-3·R-4 와 동일 — 타당하다고 판단)

| # | 항목 |
|---|------|
| U-1 | cron 의 **정시 실행** 자체는 미관측. 첫 실행 2026-09-07(월) 00:10 KST 이후 `cron.job_run_details` 확인 필요 (R-1) |
| U-2 | **RK-06 실지급 · NT-06 실발화 미검증.** 티어별 모집단 1~5명이라 게이트(N≥10/20)를 넘는 사용자가 없다. 수동 실행에서 `badges_awarded=0`, `notifications=0` — **정상 동작이지 실패가 아니다.** TRD §14 #11 해소(베타 20명) 후 재검증 (R-2·R-3) |
| U-3 | **시즌 스냅샷 첫 실적재는 2026-09-30.** 롤백 트랜잭션으로 경로·순위·모집단은 검증했으나 `recompute_season_tier` 경유 실마감은 미관측 (R-4) |

**backend R-5·R-6·R-7·R-8 은 모두 타당**하며 과소평가도 없다. 특히 R-6(앵커 치환의 취약성)은 실제 위험 — `evaluate_badge_condition` 전문 재정의 마이그레이션이 오면 `finalized_at` 필터가 조용히 사라진다. 사후 검출 수단으로 아래 정도의 회귀 가드를 두는 것을 권한다:

```sql
do $$ begin
  if position('and le.finalized_at is not null' in
       (select pg_get_functiondef(oid) from pg_proc
         where proname='evaluate_badge_condition' and pronamespace='public'::regnamespace)) = 0
  then raise exception 'evaluate_badge_condition 에서 finalized_at 필터가 사라졌다 (마이그레이션 57)'; end if;
end $$;
```

**놓친 경계**: C-1(RLS 반전), C-2(시즌 말 걸친 주), C-3(레거시 뱃지 3건), L-2(§9.1 문구), L-3(거리 산출원 이중화) — 5건이 R-1~R-8 에 없었다.

---

## 5. 문서 ↔ 라이브 대조

| 문서 | 결과 |
|------|------|
| `docs/TRD.md` v0.20 §4 DDL·§4.1 매핑표·§14 #12/#23 해소 표기 | **일치.** 신설 두 테이블의 컬럼 목록·PK·매핑 설명이 라이브와 동일 |
| `docs/ARCHITECTURE.md` v0.14 §5.3 배치 서술·§13-4 | **일치** |
| `docs/ARCHITECTURE.md:317` `weekly_ranking_finalizations` RLS 행 | **일치** |
| `docs/ARCHITECTURE.md:318` `season_leaderboard_snapshots` RLS 행 | 🔴 **불일치 — C-1.** "동일 공개 범위 / 무효 시즌은 본인만"이 실제로 성립하지 않는다. C-1 수정 후 이 행은 그대로 유효해진다 |
| PRD §5.4·§8.2·§8.5·§8.6 / RK-06·RK-10 | 티어(절대)·주간 랭킹(상대·티어 내)·뱃지(영구) 3축 혼동 없음. 크루 랭킹 미포함(R-8) 정당. **§8.5 "시즌 말 단축 주간"만 미구현 — C-2** |
| PRD §5.5 GM-07 | 시즌 티어 뱃지는 이번 변경 범위 밖, 영향 없음 |

---

## 6. 최종 판정

🔴 **C-1 수정 후 커밋 가능.**

- **blocking**: C-1 (`season_leaderboard_snapshots` RLS 반전) — §1 의 수정 SQL 을 마이그레이션 59(또는 58 파일 수정 + 재적용)로 적용하고 재현 쿼리로 `snapshot_visible_to_other = 0` 확인.
- **non-blocking, 커밋 후 처리**: C-2·C-3 는 TRD §14 신규 이슈 등재, L-1~L-4 는 UI 라운드/문구 정정.
- 코드 수정은 C-1 외에 하지 않았다. C-2 는 PRD §8.5 스펙 구현 방식 확정이 필요해 **사용자 확인 사항**이다.
- 클라이언트 영향 없음 — Dart 변경분이 없어 `flutter analyze` / `build_runner` 재생성은 불필요하다고 판단했다.
