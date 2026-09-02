# QA 경계 정합성 검증 — 마이그레이션 60·61 (스냅샷 무효 옵션 B / 시즌 말 단축 주간)

| 항목 | 내용 |
|------|------|
| 검증일 | 2026-09-01 |
| 검증자 | qa-integration-tester |
| 대상 | 미커밋 변경 — 마이그레이션 60·61, TRD v0.22, ARCHITECTURE v0.16, backend 노트 |
| 원격 DB | `xwtbwexcofcgmbvktwdo` (60=`20260901110843`, 61=`20260901111407` 적용 확인) |
| 선행 QA | `_workspace/20260901_qa_weekly-finalize-season-snapshot.md` (57·58 검증분) |
| 최종 판정 | 🟢 **커밋 가능. blocking 0건** |

---

## 0. 요약

| 분류 | 건수 |
|------|------|
| PASS (라이브 대조·재현 완료) | 18 |
| CONFIRMED (코드·라이브로 재현) | 1 (blocking 0 — 60·61 범위 밖의 기존 결함) |
| PLAUSIBLE | 5 |
| 검증 불가 / 관측 대기 | 3 |

**60·61 자체에서 발견된 blocking 결함은 없다.** 선행 QA의 C-1(스냅샷 RLS 반전)·C-2(걸친 주 RK-06 미지급)가 라이브 재현으로 **둘 다 닫힌 것**을 확인했고, 57·58·59에 대한 이전 결론도 깨지지 않았다.

CONFIRMED 1건(C-1)은 **`leaderboard_entries` 의 지난 기간 행이 클라이언트 조회에 섞여 들어오는 기존 결함**이다. 60·61이 만든 것이 아니라 57 이전부터 있었고 라이브에서 지금도 재현되지만, 61의 클램프가 "같은 달력 주에 period_start 2개"라는 형태를 분기마다 **확정적으로** 추가하므로 함께 등재한다. 커밋은 막지 않는다.

---

## 1. 마이그레이션 60 (TRD #32 옵션 B)

### P-1 정책 형태·술어가 `season_histories` 와 완전히 동일 — PASS

`pg_policy` 라이브 덤프 (`polcmd='r'`):

```
season_histories_select_visible            ((is_voided = false) OR (user_id = ( SELECT auth.uid() AS uid)))
season_snapshots_select_visible            ((is_voided = false) OR (user_id = ( SELECT auth.uid() AS uid)))
```

**바이트 단위로 동일하다.** 59가 지적한 "형태가 달라 생긴 반전" 함정이 구조적으로 제거됐다.

### P-2 헬퍼 DROP·RPC 노출 소멸·advisor 원복 — PASS

- `pg_proc` 에서 `_season_history_voided` **부재** 확인 (`proname like '%season_history%'` → `set_season_history_voided` 1건만).
- `get_advisors(security)` → **WARN 6건**, 59가 만든 `_season_history_voided` 항목 **없음**. 신규 0건. 잔존 6건은 전부 60·61 이전부터 있던 항목(`rls_auto_enable` ×2, `mark_notifications_read`, `register_push_token`, `sync_my_season`, `auth_leaked_password_protection`)이다.

### P-3 적재 시 `is_voided` 복사 + `false` 폴백 — PASS

`snapshot_season_leaderboard()` 의 `tiered` CTE가 `coalesce((select sh.is_voided from season_histories …), false)`. 폴백이 맞다 — 스냅샷은 `recompute_season_tier` 가 `season_histories` 를 **먼저 마감한 뒤** 같은 트랜잭션에서 부르므로, 행이 없다는 것은 그 시즌에 마감 이력이 없다는 뜻이고 무효 판정도 존재할 수 없다. `true` 폴백이면 정상 사용자가 통째로 숨는다.

### P-4 `set_season_history_voided()` 단일 진입점 — PASS

롤백 트랜잭션 재현:

```
r1=1  hist=t  snap=t        ← 두 테이블 함께 갱신
r2_idem=0                   ← 재호출 시 no-op (is distinct from 가드)
r3_nosnap=1  snapcnt_b=0    ← 스냅샷 행이 없어도 예외 없이 history만 갱신
```

`proacl` = `postgres=X | service_role=X` — `public`/`anon`/`authenticated` **전부 회수됨**.

