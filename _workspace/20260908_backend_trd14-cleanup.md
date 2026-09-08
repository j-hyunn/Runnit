# 백엔드 정리 3건 — TRD §14 #18 · #31 · #33

| 항목 | 내용 |
|------|------|
| 작성일 | 2026-09-08 |
| 담당 | backend-engineer |
| 상태 | **마이그레이션 작성 완료 / 프로덕션 적용 대기** — 원격(`xwtbwexcofcgmbvktwdo`)에는 아무것도 적용하지 않았다 |
| 산출 | `supabase/migrations/20260908120000_65_badge_achieved_value.sql`<br>`supabase/migrations/20260908120100_66_snapshot_void_rerank.sql` |
| 조사 방법 | 읽기 전용(`list_projects` · `execute_sql` SELECT · `get_advisors`)으로 라이브 함수 전문·행 수·트리거를 확인. 쓰기 도구는 호출하지 않았다 |
| 클라이언트 | **Dart 코드는 손대지 않았다.** §5 "클라이언트가 읽어야 할 것"이 인수인계 항목 |

---

## 0. 요약

| # | 무엇 | 마이그레이션 | 스키마 변경 | 판정 결과 변화 |
|---|------|--------------|-------------|----------------|
| 18 | `user_badges.achieved_value` 신설 + 지급 경로가 확정값을 적는다 | 65 | 컬럼 1개 추가(nullable) | 없음 |
| 33 | `evaluate_badge_condition` 앵커 치환 폐기 → 전문 관리 + 취약 분기 함수 분해 | 65 | 없음(함수만) | 없음 — 로직 동치 |
| 31 | 무효 시즌 사용자를 스냅샷 랭킹에서 제외하고 재랭크 | 66 | `rank` NOT NULL 해제 + CHECK 1개 | 순위·참가자 수 산출이 바뀐다(의도) |

#18 과 #33 을 한 파일에 넣은 이유는 **둘 다 `evaluate_badge_condition` 을 재정의**하기 때문이다.
같은 함수를 두 마이그레이션이 연달아 재정의하면 중간 상태가 생기고, 무엇보다
"판정(boolean)과 확정값(numeric)이 서로 다른 SQL 을 갖는 순간"이 **새로운 #33** 이다.

---

## 1. #33 — 회귀 가드 의존 제거 (마이그레이션 65)

### 1.1 무엇이 문제였나

마이그레이션 57-5 와 61-3 은 24KB 짜리 디스패처 `evaluate_badge_condition` 을
**전문 재작성 없이 문자열 치환**으로 패치했다.

```sql
execute replace(v_src, v_anchor, v_repl);   -- 57-5, 61-3
```

들어간 조각은 두 개다.