### P-5 무효 스냅샷 차단 + 비회귀 재현 — PASS

트랜잭션 내 삽입 후 롤백, `set local role authenticated` + `request.jwt.claims` 로 두 사용자 시점 재현:

```
snapshot_voided_to_other = 0   ← 타인의 무효 시즌 스냅샷 차단 (선행 QA C-1: 1 → 0)
normal_to_other          = 1   ← 정상 시즌 비회귀
own_voided               = 1   ← 본인 무효 시즌은 열람 가능
own_history              = 1
```

**선행 QA의 blocking C-1이 닫힌 것을 라이브에서 확인.**

### P-6 잔여 위험(직접 UPDATE)에 대한 판단 — PASS (타당)

운영자가 `season_histories` 를 직접 UPDATE하면 스냅샷이 공개된 채 남는다. 트리거로 막지 않은 판단은 **현 시점에서 타당하다**:

- `is_voided` 쓰기 경로가 코드에 **존재하지 않는다** — 라이브 함수 전량을 훑어도 `season_histories.is_voided` 를 UPDATE하는 함수는 `set_season_history_voided` 하나뿐이고, 나머지는 전부 읽기(RLS 2곳 + 뱃지 조건)다.
- 테이블에 UPDATE 정책이 0건이라 클라이언트 경로가 원천 차단돼 있다. 남는 경로는 `service_role` 수동 SQL뿐.
- 컬럼 코멘트·테이블 코멘트·함수 코멘트 3곳이 단일 진입점을 가리킨다.

다만 **문서 경고는 잊히고 트리거는 안 잊힌다.** 무효 판정이 실제 운영 절차로 들어오는 시점(베타 오픈, 이의제기 프로세스 도입)에는 `season_histories` 의 AFTER UPDATE 트리거로 스냅샷을 따라가게 하는 편이 낫다. 지금 요구하지는 않는다.

---

## 2. 마이그레이션 61 (PRD §8.5 단축 주간 / C-2)

### P-7 `leaderboard_period_bounds` 클램프 — PASS (라이브 직접 호출)

| 앵커 | period_start (KST) | period_end (KST) | 길이 |
|------|--------------------|------------------|------|
| weekly 2026-09-29 (Q3 조각) | 2026-09-28 00:00 | **2026-10-01 00:00** | 3일 ✓ |
| weekly 2026-10-02 (Q4 조각) | **2026-10-01 00:00** | 2026-10-05 00:00 | 4일 ✓ |
| weekly 2026-09-16 (평범한 주) | 2026-09-14 00:00 | 2026-09-21 00:00 | 7일 ✓ |
| weekly 2026-10-05 (분기 첫 온전한 주) | 2026-10-05 00:00 | 2026-10-12 00:00 | 7일 ✓ |
| daily 2026-09-30 | 2026-09-30 00:00 | 2026-10-01 00:00 | 1일 (클램프 무영향) ✓ |
| monthly 2026-09-30 | 2026-09-01 00:00 | 2026-10-01 00:00 | 30일 (클램프 무영향) ✓ |
| **all_time** | 1970-01-01 09:00 | **10000-01-01 08:59:59** | **보존** ✓ |

두 조각이 `[…,10-01)` / `[10-01,…)` 로 **틈도 겹침도 없다.** `all_time` 이 클램프되지 않는 것이 특히 중요했는데 정상이다.

### P-8 `week_id_at()` 접미사 — PASS

| 앵커 | 출력 |
|------|------|
| 2026-09-29 (Q3 조각) | `2026-W40@2026-Q3` |
| 2026-10-02 (Q4 조각) | `2026-W40@2026-Q4` |
| 2026-09-16 | `2026-W38` (불변) |
| 2026-08-24 (기존 이력) | `2026-W35` (불변) |
| 2026-10-05 | `2026-W41` (불변) |

**기존 dedupe 키 호환 확인**: 라이브 `notifications` 의 주 포함 키는 전부 `weekend_push:2026-W35:sun` 형태이고, `2026-W35` 는 걸치지 않는 주라 **출력이 한 바이트도 바뀌지 않는다.** 기존 이력과 충돌·중복 발화 없음.

> ⚠️ 마이그레이션 헤더의 "걸친 주는 2026-09-28 이 처음"이라는 서술은 **엄밀히는 부정확하다.** `week_id_at` 은 순수 계산 함수라 과거 앵커에도 접미사를 붙인다 — `2025-12-30 → 2026-W01@2025-Q4`, `2026-03-31 → 2026-W14@2026-Q1`, `2026-06-30 → 2026-W27@2026-Q2`. 실제로는 그 주들의 dedupe 키·원장 행이 라이브에 없어서 무해하고(위 확인), 소비자가 전부 `now()` 또는 최근 `period_start` 기준이라 과거 키를 재계산하지 않는다. **결론은 맞고 근거만 좁다** — 문구 정밀화 권고.

### P-9 `badge_season` GUC 경로 + 과거 시즌 오판정 차단 — PASS (트랜잭션 재현)

`evaluate_badge_condition` 라이브 덤프 선언부 (offset 900):

```
v_season       text := coalesce(
                         nullif(current_setting('runnit.badge_season', true), ''),
                         public.season_id_at(now()));
v_season_start timestamptz := public.season_start(v_season);
v_season_end   timestamptz := public.season_end(v_season);
```

롤백 트랜잭션 재현 (`leaderboard_entries` 에 Q4 조각 rank1/pc10/gold/확정 삽입 → 이후 Q3 조각 추가):

```
q4guc=t                    ← GUC=Q4 로 Q4 조각 성적 판정 성공
q3guc_only_q4data=f        ← 🔴 GUC=Q3 인데 Q4 데이터뿐 → 거짓. 잠재 결함이 닫혔다
q3guc_with_q3data=t        ← Q3 조각 추가 후 GUC=Q3 → 참
guc_after=[]               ← evaluate_badges 종료 후 GUC 원복. 누수 없음
awarded=2  srank=srank_gold_top1@2026-Q3, srank_gold_top1@2026-Q4
```

마지막 줄이 결정적이다 — **한 번의 `evaluate_badges` 호출이 두 시즌 인스턴스를 각자의 조각 성적으로 정확히 지급했다.** 61 이전이라면 두 인스턴스 모두 `season_id_at(now())` 하나로 판정돼 한쪽은 영영 못 받았다. C-2와 그보다 넓은 "과거 시즌 인스턴스 재판정" 결함이 함께 닫힌 것을 확인.

`evaluate_badges` 의 디스패치 커서가 `b.season_id` 를 select하고 뱃지마다 `set_config(..., true)`(트랜잭션 로컬)로 세팅 → 루프 종료 후 `''` 로 원복하는 구조도 코드·런타임 양쪽에서 확인.

**템플릿 뱃지 오염 없음**: `season_id is null` 인 `srank_*`/`stier_*`/`sevent_*` 35건은 전부 `scope='seasonal'` 이라 `evaluate_badges` 의 `(scope='seasonal' and season_id is not null)` 필터에서 제외된다. `scope='permanent'` 인 뱃지 중 `season_id is null` 인 것은 전부 시즌 무관 조건(누적·PB·레벨 등)이라 GUC 폴백 경로를 타도 무해하다.

### P-10 확정 커버리지 — PASS (4단계 시뮬레이션)

롤백 트랜잭션에서 `finalize_weekly_ranking` 을 시간 순서대로 4번 호출:

| 호출 | p_at (KST) | 결과 |
|------|-----------|------|
| ① 시즌 롤오버 | 2026-10-01 00:05 | **3주 확정** — `2026-W38`, `2026-W39`, **`2026-W40@2026-Q3` (shortened: true, 09-28~10-01)** |
| ② 같은 시점 재실행 | 2026-10-01 00:05 | **0주** (멱등) |
| ③ 다음 월요일 배치 | 2026-10-05 00:10 | **1주** — **`2026-W40@2026-Q4` (shortened: true, 10-01~10-05)** |
| ④ 재실행 | 2026-10-05 00:10 | **0주** (멱등) |

- **Q3 조각은 ①에서 확정된다** — `reset_stale_seasons` 가 리셋 루프 전에 부르는 경로가 실제로 동작한다.
- ①이 실패해도 ③의 14일 되짚기(10-05 기준 09-21~10-05)가 Q3 조각을 덮는다 — **자기치유 확인.**
- ②④가 0주 → `weekly_ranking_finalizations` 존재 검사로 **재확정·뱃지·알림 중복이 발생하지 않는다.** `badges_awarded=0`, `notifications=0`.
- `shortened` 플래그가 두 조각 모두 true로 정확히 계산된다.