| 출처 | 조각 | 이게 사라지면 |
|------|------|---------------|
| 57-5 | `season_weekly_rank_lte` 분기의 `and le.finalized_at is not null` | 진행 중인 주의 **일시적 1위**로 영구 뱃지가 나간다 (TRD #23) |
| 61-3 | 판정 시즌을 `current_setting('runnit.badge_season')` 로 읽는 것 | 시즌 말 걸친 주 RK-06 미지급 + 과거 시즌 인스턴스 오판정 (TRD #30, QA C-2) |

63 은 이 둘을 **문자열 존재 검사**로 지켰다. 사고를 막는 게 아니라 터뜨려 알리는 안전망이고,
술어를 한 글자만 고쳐도 오탐한다.

### 1.2 어떻게 고쳤나 — 전문 관리 + 분해, 둘 다

**(a) 전문 관리.** 65 파일이 이제 `evaluate_badge_condition` 의 정본이다.
원격에서 `pg_get_functiondef` 를 떠와 편집하던 관행이 여기서 끝난다.
앞으로 이 함수를 고칠 때는 **마이그레이션 파일에 전문을 다시 싣는다.**

**(b) 분해.** 사라지면 안 되는 두 술어를 함수 경계 뒤로 옮겼다.

| 새 함수 | 담는 것 | 왜 |
|---------|---------|-----|
| `_badge_eval_season() → text` | 61-3 의 GUC 폴백 | 디스패처 `declare` 절이 이 함수를 부른다. 술어가 아니라 **호출**이므로 전문 재정의로 빠지려면 의도가 필요하다 |
| `_season_weekly_rank_badge_rank(uuid, tier, text, text) → integer` | 57-5 의 `finalized_at` + bucket 문턱 | boolean 이 아니라 **자격 등수**를 돌려준다 — 판정은 `is not null`, 확정값(#18)은 그 값 그대로. **두 경로가 갈라질 수 없다** |
| `_season_streak_weeks(uuid, text) → integer` | 시즌 내 최장 연속 주 CTE | 판정·확정값 공유 (로직 이동만, 변경 없음) |
| `_season_weekly_rank_rising_streak(uuid, text) → integer` | 순위 연속 상승 CTE | 판정·확정값 공유 (로직 이동만, 변경 없음) |

### 1.3 가드는 남겼다 — 형태를 바꿔서

65-8 이 63 의 두 검사를 대체한다. 문자열 조각이 아니라 **호출 관계**를 본다.

- `_badge_eval_season()` · `_season_weekly_rank_badge_rank()` 가 실재하는가
- `evaluate_badge_condition` 본문이 그 둘을 부르는가
- `_season_weekly_rank_badge_rank` 안에 `finalized_at` 필터가 남아 있는가

헬퍼 **안**의 SQL 은 자유롭게 고칠 수 있으므로 오탐하지 않는다.

> ⚠️ **63 의 가드 블록을 이후 마이그레이션에 복사하지 마라.** 63 이 그걸 요구했던 이유는
> 앵커 치환이라는 시공법 때문이었고, 그 시공법이 사라졌다. 63 파일 자체는 이력이므로
> 그대로 둔다 — 신규 환경 replay 에서는 65 **이전** 순서에 실행돼 정상 통과한다.

### 1.4 로직 동치 확인

라이브 `pg_get_functiondef` 를 그대로 옮기고 **세 곳만** 바꿨다(위 표의 헬퍼 호출).
그 밖에 손댄 것은 어느 분기에서도 쓰이지 않던 죽은 선언
`v_season_walk` · `v_participated` · `v_seasons_ok` · `v_i` 제거뿐이다.
**판정 결과를 바꾸는 마이그레이션이 아니다.**

---

## 2. #18 — `user_badges.achieved_value` (마이그레이션 65)

### 2.1 컬럼

```sql
alter table public.user_badges add column achieved_value numeric null;
```

### 2.2 시맨틱 — 단위는 컬럼이 아니라 `badges.condition_type` 이 정한다

| `condition_type` | `achieved_value` | 산출 |
|------------------|------------------|------|
| `pb_time_lte` | **초**(소수 가능) | `_pb_best_seconds(user, distanceKm)` |
| `pb_first_achieved` | **초**(소수 가능) | 〃 |
| `streak_weeks_gte` | **주 수** | 판정 시점 `profiles.longest_streak_weeks` |
| `season_streak_weeks_gte` | **주 수** | `_season_streak_weeks(user, season)` |
| `season_weekly_rank_lte` | **등수**(작을수록 상위) | `_season_weekly_rank_badge_rank(...)` — 자격을 만족한 주가 여러 개면 그중 가장 좋은 등수 |
| `season_weekly_rank_rising_streak_gte` | **연속 상승 주 수** | `_season_weekly_rank_rising_streak(user, season)` |
| **그 밖의 34종** | **항상 `null`** | 확정값 시맨틱이 정의되지 않았다 |

세 가지를 못 박아 둔다.

1. **진행률이 아니다.** 판정 이후 기록이 좋아져도 갱신하지 않는다. "이 뱃지를 딸 때 당신은
   이랬다"를 영구 보존하는 값이고, 그래서 공유 카드가 앱 화면과 어긋나지 않는다.
2. **`null` 은 "값 없음"이지 "0"이 아니다.** 대부분의 뱃지가 `null` 이고 그게 정상이다.
3. **단위가 타입별로 다르다.** 클라이언트가 이 컬럼만 보고 포맷을 정할 수 없다 —
   반드시 `badges.condition_type` 과 함께 읽어야 한다.

### 2.3 기록 지점 — 왜 하필 거기인가

`evaluate_badges` 의 지급 루프 안, **판정이 참이 된 직후·INSERT 와 같은 반복**에서
`badge_achieved_value()` 를 부른다.

```sql
if public.evaluate_badge_condition(...) then
  v_value := public.badge_achieved_value(p_user_id, v_badge.condition_type, v_badge.condition);
  insert into public.user_badges (..., achieved_value) values (..., v_value)
  on conflict (user_id, badge_id) do nothing;
```

여기서 미루면(예: 루프 밖에서 한꺼번에) `runnit.badge_season` GUC 가 이미 다른 뱃지 것으로
바뀌어 있고, 같은 트랜잭션 안에서도 `recompute_profile_stats` 가 도는 3-pass 구조라
**"판정 시점 값"이 아니게 된다.**

지급 경로는 `evaluate_badges` **하나뿐**임을 확인했다(12/13/25/27/31/39 의 INSERT 는 모두
후속 마이그레이션이 대체한 죽은 정의다).

### 2.4 과거 행 백필 — **하지 않는다**

라이브 `user_badges` 199행 중 값 시맨틱이 있는 것은 47행(PB 38 · 스트릭 6 · 주간순위 3).

트리거 폭발 위험은 **먼저 배제했다** — `user_badges` 의 트리거는 둘뿐이고,
XP 재계산 트리거는 `AFTER INSERT OR DELETE OR UPDATE OF verified, revoked` 라
`achieved_value` 만 바꾸는 UPDATE 로는 **뜨지 않는다**. 가드 트리거는 BEFORE 이고
이 컬럼을 되돌리지 않는다. 즉 비용이 이유가 아니다.

백필하지 않는 진짜 이유는 **정확성**이다.

- `_pb_best_seconds` 는 "지금까지의 최고"를 돌려준다. 지금 백필하면 **판정 이후에 세운 더
  좋은 기록**이 "판정 시점 확정값" 자리에 들어간다 — 컬럼 시맨틱을 스스로 어기는 값이고,
  `null` 보다 나쁘다(틀린 숫자가 공유 카드에 박힌다).
- 주간순위 계열은 `leaderboard_entries` 의 과거 주 행이 배치로 재계산·정리될 수 있어
  `earned_at` 만으로 그 순간의 등수를 복원할 수 없다.
- `null` 은 어차피 클라이언트가 다뤄야 하는 정상 상태다(값 시맨틱 없는 34종). 백필을
  건너뛴다고 클라이언트 분기가 하나 더 생기지 않는다.

**현재 데이터는 전량 개발/시드 데이터다**(`season_histories` 0행, `season_leaderboard_snapshots`
0행 — 아직 시즌 마감이 한 번도 없었다). 실사용자 기록 손실이 아니다.

> 나중에 정말 필요해지면: `_pb_best_seconds` 에 `earned_at` 컷오프를 받는 변형을 만들어
> PB 계열만 재구성할 수 있다. 지금 만들지 않는 이유는 호출자가 없는 코드이기 때문이다.

---

## 3. #31 — 무효 시즌 사용자 스냅샷 구멍 (마이그레이션 66)

### 3.1 마이그레이션 58 · 59 · 60 을 다시 읽은 결과

| 마이그 | 한 일 | 남긴 것 |
|--------|-------|---------|
| 58 | `season_leaderboard_snapshots` 신설, 티어별 rank·participant_count 적재 | RLS 정책이 `season_histories` 를 서브쿼리로 봐서 **무효 스냅샷이 전원 공개**(QA C-1) |
| 59 | SECURITY DEFINER 헬퍼로 RLS 밖에서 평가 → 차단 정상화 | 헬퍼가 PostgREST RPC 로 노출(advisor WARN) |
| 60 | 무효 여부를 스냅샷에 **복사**, 정책을 순수 컬럼 술어로, 헬퍼 DROP, `set_season_history_voided()` 단일 진입점 | **행을 숨기기만 했다** |

그래서 현재 상태는 이렇다.

- 3위가 무효 → 나머지에게 **1 · 2 · 4위**로 보인다(3위 자리가 비지도 않는다)
- `participant_count` 는 무효 사용자를 **계속 센다** → "50명 중 4위"인데 유효 참가자는 49명

PRD §8.1/§8.4 의 무효 처리는 "그 사람의 기록을 랭킹에서 제외한다"이지 "그 사람만 안 보인다"가
아니다. 소비 UI(RK-10)가 아직 없어 실피해는 없지만, 화면이 붙는 순간 드러난다.

### 3.2 접근 방식 결정 — 저장값 재랭크(후보 B)

| 후보 | 내용 | 판정 |
|------|------|------|
| A. 읽기 시점 뷰에서 window 재랭크 | 소비 뷰가 조회마다 `rank() over (...)` | ❌ **채택 안 함.** 뷰는 기반 테이블의 RLS 를 그대로 받는다 — 58 의 C-1 이 정확히 그 함정이었다. 무효 행은 **본인에게만** 보이므로 같은 뷰가 본인에게 N행, 남에게 N-1행을 주고 **사람마다 다른 등수**를 낸다. "내 화면의 4위가 남의 화면에서 3위"라는, 59 가 겨우 닫은 부류의 버그 |
| B. 적재·무효 판정 시점에 재랭크해 저장 | rank·participant_count 를 유효 행만으로 다시 매겨 저장 | ✅ **채택.** 등수는 누가 보든 하나여야 하는 값이라 저장이 맞다. 재랭크에 필요한 정렬 키(거리·횟수·도달시각·이동시간·user_id)가 **전부 스냅샷 행 안에 있어** `runs` 를 다시 훑지 않고 테이블 안에서 닫힌다 |
| C. 스냅샷 전체 재산정 | `runs` 부터 다시 집계 | ❌ 과하다. 무효 판정은 참가자 집합만 바꾸고 각자의 거리·횟수는 그대로다. `runs` 재집계는 비싸고, 마감 시점 값이어야 할 스냅샷이 "지금의 runs" 로 흔들릴 위험까지 생긴다 |

### 3.3 무효 행 자신의 rank 는 `null`

`rank` 의 NOT NULL 을 풀고 CHECK 를 걸었다.

```sql
check ((is_voided and rank is null) or (not is_voided and rank is not null))
```

무효 사용자는 자기 행을 여전히 본다(60 정책). 옛 등수를 남기면 "무효인데 12위"라는 모순된
화면이 되고, 0/-1 같은 보초값은 언젠가 정렬에 섞인다. `null` 은 "이 시즌 순위가 없다"를
타입으로 말하는 유일한 방법이고, 클라이언트가 **반드시 분기하게** 만든다.

`participant_count` 는 무효 행에도 **유효 참가자 수**를 넣는다 — "N명 중" 의 N 은 누구에게나
같아야 하고, 무효 사용자 화면에서도 그 시즌 규모는 사실이다.

### 3.4 구현

| 함수 | 변화 |
|------|------|
| `_rerank_season_snapshot(text)` **(신설)** | 스냅샷 테이블 안에서 닫힌 재랭크. 무효 행을 건너뛰며 세는 누적 카운트로 1..N 연속 보장, `count(*) filter (where not is_voided) over (partition by season_id, tier)` 로 참가자 수. 멱등 |
| `snapshot_season_leaderboard(text)` | 적재 window 자체가 무효를 건너뛴다(틀린 rank 로 넣고 고치는 왕복 없음). 부분 적재 대비로 끝에 재랭크 1회 |
| `set_season_history_voided(uuid, text, boolean)` | 두 테이블 갱신 **+ 재랭크**까지 한 트랜잭션. 무효화/해제 양방향. 한 사람이 빠지면 그 티어 전원의 등수가 밀리므로 시즌 단위로 다시 매긴다 |

정렬 키는 58 의 적재 정렬과 **동일**하다: 거리 desc → 횟수 asc → 도달시각 asc → 이동시간 asc
→ user_id asc. user_id 까지 가면 전순서라 `rank` 와 `row_number` 가 일치한다.

RLS 정책은 **건드리지 않았다** — 60 의 순수 컬럼 술어 그대로다. 숨김은 숨김 역할만 하고,
순위 정합은 저장값이 책임진다.

---

## 4. 프로덕션 적용 절차

> 지금까지 원격에 적용된 것은 **없다**. 아래는 사용자 승인 후 실행할 순서다.

1. **사전 확인 (읽기)**
   ```sql
   -- 65 전제
   select count(*) from information_schema.columns
    where table_name='user_badges' and column_name='achieved_value';   -- 0 이어야 한다
   -- 66 전제
   select count(*) from public.season_leaderboard_snapshots;           -- 0 이면 66-5 는 no-op
   ```
2. **65 적용** — `apply_migration(name: '20260908120000_65_badge_achieved_value')`.
   65-8 가드 블록이 마지막에 돌므로, **통과했다면 두 술어가 살아 있다는 뜻**이다.
3. **65 검증 (읽기)**
   ```sql
   select public.evaluate_badge_condition('<기존 사용자 uuid>', 'pb_time_lte',
          '{"distanceKm":5,"seconds":1800}'::jsonb);          -- 65 이전과 같은 결과여야 한다
   select public.badge_achieved_value('<같은 uuid>', 'pb_time_lte',
          '{"distanceKm":5,"seconds":1800}'::jsonb);          -- 초(numeric) 또는 null
   ```
   ⚠️ 두 함수 모두 `authenticated` 에 EXECUTE 가 없으므로 **SQL 에디터/MCP(서비스 롤)로만**
   호출된다. 앱에서 부를 수 있으면 revoke 가 빠진 것이다.
4. **회귀 확인** — 러닝 1건을 업로드(또는 기존 러닝 `updated_at` 터치)해 트리거 체인을 돌리고,
   새로 지급된 `user_badges` 행에 `achieved_value` 가 채워지는지 본다.
   기존 199행은 `null` 로 남는 것이 **정상**이다.
5. **66 적용** — `apply_migration(name: '20260908120100_66_snapshot_void_rerank')`.
6. **66 검증 (읽기)** — 스냅샷이 0행이라 즉시 확인할 것이 없다. 시즌 마감(2026-09-30) 이후
   또는 스테이징에서:
   ```sql
   select tier, count(*) filter (where rank is null) as voided,
          min(rank), max(rank), max(participant_count)
     from public.season_leaderboard_snapshots where season_id = '<시즌>' group by tier;
   -- max(rank) = max(participant_count) 이고 1..N 이 끊기지 않아야 한다
   ```
7. **`get_advisors(security)` · `get_advisors(performance)`** 재확인 (§6).
8. TRD 상태 표기를 "적용 대기" → "원격 적용 완료(날짜)" 로 갱신.

**롤백.** 65 는 컬럼 추가와 함수 재정의뿐이라 실사용 데이터를 파괴하지 않는다
(되돌리려면 이전 정의를 다시 실으면 된다 — 그런데 그 이전 정의는 앵커 치환의 산물이라
**되돌아갈 파일이 없다.** 이것이 65 를 굳이 전문 관리로 바꾼 이유이기도 하다).
66 은 `rank` 를 다시 NOT NULL 로 만들려면 무효 행에 값을 채워야 하므로,
되돌릴 일이 생기면 CHECK 만 드롭하고 컬럼은 nullable 로 두는 편이 안전하다.

**문법 검증 한계.** 이 환경에는 로컬 Postgres 가 없어(psql/docker 미설치) 두 파일을
실행해 본 적이 없다. **먼저 Supabase 브랜치에 적용해 보는 것을 권한다** — 특히
66-2 의 window + `update ... from cte` 조합.

---

## 5. 클라이언트가 읽어야 할 wire 키 · 타입 (Dart 담당 인수인계)

> **이번 라운드에서 Dart 코드는 전혀 건드리지 않았다.** 아래는 마이그레이션 적용 후에
> 별도로 처리할 항목이다.

### 5.1 `user_badges.achieved_value`

| 항목 | 값 |
|------|-----|
| wire 키 (snake_case) | `achieved_value` |
| PostgREST 타입 | `numeric` → JSON 에 **숫자** 또는 `null` (`double` 로 받으면 안전) |
| Dart 필드 | `achievedValue` (`double?`) |
| 단위 | **`badges.condition_type` 이 정한다** — §2.2 표. 이 값만으로 포맷을 결정하면 안 된다 |
| 기본값 | 없음. 65 이전 지급분은 전부 `null` |

**PB 공유 카드(`lib/features/sharing/domain/share_card_data.dart` `certifiedSeconds`) 정리 방향**

```
현재: 세션 거리 ≤ 목표×102% → run.movingSeconds
      초과                  → null
이후: certifiedSeconds = achievedValue?.round()   // 서버 값 하나만
```

- `moving_seconds` **폴백 분기를 삭제**한다. 그 분기가 존재한 유일한 이유는
  "서버가 확정한 숫자가 어디에도 없다"였고, 이제 있다.
- `null` 처리는 **그대로 남는다** — 65 이전 뱃지(백필 안 함, §2.4)와 값 시맨틱 없는
  조건 타입이 `null` 이다. 카드는 지금처럼 시간 없이 "5km PB 갱신"만 말한다.
- ⚠️ 개발 DB 의 기존 PB 뱃지 38행은 `null` 이라 **적용 직후 카드에 시간이 안 나온다.**
  버그가 아니다. 실사용자 데이터가 아니므로 시드 재생성으로 해소하면 된다.
- ⚠️ `achievedValue` 를 `int` 로 받지 마라. `numeric` 이고 PB 초는 보간값이라 소수가 나온다.

### 5.2 `season_leaderboard_snapshots.rank`

| 항목 | 값 |
|------|-----|
| wire 키 | `rank` |
| 타입 변화 | `integer not null` → **`integer null`** |
| Dart | `int` → **`int?`** (필수) |
| 의미 | `null` ⇔ `is_voided = true` ⇔ **그 시즌 순위가 존재하지 않는다** (CHECK 로 강제) |
| `participant_count` | 의미 변경 — **유효 참가자 수**(무효 제외). 타입·nullability 변화 없음 |

RK-10 UI 는 `rank == null` 분기를 반드시 가져야 한다. "무효 처리된 시즌" 표기이며,
0위·미참여와 구분해야 한다. (현재 이 테이블을 읽는 Dart 코드는 없다 —
소비 UI 가 붙기 전에 스키마가 확정되는 편이 낫다는 것이 이 순서의 이점이다.)

### 5.3 안 바뀐 것

`badges` · `leaderboard_entries` · `season_histories` · `runs` 의 wire 계약은 그대로다.
`evaluate_badge_condition` 판정 결과도 동치다(§1.4).

---

## 6. `get_advisors` 예상 영향

**적용 전 baseline (2026-09-08 조회): security WARN 6건.**
`rls_auto_enable`(anon+authenticated) · `mark_notifications_read` · `register_push_token` ·
`sync_my_season` · `auth_leaked_password_protection`.

**예상: 신규 0건.**

| 신규 함수 | SECURITY DEFINER | 조치 |
|-----------|------------------|------|
| `_badge_eval_season()` | O | `revoke execute from public, anon, authenticated` |
| `_season_weekly_rank_badge_rank(...)` | O | 〃 |
| `_season_streak_weeks(...)` | O | 〃 |
| `_season_weekly_rank_rising_streak(...)` | O | 〃 |
| `badge_achieved_value(...)` | O | 〃 |
| `_rerank_season_snapshot(text)` | O | 〃 |

Postgres 는 새 함수에 EXECUTE 를 PUBLIC 으로 기본 부여하므로 이 revoke 가 **필수**다.
59 가 헬퍼 하나에 grant 를 줬다가 advisor WARN 을 새로 얻은 전례가 정확히 이 지점이다
(TRD §14 #32) — 이번 헬퍼들은 RLS 정책식이 아니라 SECURITY DEFINER 함수 내부에서만
불리므로 grant 가 아예 필요 없다.

**performance:** 인덱스 추가·삭제 없음.
- `achieved_value` 는 nullable numeric 이고 조회 술어로 쓰이지 않아 인덱스가 필요 없다.
- `_rerank_season_snapshot` 은 `season_id` 로 좁히므로 기존
  `idx_season_snapshots_season_tier_rank(season_id, tier, rank)` 가 그대로 듣는다.
- `rank` 의 NOT NULL 해제는 인덱스 유효성에 영향이 없다.
- `unindexed_foreign_keys` / `unused_index` 계열이 새로 뜰 여지는 없다.

적용 후 두 종류 모두 재조회해 **6건에서 늘지 않았음**을 확인할 것.

---

## 7. TRD §14 갱신 문구 (그대로 붙여넣기용)

**#18**

> ~~18~~ | **`user_badges.achieved_value` 신설 — 마이그레이션 65 작성 완료, 원격 적용 대기**(2026-09-08). 컬럼 `achieved_value numeric null` + 확정값 디스패처 `badge_achieved_value()` + `evaluate_badges` 가 지급 시 함께 적는다. 시맨틱은 조건 타입이 정한다 — PB 계열 = 초(보간값 포함), 스트릭 계열 = 주 수, 주간순위 계열 = 등수, **나머지 34종은 항상 null**. 진행률이 아니라 판정 시점 확정값이며 이후 갱신하지 않는다. **과거 199행은 백필하지 않는다** — 트리거 비용이 아니라 정확성 때문이다(`_pb_best_seconds` 는 "지금까지의 최고"라 백필하면 판정 이후의 더 좋은 기록이 "판정 시점 값" 자리에 들어간다). 클라이언트는 `share_card_data.dart` 의 `moving_seconds` 폴백 분기를 지우고 `certifiedSeconds = achievedValue?.round()` 하나만 쓴다(`null` 처리는 유지). 상세 `_workspace/20260908_backend_trd14-cleanup.md`

**#31**

> ~~31~~ | **무효 시즌 사용자 재랭크 — 마이그레이션 66 작성 완료, 원격 적용 대기**(2026-09-08). 60 이 "행을 숨기기"까지만 해서 남은 rank 구멍(3위가 무효면 1·2·4위, participant_count 는 무효 포함)을 **저장값 재랭크**로 닫는다. **읽기 시점 뷰 재랭크는 채택하지 않았다** — 뷰는 기반 테이블 RLS 를 그대로 받아 무효 행이 본인에게만 보이므로 사람마다 다른 등수가 나온다(58 C-1 과 같은 부류). `_rerank_season_snapshot()` 신설, `snapshot_season_leaderboard()` 는 적재 window 에서 무효를 건너뛰고, `set_season_history_voided()` 가 무효화/해제 후 재랭크까지 한 트랜잭션에서 끝낸다. **`rank` 는 nullable 이 되고 `is_voided ⇔ rank is null` CHECK 로 묶인다** — 무효 사용자에게 옛 등수를 보여 주지 않기 위해서다. `participant_count` 는 유효 참가자 수로 의미가 바뀐다. RK-10 UI 는 `rank == null` 분기 필수. 상세 `_workspace/20260908_backend_trd14-cleanup.md`

**#33**

> ~~33~~ | **`evaluate_badge_condition` 앵커 치환 폐기 — 마이그레이션 65 작성 완료, 원격 적용 대기**(2026-09-08). 전문 관리와 분해를 **둘 다** 했다. (a) 65 파일이 이 함수의 정본이며 `replace(pg_get_functiondef(...))` 관행은 끝났다. (b) 사라지면 안 되는 두 술어를 `_badge_eval_season()`(61-3 GUC)과 `_season_weekly_rank_badge_rank()`(57-5 finalized_at)로 뽑았다 — 후자는 boolean 이 아니라 **자격 등수**를 돌려주어 #18 의 확정값과 판정이 같은 SQL 을 보게 한다. 마이그레이션 63 의 문자열 가드는 **호출 관계 검사**(65-8)로 대체됐고, **63 블록을 이후 마이그레이션에 복사하는 규약은 폐지**한다(63 파일 자체는 이력으로 남으며 신규 환경 replay 에서는 65 이전 순서라 정상 통과). 판정 결과는 동치 — 헬퍼 호출 3곳과 죽은 변수 선언 4개 제거 외에 본문 변경 없음. 상세 `_workspace/20260908_backend_trd14-cleanup.md`

---

## 8. 남는 것 / 이번 범위 아님

- **`_season_weekly_rank_rising_streak` 의 알려진 한계** — 사용자의 **현재 티어** 행만 본다.
  시즌 중 승급하면 승급 이전 주가 집계에서 빠진다. 27/41 의 원 로직을 그대로 옮긴 것이며
  이번에 고치지 않았다(로직 변경 없는 마이그레이션이라는 전제를 지키기 위해).
  별도 항목으로 등재할지는 gamification-designer 판단.
- **`achieved_value` 를 쓰는 조건 타입 확장** — 지금은 6종. `cumulative_distance_gte`(누적 m),
  `season_tier_reached`(시즌 누적 m) 등을 넣고 싶으면 `badge_achieved_value` 에 분기를
  추가하되, **계산식을 복사하지 말고 양쪽이 함께 부르는 함수로 뽑을 것**(#33 의 교훈).
- **로컬 문법 검증 부재** — §4 말미 참조. 브랜치 선적용 권장.