**14일 윈도 적정성**: 롤오버 배치와 월요일 배치가 **연속 2회 모두** 실패하면(10-01, 10-05 둘 다) 다음 기회는 10-12 — 되짚기 09-28~10-12로 Q3 조각을 **아슬아슬하게 덮는다**(경계 정확히 09-28). 3회 실패(10-19)면 영구 유실. 오프라인 업로드 지연은 확정 커버리지와 무관하다(§9.1 정책상 마감된 과거는 소급 변경 안 함). 14일은 자기치유와 "오래된 주를 오늘의 티어로 합성"의 절충으로 **타당**하나 여유가 정확히 1회분이다 — L-4 참조.

### P-11 `recompute_season_tier.best_weekly_rank` — PASS

라이브 정의가 52의 형태를 그대로 유지한다:

```sql
select min(le.rank) from public.leaderboard_entries le
 where le.user_id = p_user_id and le.period='weekly' and le.metric='distance'
   and le.scope='global'
   and le.tier is not null                                   -- 52 유지 ✓
   and le.period_start >= public.season_start(v_prev_season)
   and le.period_start <  public.season_end(v_prev_season)
```

클램프 덕에 Q3 조각의 `period_start`(09-28)는 범위 안, Q4 조각(10-01)은 `< season_end('2026-Q3')` = 10-01 에서 탈락. **Q3 조각만 세고 Q4 조각을 정확히 뺀다.** 서브쿼리 수정 없이 성립하는 것이 61 설계의 핵심 주장인데 사실이다.

### P-12 §8.6 (주중 승급 시 주간 거리 이관) — PASS

`refresh_leaderboard` 가 경계를 자체 계산하지 않고 `leaderboard_period_bounds(p_period, p_anchor)` 를 호출한다(라이브 덤프 offset 877 확인) → 클램프가 **모든 리더보드 갱신 경로에 자동 전파**된다. 이관 메커니즘은 `p.current_tier` 파티션 + `started_at ∈ [v_start, v_end)` 집계이고, 클램프는 창을 좁힐 뿐 파티션 로직을 건드리지 않는다. 승급 시 그 조각 안의 거리가 새 티어 보드로 그대로 따라간다 — **동작 불변.**

### P-13 NT-04 dedupe 분리 — PASS

`notify_rank_changes` 가 `v_week := week_id_at(v_start)` — `now()` 가 아니라 **클램프된 조각의 시작점**을 쓴다. 두 조각이 `rank_change:2026-W40@2026-Q3:…` / `…@2026-Q4:…` 로 갈린다. 조각별 24시간 게이트(`p_at - v_start < 24h`)도 조각 시작 기준이라 정합.

### P-14 NT-06 — PASS

`notify_weekly_rank_badges` 가 "최근 7일 내 확정된 주 **전부**"를 돈다. Q3 조각(10-01 00:05 확정)과 Q4 조각(10-05 00:10 확정)이 10-05 08:00 KST 발송 시점에 둘 다 7일 창 안에 들어와 **양쪽 다 발송된다.** `b.season_id = w.season_id` 로 각 주를 자기 시즌 인스턴스에만 귀속. `_batch_hours_ok` 자가 게이트로 00:05/00:10 확정 배치 호출은 무음(위 시뮬레이션에서 `notifications=0` 확인).

---

## 3. 공통

### P-15 R-12 회귀 가드 — 두 패치 모두 라이브에 실재 — PASS

`evaluate_badge_condition` 라이브 덤프(24,261자) 문자열 위치:

| 패치 | 위치 | 상태 |
|------|------|------|
| `and le.finalized_at is not null` (57-5) | 15,518 | ✓ 실재 |
| `runnit.badge_season` (61-3) | 1,092 | ✓ 실재 |

`season_weekly_rank_lte` 분기 전문을 덤프해 **두 패치가 공존하며 최소 모집단 게이트(top1 pc≥10 / top10 pc≥20 / top10pct pc≥20 & ceil(pc*0.10))도 원형 유지**된 것을 확인했다. 61의 앵커 치환이 57의 치환을 덮어쓰지 않았다.

**제안 — 회귀 가드 SQL** (다음 마이그레이션 상단에 삽입; 전문 재정의 시 즉시 실패):

```sql
do $$
declare v_src text;
begin
  select pg_get_functiondef(oid) into v_src from pg_proc
   where proname = 'evaluate_badge_condition' and pronamespace = 'public'::regnamespace;

  if position('and le.finalized_at is not null' in v_src) = 0 then
    raise exception 'evaluate_badge_condition: 마이그레이션 57 의 finalized_at 필터가 사라졌다 — 진행 중인 주의 일시적 1위로 영구 뱃지가 나간다';
  end if;
  if position('runnit.badge_season' in v_src) = 0 then
    raise exception 'evaluate_badge_condition: 마이그레이션 61 의 badge_season GUC 가 사라졌다 — 시즌 말 걸친 주 RK-06 미지급 + 과거 시즌 인스턴스 오판정이 되살아난다';
  end if;
end $$;
```

### P-16 권한 회수 — PASS

`proacl` 라이브 확인. 신규·변경 SECURITY DEFINER 함수 **전부** `postgres=X | service_role=X` 만:

`set_season_history_voided` / `snapshot_season_leaderboard` / `finalize_weekly_ranking` / `notify_weekly_rank_badges` / `reset_stale_seasons` / `evaluate_badges` / `evaluate_badge_condition`

`week_id_at`·`leaderboard_period_bounds` 는 `anon`/`authenticated` 실행 가능하지만 **SECURITY INVOKER 순수 계산 함수**(테이블 접근 0)라 정보 노출이 없다 — 기존 상태 유지, 문제 없음.

### P-17 볼러틸리티 정합 — PASS

`leaderboard_period_bounds` 와 `week_id_at` 이 `IMMUTABLE` 로 선언됐고, 새로 의존하게 된 `season_id_at`·`season_start`·`season_end` 도 **전부 IMMUTABLE**(시즌은 테이블이 아니라 순수 계산 — ARCHITECTURE v0.3 확정). IMMUTABLE 선언이 거짓이 아니므로 플랜 캐싱·인덱스 평가에서 잘못된 상수 접기가 일어나지 않는다.

### P-18 cron 배선 — PASS

| job | schedule (UTC) | KST | 대상 |
|-----|----------------|-----|------|
| `runnit-weekly-finalize` | `10 15 * * 0` | 월 00:10 | `finalize_weekly_ranking()` ✓ |
| `runnit-weekly-rank-badge-notify` | `0 23 * * 0` | 월 08:00 | `notify_weekly_rank_badges()` ✓ |
| `runnit-season-reset-30` | `5 15 30 6,9 *` | 7/1·10/1 00:05 | `reset_stale_seasons()` ✓ |
| `runnit-season-reset-31` | `5 15 31 3,12 *` | 4/1·1/1 00:05 | `reset_stale_seasons()` ✓ |

전부 `active=true`. 61이 함수 시그니처를 바꾸지 않아 job 정의 수정이 불필요한 것도 맞다.

### P-19 클라이언트 게이트 — PASS

```
dart run build_runner build   → wrote 0 outputs (재생성 불필요 — Dart 변경분 없음)
flutter analyze               → No issues found!
flutter test                  → All tests passed! (279 tests)
git status                    → 검증 중 파일 변경 0건 (코드 수정 금지 준수)
```

---

## 4. CONFIRMED

### 🟠 C-1 — `leaderboard_entries` 의 지난 기간 행이 클라이언트 조회에 섞여 들어온다

**분류: 기존 결함(57 이전부터). 60·61이 만든 것이 아니며 커밋을 막지 않는다.**

**위치**: `lib/features/ranking/data/supabase_ranking_repository.dart:96-128` ↔ 라이브 `refresh_leaderboard` 꼬리 DELETE

Dart `_scoped()` 의 전제 주석:

> `period_start`는 조건에 넣지 않는다 — 배치가 매 주기 이전 기간 행을 정리하므로 (period, metric, scope, tier) 조합당 현재 기간 행만 남는다.

**이 전제는 거짓이다.** 라이브 `refresh_leaderboard` 의 꼬리 DELETE는 현재 기간으로 한정된다:

```sql
delete from public.leaderboard_entries le
 where le.scope = p_scope and le.crew_key = … and le.tier_key = v_tier_key
   and le.period = p_period and le.metric = p_metric
   and le.period_start = v_start          -- ← 현재 기간 안의 stale 행만 지운다
   and le.computed_at  < v_now;
```

ARCHITECTURE §5.3도 "지난 주차 행은 삭제하지 않고 **누적 보존**"이라고 명시한다 — 즉 DB 쪽 의도가 맞고 **Dart 주석·쿼리 쪽이 어긋나 있다.**

**라이브 재현** (클라이언트 `_scoped()` 와 동일한 필터 + `order by rank`):

```sql
select rank, period_start, user_id, score from public.leaderboard_entries
 where period='weekly' and metric='distance' and scope='global' and tier='bronze'
 order by rank asc limit 50;
```
```
rank | period_start              | user_id
   1 | 2026-08-23 15:00:00+00    | 42861c7f-…       ← 현재 주
   1 | 2026-08-16 15:00:00+00    | 0000…00a4        ← 지난 주 (섞여 들어옴)
   2 | 2026-08-16 15:00:00+00    | 0000…00a1
   3 | 2026-08-16 15:00:00+00    | 0000…00a2
   4 | 2026-08-16 15:00:00+00    | 0000…00a3
```

**rank=1 행이 두 개** 나온다. 클라이언트는 "`rank`가 서버의 확정값"이라며 재정렬조차 하지 않으므로(`supabase_ranking_repository.dart:11-14`) 이 목록이 그대로 렌더된다.

추가로 `fetchMyEntry`(:55-57)는 `.maybeSingle()` 을 쓴다 — 한 사용자가 같은 보드의 서로 다른 주에 행을 가지면 PostgREST가 다중 행을 돌려주고 `maybeSingle` 이 **예외를 던진다.** 현재 시드에서는 각 주에 뛴 사용자가 갈려 있어 중복 사용자가 0명이라 아직 터지지 않는다(확인함). 베타에서 두 주 연속 뛰는 사용자가 나오는 순간 랭킹 화면이 깨진다.

> Dart 클라이언트를 실제로 실행해 예외를 관측하지는 않았다 — 다중 행 조건은 라이브 재현으로 CONFIRMED이고, `maybeSingle` 의 예외 동작은 PostgREST/supabase-dart 규약에 근거한 판단이다.

**61과의 관계**: 61은 이 결함을 만들지도 악화시키지도 않는다(누적은 원래 매주 일어난다). 다만 클램프 이후 **분기마다 "같은 달력 주에 period_start 2개"** 가 확정적으로 생기고, 클라이언트는 `2026-W40@2026-Q3` 조각과 `@2026-Q4` 조각을 **구분할 수단이 전혀 없다** — `week_id` 는 `leaderboard_entries` 에 없는 컬럼이고 `period_start` 는 쿼리에 안 들어간다. 시즌 롤오버 직후 주간 랭킹 화면이 두 조각을 합쳐 보여줄 것이다.

**수정 제안** (코드 수정 금지 지시에 따라 적용하지 않았다):

```dart
// _scoped() 에 현재 기간 한정을 추가한다. 서버 경계 계산을 클라이언트가 복제하지
// 않도록, period_start 최댓값을 쓰는 편이 KST/시즌 클램프 규칙 중복을 피한다.
//   가장 단순: .order('period_start', ascending: false) 를 rank 정렬보다 앞에 두고
//   최신 period_start 만 남기도록 서버 뷰를 추가하거나,
//   RPC `current_leaderboard(period, metric, scope, tier)` 를 신설해
//   leaderboard_period_bounds() 로 period_start 를 서버가 정하게 한다.
```

클라이언트가 `leaderboard_period_bounds` 의 KST·시즌 클램프 규칙을 Dart로 재구현하면 61의 클램프와 어긋날 위험이 크므로, **서버가 현재 기간을 정해 주는 RPC/뷰** 쪽을 권한다. backend-engineer·flutter-ui-designer 공동 항목.

---

## 5. PLAUSIBLE

| # | 항목 | 비고 |
|---|------|------|
| L-1 | **구시즌 조각의 NT-06 알림이 최대 4일 지연된다.** Q3 조각 RK-06은 10-01 00:05에 지급되지만 `runnit-weekly-rank-badge-notify` 는 `0 23 * * 0`(주 1회, 월 08:00 KST)이라 발송은 10-05 08:00 | 뱃지 자체는 즉시 갤러리에 뜨고 dedupe로 중복도 없다. 시즌 마감 결과를 나흘 뒤 알리는 UX가 §8.5 취지("시즌 종료와 같은 순간에 결과를 본다" — 61 헤더)와 어긋난다. 알림 job을 일 1회로 바꾸면 해소 |
| L-2 | **걸친 주에는 `rank_change` 알림 상한이 사실상 2배가 된다.** 조각마다 `v_total < 4` 예산이 따로 잡혀 한 달력 주에 최대 8건 | 두 조각이 실제로 별개 랭킹 기간이므로 논리적으로는 정당하다. 다만 §6-N 의 "주당 4건" 서술과 어긋나므로 문구 확인 필요 |
| L-3 | **시즌 롤오버 순간 주간 보드가 달력 주 중간에 0으로 리셋된다.** 10-01(목) 00:00부터 주간 랭킹이 목요일 거리만 반영 | PRD §8.5 단축 운영의 **의도된 결과**다. 그러나 UI에 아무 설명이 없으면 "내 주간 기록이 사라졌다"로 읽힌다. 랭킹 화면에 조각 기간(`9/28–9/30`, `10/1–10/4`)과 "시즌 전환으로 단축된 주" 안내 필요 — RK 라운드 항목 |
| L-4 | **14일 되짚기의 여유가 정확히 1회분이다.** 롤오버(10-01)·월요일(10-05) 배치가 둘 다 실패하면 10-12 실행이 09-28을 **경계값으로 간신히** 덮고, 3회 실패 시 Q3 조각은 영구 미확정 | 되짚기 상한을 늘리면 "오래된 주를 오늘 티어로 합성"하는 더 나쁜 문제가 생긴다는 판단은 타당. 대신 `weekly_ranking_finalizations` 에 미확정 조각이 남아 있는지 감시하는 알람 쪽이 맞다 |
| L-5 | **61 배포 후 첫 월요일 배치(2026-09-07 00:10)가 `[08-31, 09-07)` 주를 "그날의 티어"로 합성 확정한다.** 되짚기 범위 08-24~09-07 중 `[08-24,08-31)` 은 원장에 이미 있어 건너뛰고, 한 주가 새로 확정된다 | 되짚기 설계상 의도된 1회성 동작이고 모집단이 게이트(N≥10/20)에 못 미쳐 뱃지·알림은 나가지 않는다. 다만 그 주의 순위가 **집계된 적 없는 상태에서 사후 합성**된다는 점은 인지하고 넘어가야 한다 |

---

## 6. 검증 불가 / 관측 대기

| # | 항목 |
|---|------|
| U-1 | **cron 정시 실행 미관측.** `runnit-weekly-finalize` 첫 실행 2026-09-07(월) 00:10 KST, `runnit-season-reset-30` 첫 실행 2026-10-01 00:05 KST. `cron.job_run_details` 확인 필요 |
| U-2 | **RK-06 실지급·NT-06 실발화 미검증** (선행 QA U-2 유지). 티어별 모집단이 1~5명이라 게이트를 넘는 사용자가 없다. 위 재현은 전부 인위적 `leaderboard_entries` 삽입 기반. TRD §14 #11 해소(베타 20명) 후 재검증 |
| U-3 | **실제 시즌 롤오버 미관측.** 2026-09-30 → 10-01 전환에서 `reset_stale_seasons` → `finalize_weekly_ranking` → 리셋 루프 → `snapshot_season_leaderboard` 순서가 실행되는 것은 롤백 시뮬레이션으로만 확인했다. 첫 실적재 2026-10-01 |

---

## 7. 문서 ↔ 라이브 대조

| 문서 | 결과 |
|------|------|
| `docs/TRD.md` v0.22 변경 이력 | **일치.** 60(옵션 B·단일 진입점·advisor 원복)·61(클램프·접미사·GUC·되짚기) 서술이 라이브 동작과 전부 부합 |
| `docs/TRD.md` §14 #30 | ~~취소선~~ + 해소 근거 4항목. **정확.** 스모크 기재 내용도 재현과 일치 |
| `docs/TRD.md` §14 #32 | ~~취소선~~ + 해소 근거(헬퍼 DROP·advisor 원복·단일 진입점·대가 명시). **정확** |
| `docs/TRD.md` §14 **#31** | **open item 으로 정확히 등재됨.** "무효 사용자를 숨기면 `rank`·`participant_count` 에 구멍" / 확정 시점 "RK-10 UI 라운드, gamification-designer와 확정". 60이 #31을 건드리지 않았다는 서술도 맞다 |
| `docs/TRD.md` §6.4.1 / :1574 | 클램프 규칙·weekly 한정·`all_time` 파손 경고 모두 라이브와 일치 |
| `docs/ARCHITECTURE.md` v0.16 §5.3 | 단축 주간·되짚기·롤오버 선확정·GUC 전환 서술 **일치** |
| `docs/ARCHITECTURE.md` §5.5 RLS 표 `season_leaderboard_snapshots` 행 | **일치.** 선행 QA가 지적한 :318 불일치가 해소됐다 — 이제 "순수 컬럼 술어"라는 서술이 라이브와 정확히 같고, 되돌림 금지 경고와 `set_season_history_voided` 안내가 붙었다 |
| `docs/ARCHITECTURE.md` §13 | 마이그레이션 범위 00~61, "로컬·원격 전량 적용 완료" — `supabase_migrations` 대조 결과 **사실** |
| PRD §1.4 / §5.3 / §5.4 / §8.5 / §8.6 | 티어(절대·시즌 누적 임계)·주간 랭킹(상대·티어 내·주 리셋)·뱃지(영구) 3축 혼동 없음. 크루 랭킹 미포함. §8.5 단축 운영이 **드디어 구현됨**. §8.6 이관 로직 불변 확인 |
| 마이그레이션 61 헤더 "걸친 주는 2026-09-28 이 처음" | 🟡 **근거가 좁다** — P-8 참조. 결론(기존 이력과 충돌 없음)은 라이브 확인으로 사실이나, 이유는 "과거에 걸친 주가 없어서"가 아니라 "그 주들의 키가 라이브에 없어서"다. 문구 정밀화 권고 |

**57·58·59 이전 결론 비회귀 확인**: 선행 QA의 P-1~P-12 중 60·61이 건드린 표면(P-1 앵커 치환, P-2 모집단 게이트, P-6 `finalized_at` upsert 미갱신, P-8 finalize 멱등, P-9 snapshot 멱등)을 재검증했고 **전부 유지**된다. C-1은 해소, C-2는 해소, C-3(레거시 뱃지 3건)은 문서 정정 사항으로 변화 없음.

---

## 8. 최종 판정

🟢 **커밋 가능. blocking 0건.**

- **60·61 자체에 blocking 결함 없음.** 선행 QA의 blocking C-1과 non-blocking C-2가 라이브 재현으로 **둘 다 닫힌 것**을 확인했고, 옵션 B의 대가(복제본 정합)는 `set_season_history_voided()` 단일 진입점이 실제로 처리한다.
- **가장 가치 있는 확인**: 61-3의 `badge_season` GUC가 C-2뿐 아니라 "과거 시즌 인스턴스가 현재 데이터로 재판정되는" 더 넓은 잠재 결함까지 닫았다는 backend의 주장이 **사실이다.** 한 번의 `evaluate_badges` 호출이 Q3·Q4 인스턴스를 각자의 조각 성적으로 정확히 지급하는 것을 재현했다.
- **커밋 후 처리**:
  - **C-1** (랭킹 리포지토리가 지난 기간 행을 걸러내지 않음) — TRD §14 신규 이슈 등재. `fetchMyEntry` 의 `maybeSingle` 예외는 베타 오픈 전 처리 필요. backend-engineer(서버 RPC/뷰) + flutter-ui-designer 공동.
  - **R-12 회귀 가드 SQL** (§3 P-15) — 다음 마이그레이션에 삽입 권고.
  - **L-1** (NT-06 4일 지연) — 알림 job 주기 재고.
  - **L-3** (단축 주 UI 안내 부재) — RK 라운드.
  - 마이그레이션 61 헤더·TRD 문구 정밀화 2건(P-8, §7 마지막 행).
- **코드·마이그레이션·문서 수정 0건, 커밋 0건.** 검증은 전부 라이브 롤백 트랜잭션과 읽기 전용 덤프로 수행했으며 `git status` 로 파일 변경이 없음을 확인했다.
