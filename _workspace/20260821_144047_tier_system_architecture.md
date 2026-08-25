# Runnit 티어 시스템 데이터 모델 v1.0 — PRD 기준

- 작성: mobile-architect
- 일자: 2026-08-21
- 기준 문서: `/Users/jehyun/Runnit/.claude/worktrees/prd-brd-planning-9a0347/docs/PRD.md` (v1.3 확정)
- 선행 계약: `_workspace/20260819_132600_architect_data-model.md` (단위 규약 §0, 필드 매핑 §1 — **그대로 유효**)
- 상태: **확정.** 이 라운드 범위는 TI-01~08, §8.1, §8.5, §8.6, RK-02, HI-06.

> **호환성**: 이번 변경은 전부 **필드 추가**다. 기존 필드 삭제·이름 변경·타입 변경이 없으므로
> **breaking change가 아니다.** 기존 코드는 그대로 컴파일된다(`dart analyze` 클린, `flutter test` 38건 통과 확인).

---

## 0. 요약 — 무엇이 바뀌었나

| 파일 | 변경 |
|------|------|
| `lib/models/enums.dart` | `Tier` enum + `TierX` 확장(기준선·판정·다음 티어) 추가 |
| `lib/models/season.dart` | **신규** — `Season` / `RankingWeek` 경계 계산 (테이블 없음) |
| `lib/models/app_user.dart` | `currentTier` / `seasonDistanceMeters` / `tierSeasonId` 추가 + 진행률 getter |
| `lib/models/ranking_entry.dart` | `tier` / `participantCount` 추가 + `topPercent` getter |
| `lib/models/season_history.dart` | **신규** — HI-06 역대 시즌 기록 |
| `lib/models/models.dart` | 배럴에 신규 파일 export |
| `lib/core/api/wire_enums.dart` | `TierWire` 추가 (쿼리 필터용 문자열) |
| `test/models/tier_season_test.dart` | **신규** — 기준선·경계·직렬화 18건 |

---

## 1. `Tier` enum

```
bronze / silver / gold / platinum   (Postgres: create type public.tier as enum (...))
```

| 티어 | 시즌 누적 거리 하한 | 저장값(m) |
|------|-------------------|-----------|
| 브론즈 | 0km | 0 |
| 실버 | 25km | 25000 |
| 골드 | 100km | 100000 |
| 플래티넘 | 250km | 250000 |

### 왜 기존 `BadgeTier`를 재사용하지 않았나
`BadgeTier`(bronze/silver/gold/platinum)와 라벨이 완전히 같아서 통합하고 싶어진다. 통합하지 않은 이유:
**두 값의 의미가 다르다.** `BadgeTier`는 *뱃지 카탈로그의 희소도 속성*이고, `Tier`는 *사용자 프로필의
시즌 경쟁 등급*이다. 통합하면 뱃지 희소도 체계를 5단계로 바꾸는 순간 경쟁 티어가 딸려 움직이고,
Postgres enum 하나를 두 테이블이 서로 다른 의도로 참조하게 된다. 별도 enum · 별도 Postgres 타입으로 둔다.

### 클라이언트 계산의 위치
`TierX.fromSeasonDistanceMeters()` / `remainingToNextMeters()`는 **표시용 예측 전용**이다.
PRD §6 "티어 정합성 — 티어·랭킹은 서버가 단일 진실 원천, 클라이언트 계산 값 신뢰 금지"에 따라,
클라이언트가 계산한 티어를 서버에 쓰거나 서버가 내려준 `currentTier`를 덮어쓰지 않는다.
`AppUser.tierProgress`는 **거리에서 티어를 재유도하지 않고 서버가 준 `currentTier`를 기준선으로 삼는다**
— 서버 갱신이 한 박자 늦어도 화면의 티어 배지와 진행률 바가 모순되지 않게 하기 위함이다.

---

## 2. 시즌 — **테이블을 만들지 않는다 (확정)**

**결정: `seasons` 테이블 없이 `seasonId` 문자열(`"2026-Q3"`) + 순수 함수로 표현한다.**

### 근거
시즌은 역년 분기로 고정(§8.5)되어 있어 달력에서 결정론적으로 유도된다. 운영자가 시즌을 만들거나
날짜를 조정하는 절차가 존재하지 않고, 시즌에 붙일 가변 속성(이름·보상 등)도 현재 없다.
테이블을 두면 얻는 것 없이 세 가지 비용이 생긴다.

1. 매 분기 행을 미리 심어두는 **운영 작업**이 생긴다.
2. 행이 없는 분기에 러닝이 들어오면 **FK 위반으로 업로드가 실패**한다 — 달력이 알아서 굴러가는
   개념을 사람이 관리하는 데이터로 바꾼 대가다.
3. 클라이언트가 TI-05 진행률 바를 그리려고 **시즌 경계를 조회하는 네트워크 왕복**이 추가된다.

시즌 한정 뱃지·시즌 테마(GM-08, P1)가 실제로 필요해지면 그때 `seasons` 테이블을 추가한다.
그 경우에도 `season_id`가 자연키가 되므로 **지금 저장한 값이 그대로 재사용된다** — 마이그레이션 비용이 낮다.

### `seasonId` 형식: `"{연도}-Q{1..4}"`
- GM-07 티어 뱃지 이름("2026 Q3 플래티넘")에 그대로 쓰인다.
- 문자열 정렬 = 시간 순 정렬 (`2026-Q3` < `2026-Q4` < `2027-Q1`). 인덱스·`ORDER BY`가 단순해진다.

### 경계 (전부 UTC 반환, KST=UTC+9 고정 — 한국은 서머타임 없음)
| 개념 | 규칙 | 예 |
|------|------|-----|
| 시즌 시작 | 분기 첫날 00:00 KST | `2026-Q3` → `2026-06-30T15:00Z` |
| 시즌 종료 | 다음 시즌 시작 (**배타적**, 반열림 `[start, end)`) | `2026-09-30T15:00Z` |
| 주간 시작 | 월요일 00:00 KST | 기존 `leaderboard_period_bounds`의 `date_trunc('week', ... 'Asia/Seoul')`와 **동일** |
| 귀속 | 러닝 **시작 시각** 기준 (§8.5) | 9/30 23:30 KST 시작 → `2026-Q3` |

### 첫 시즌(단축 시즌)
§8.5의 "첫 시즌은 단축 시즌"은 **별도 개념이 아니다.** 출시일이 속한 분기가 그대로 첫 시즌이고
사용자가 분기 도중에 합류할 뿐이다. 티어는 절대평가라 기간이 짧아도 판정이 정상 작동한다.
**코드·스키마에 단축 시즌 분기 처리를 두지 않는다.**

---

## 3. `AppUser`(profiles) 티어 필드

| Dart 필드 | DB 컬럼 | 타입 (Postgres) | 기본값 | 단위 | 설명 |
|-----------|---------|-----------------|--------|------|------|
| `currentTier` | `current_tier` | `public.tier not null` | `'bronze'` | — | 현재 시즌 티어 |
| `seasonDistanceMeters` | `season_distance_meters` | `double precision not null` | `0` | m | **티어 판정 기준 거리** |
| `tierSeasonId` | `tier_season_id` | `text` (nullable) | `null` | — | `'2026-Q3'`. 시즌 리셋 트리거 기준점 |

전부 **서버 전용 쓰기**다 — 기존 통계 캐시 필드와 동일하게 `05_server_guards`의 가드 트리거 대상에 추가할 것
(계약서 §1.3 표에 이 세 필드를 넣는다).

### `seasonDistanceMeters` ≠ `totalDistanceMeters` (가장 중요)

| | `totalDistanceMeters` | `seasonDistanceMeters` |
|---|---|---|
| 기간 | 전 기간 | 현재 시즌만 |
| 상태 필터 | `status='completed' and is_flagged=false` | 동일 |
| **활동 유형** | **전부 포함 (트레드밀 포함)** | **`activity_type <> 'indoor_run'` 만** |
| 근거 | §8.3 "누적 통계·히스토리 ✅ 반영" | §8.3 "티어 누적 거리 ❌ 미반영" |

즉 **트레드밀 기록은 누적 통계에는 들어가고 티어 거리에는 안 들어간다.** 이 비대칭이 PRD의 의도다
(기록은 남고 인정도 받되, 경쟁 지표에는 들어가지 않는다).

`ActivityType.indoorRun`이 §8.3의 "트레드밀 기록"에 정확히 대응한다 — **별도 `isManual` 플래그를 새로
만들지 않았다.** `lib/models/enums.dart`의 기존 주석("트레드밀 — GPS 좌표 없음")과
`tracking_format.dart`의 `hasRoute(type) => type != ActivityType.indoorRun`이 이미 같은 판정을 쓰고 있다.
개념을 하나 더 만들면 두 판정이 갈라진다.

> ⚠️ 웨어러블(P1) 도입 시 §5.7의 "경로 샘플 유무" 판정이 추가로 필요해진다. 그때는
> `activity_type <> 'indoor_run'` 조건에 "경로 샘플 존재" 조건이 **AND로 덧붙는다** —
> 지금 조건을 바꿀 필요는 없다. 이번 라운드에서 처리하지 않는다.

### 시즌 리셋 트리거 (§8.1 "시즌 종료: 최종 티어 기록 후 전원 브론즈 초기화")

`tier_season_id <> Season.currentId()`를 **읽기/쓰기 경로 양쪽에서** 비교한다:

```
if profiles.tier_season_id is distinct from <현재 시즌>:
    1) tier_season_id 가 not null 이면 → season_histories 에 그 시즌 결과 확정 INSERT
       (UNIQUE (user_id, season_id) 로 중복 마감 방지 — ON CONFLICT DO NOTHING)
    2) current_tier = 'bronze', season_distance_meters = 0
    3) tier_season_id = <현재 시즌>
```

배치(cron)로도 분기 전환 시점에 일괄 실행하되, **배치에만 의존하지 않는다.** 배치가 실패하거나
지연돼도 다음 러닝 업로드/프로필 조회에서 스스로 복구되게 하기 위함이다(멱등해야 한다).

---

## 4. `RankingEntry` — RK-02 티어 내 랭킹

**결정: 티어를 `RankingScope`의 새 값으로 넣지 않고, `scope`와 직교하는 별도 `tier` 필드로 둔다.**

| Dart 필드 | DB 컬럼 | 타입 | 설명 |
|-----------|---------|------|------|
| `tier` | `tier` | `public.tier` **nullable** | null = 티어 미분할 통합 보드 |
| `participantCount` | `participant_count` | `integer` nullable | RK-04 "상위 N%" 계산용 모집단 크기 |

### 근거
`scope`는 **"누구와 겨루는가"라는 모집단 축**(전체/크루/친구)이고, 티어는 **그 모집단을 실력으로 자르는
필터 축**이다. 서로 직교한다. `RankingScope.tier`를 추가하면:
- "크루 안에서의 티어 랭킹"(P2에서 실제로 나올 조합)을 표현할 수 없다.
- `scope='tier'`가 crew/friends와 배타적이 되어, 조합이 필요해지는 순간 enum이 조합 폭발한다.
- 기존 `RankingScope`를 참조하는 코드(`ranking_page.dart`의 탭 목록, `wire_enums.dart`)가
  "탭으로 노출할 스코프"와 "필터"를 구분하지 못하게 된다.

`tier`를 nullable로 둔 것도 의도적이다 — **기존 daily/monthly/all_time 보드를 삭제하지 않기 위해서**다.
PRD 범위 밖이지만 이미 동작 중인 조합이므로 `tier = null`로 그대로 살아 있고,
PRD가 요구하는 보드만 `tier != null`로 새로 생긴다.

### PRD가 요구하는 조합 (반드시 존재해야 하는 것)

```
period = weekly · metric = distance · scope = global · tier ∈ {bronze,silver,gold,platinum}
```

이것이 앱의 **기본 랭킹 화면**이다 (RK-01 + RK-02 + RK-03).
`lib/features/ranking/data/ranking_providers.dart`의 `rankingPeriodV1 = RankingPeriod.weekly`는 이미 맞다.

**PRD 범위 밖으로 남겨두는 것** (삭제하지 않음): `daily` / `monthly` / `all_time` 기간,
`duration` / `run_count` 지표, `crew` / `friends` 스코프. PRD에 없다는 이유로 지우면
이미 붙어 있는 UI가 깨지고, 되살릴 때 비용이 든다.

### RK-08 / §8.6 주중 승급 시 랭킹 이관
"주간 누적 거리를 그대로 이관"은 **별도 이관 로직이 필요 없다.** 랭킹 점수의 원천이
`runs`의 주간 합계이므로, 승급 후 갱신에서 새 티어 보드에 같은 합계로 다시 계산될 뿐이다.
backend가 보장해야 할 것은 하나뿐: **이전 티어 보드에 남은 그 사용자의 행이 정리되는 것.**
현행 `refresh_leaderboard` 말미의 `computed_at < v_now` 정리 로직이 이 역할을 하지만,
티어 차원이 PK에 들어가면 **이전 티어 조합도 함께 갱신되어야** 그 행이 지워진다(§7 작업 목록 참조).

---

## 5. `SeasonHistory` — HI-06 역대 시즌 기록

테이블 `season_histories`. **유저당 시즌당 1행**, `UNIQUE (user_id, season_id)`.

| Dart 필드 | DB 컬럼 | 타입 | 단위 | 설명 |
|-----------|---------|------|------|------|
| `id` | `id` | `uuid` PK | — | 서버 생성 |
| `userId` | `user_id` | `uuid not null` → `profiles(id)` on delete cascade | — | |
| `seasonId` | `season_id` | `text not null` | — | `'2026-Q3'` |
| `finalTier` | `final_tier` | `public.tier not null` | — | 마감 시점 확정 티어 |
| `distanceMeters` | `distance_meters` | `double precision not null default 0` | m | 검증 통과 + 실외만 |
| `runCount` | `run_count` | `integer not null default 0` | 회 | 동일 필터 |
| `movingSeconds` | `moving_seconds` | `integer not null default 0` | s | 동일 필터 |
| `bestWeeklyRank` | `best_weekly_rank` | `integer` nullable | — | 그 시즌 최고 주간 순위 |
| `closedAt` | `closed_at` | `timestamptz not null` | UTC | 마감 처리 시각 |
| `isVoided` | `is_voided` | `boolean not null default false` | — | 사후 부정 판정 무효화(§8.1) |

`startAt` / `endAt`은 **컬럼이 아니다** — `seasonId`에서 파생되는 getter다. 역년 분기가 결정론적이라
컬럼으로 두면 중복 진실이 된다.

### 설계 근거
- **왜 마감 스냅샷인가**: `runs`에서 매번 재집계해 복원할 수도 있지만, 그러면 이후의 기록 삭제·
  부정 판정이 **과거 시즌의 확정 결과를 소급해 바꾼다.** "2026 Q3 플래티넘"이 나중에 골드로 바뀌면
  뱃지(GM-07)와 어긋난다. 시즌 결과는 마감 시점에 못 박는다.
- **왜 진행 중 시즌 행을 만들지 않는가**: 현재 시즌 상태는 `profiles.current_tier` /
  `season_distance_meters`가 들고 있다. 두 곳에 동시에 쓰면 어느 쪽이 진실인지 모호해진다.
  `season_histories`에는 **끝난 시즌만** 들어간다.
- **왜 `isVoided`인가**: 부정 판정 시 행을 삭제하면 이의 제기(§8.4 "이의 제기 경로 필수") 대응
  근거가 사라진다. 행은 남기고 표시만 지운다.

---

## 6. 🔴 §8.3 정책 위반 결함 — backend-engineer 인계

### 결함
**`refresh_leaderboard()`가 `activity_type`으로 필터링하지 않는다.**
즉 **트레드밀(`indoor_run`) 기록이 지금 이미 주간 랭킹 점수에 합산되고 있다.**
PRD §8.3 "트레드밀 기록 → 주간 랭킹 ❌ 미반영" 위반.

- 위치: `supabase/migrations/20260819220300_11_leaderboard_tiebreak.sql` L61~68 의 `base` CTE
  (원본은 `20260819140300_03_leaderboard.sql` L126~141, 11번이 함수를 재정의하며 그대로 승계).
- 현행 WHERE 절: `r.status='completed' and r.is_flagged=false and r.started_at >= v_start and < v_end`
  — **활동 유형 조건이 없다.**

### 재현 방법
```sql
-- 1) 임의 사용자로 트레드밀 기록 1건 삽입 (이번 주 KST 안의 시각으로)
insert into public.runs (id, user_id, started_at, ended_at, activity_type, status,
                         distance_meters, elapsed_seconds, moving_seconds)
values (gen_random_uuid(), '<user_uuid>', now(), now() + interval '30 min',
        'indoor_run', 'completed', 5000, 1800, 1800);

-- 2) 주간 거리 리더보드 갱신
select public.refresh_leaderboard('weekly', 'distance', 'global');

-- 3) 결과 확인 — score 에 위 5000m 가 포함되어 있다 (기대: 제외)
select user_id, score, run_count
from public.leaderboard_entries
where user_id = '<user_uuid>' and period='weekly' and metric='distance' and scope='global';
```
**기대**: 트레드밀 기록만 있는 사용자는 리더보드에 **아예 나타나지 않아야 한다**(`score > 0` 필터에 걸려 탈락).
**실제**: `score = 5000`으로 등재된다.

### ⚠️ 함께 확인할 것 — `recompute_profile_stats()`는 **고치면 안 된다**
`recompute_profile_stats()`도 `activity_type` 필터가 없다. 하지만 이쪽은 **정상**이다 —
§8.3이 "누적 통계·히스토리 ✅ 반영"이라고 명시하므로 `total_distance_meters` 등에는 트레드밀이
들어가는 것이 맞다. **여기에 필터를 넣으면 오히려 PRD 위반이 된다.**
새로 추가되는 `season_distance_meters`만 `activity_type <> 'indoor_run'` 필터를 받는다.

### (참고) 함께 발견한 §8.2 불일치 — 이번 라운드 범위 밖
PRD §8.2의 주간 랭킹 동점 처리는 **① 더 적은 러닝 횟수 → ② 먼저 도달 → ③ 총 시간 짧은 순**이다.
현행 구현(`11_leaderboard_tiebreak.sql`)은 `distance` 지표에서 `sum(moving_seconds)` 오름차순 단일 기준
= PRD의 ③만 반영하고 ①②가 빠져 있다. 정책 확정 주체가 gamification-designer이므로 이번 라운드에서
건드리지 않고 **기록만 남긴다.**

---

## 7. backend-engineer 작업 목록 (이번 라운드)

우선순위 순. 전부 신규 마이그레이션 파일로 — 기존 파일 수정 금지.

1. **enum 추가** — `create type public.tier as enum ('bronze','silver','gold','platinum');`
   (`badge_tier`와 별개 타입. §1 근거 참조)
2. **`profiles` 컬럼 3개 추가** — §3 표대로.
   `current_tier public.tier not null default 'bronze'`,
   `season_distance_meters double precision not null default 0`,
   `tier_season_id text`.
   → `05_server_guards`의 서버 전용 컬럼 가드 목록에 3개 모두 추가.
3. **시즌 경계 SQL 함수** — Dart `Season`과 **동일한 규약**으로:
   `season_id_at(timestamptz) → text` (`to_char(ts at time zone 'Asia/Seoul', 'YYYY"-Q"Q')`),
   `season_start(text) / season_end(text) → timestamptz`.
   ⚠️ Dart와 결과가 어긋나면 진행률 바와 서버 판정이 갈라진다 — `test/models/tier_season_test.dart`의
   경계 케이스(`2026-06-30T14:59Z` = Q2, `15:00Z` = Q3)를 SQL에서도 동일하게 확인할 것.
4. **`season_distance_meters` 재계산 + 티어 판정** — `recompute_profile_stats()`를 확장하거나
   별도 `recompute_season_tier(uuid)`를 추가:
   ```sql
   where r.user_id = p_user_id
     and r.status = 'completed'
     and r.is_flagged = false
     and r.activity_type <> 'indoor_run'          -- §8.3
     and r.started_at >= season_start(<현재 시즌>)  -- §8.5 시작 시각 귀속
     and r.started_at <  season_end(<현재 시즌>)
   ```
   티어 = 25000/100000/250000 기준선 판정. **TI-03 "기록 저장 즉시 판정, 배치 대기 없음"** —
   기존 `runs_recompute_stats` 트리거 경로에 태울 것.
   §8.1 "기록 삭제 시 기준선 미달이면 티어 하향"은 전체 재계산 방식이라 자동 충족된다.
5. **시즌 리셋** — §3의 3단계 로직. 멱등하게. cron(분기 첫날 00:05 KST) + 읽기/쓰기 경로 지연 복구 양쪽.
6. **`season_histories` 테이블** — §5 표대로. `UNIQUE (user_id, season_id)`,
   인덱스 `(user_id, season_id desc)`. RLS: 본인 + 공개 프로필 select, 클라이언트 write 전면 금지.
7. **🔴 §8.3 결함 수정** — `refresh_leaderboard()`의 `base` CTE WHERE 절에
   `and r.activity_type <> 'indoor_run'` 추가. §6의 재현 절차로 수정 전/후 확인.
8. **리더보드 티어 차원** — `leaderboard_entries`에
   `tier public.tier` (nullable), `participant_count integer` 추가.
   - PK에 티어를 넣어야 티어별 보드가 공존한다. `crew_key`와 같은 패턴으로
     `tier_key text generated always as (coalesce(tier::text,'_all')) stored`를 두고
     PK를 `(scope, crew_key, tier_key, period, metric, period_start, user_id)`로 재정의.
     (nullable 컬럼은 `ON CONFLICT` 추론이 되지 않는다 — 기존 `crew_key` 주석과 동일한 이유)
   - `refresh_leaderboard`에 `p_tier public.tier default null` 파라미터 추가.
     non-null이면 `join profiles p ... and p.current_tier = p_tier`로 모집단을 자르고,
     `rank()`도 그 모집단 안에서 매긴다.
   - `participant_count` = 해당 보드의 `count(*)` (RK-04 상위 % 계산용).
   - `refresh_all_leaderboards`에 **weekly × distance × global × 4티어** 조합을 반드시 포함.
   - **RK-08 주의**: 주중 승급자가 이전 티어 보드에 남지 않도록, 갱신 시 4개 티어 조합을
     **항상 함께** 돌려야 `computed_at < v_now` 정리 로직이 그 행을 지운다.
     한 티어만 부분 갱신하면 승급 전 티어에 유령 행이 남는다.
9. **RK-02 조회 경로** — 클라이언트 필터는 `.eq('tier', <TierWire.wire>)`. `tier`가 응답 JSON에
   그대로 실려야 `RankingEntry.fromJson`이 채운다(별칭 금지, 계약서 §1.1).

---

## 8. 다른 팀원 영향

| 담당 | 영향 |
|------|------|
| **backend-engineer** | §7 전체. 특히 §6 결함 수정을 이번 라운드에 포함할 것 |
| **flutter-ui-designer** | `AppUser.tierProgress` / `remainingToNextTierMeters` / `RankingEntry.topPercent` 사용 가능. TI-04(승급 연출) / TI-05(홈 진행률 바) 화면은 **다음 라운드** |
| **gamification-designer** | GM-07 시즌 티어 뱃지는 다음 라운드. 이번 라운드에서 포인트/레벨/스트릭 로직은 **건드리지 않았다**. §6의 §8.2 동점 처리 불일치 확인 요망 |
| **gps-tracking-engineer** | 영향 없음. `ActivityType.indoorRun`이 티어 제외 판정의 유일한 기준이 되었으므로, 트레드밀 기록에 이 값을 정확히 세울 것 |
| **qa-integration-tester** | `profiles` 3필드 / `leaderboard_entries` 2필드 / `season_histories` 전체의 모델↔스키마 대조 |

---

## 9. 다음 라운드로 미룬 항목 (이번에 손대지 않음)

| ID | 내용 | 담당 |
|----|------|------|
| GM-07 | 시즌 한정 티어 뱃지 동적 발급 ("2026 Q3 플래티넘") | gamification-designer |
| RK-09 / RK-10 | 명예의 전당 · 시즌 누적 랭킹 탭 (P1) | gamification-designer + backend |
| NT-01~03 | 티어 승급 / 근접 / 시즌 D-14·D-3 알림 | backend + UI |
| TI-04 / TI-05 | 승급 연출 · 홈 진행률 바 화면 | flutter-ui-designer |
| TI-09 | 역대 최고 티어 프로필 표시 (P1) | — |
| §5.7 | 웨어러블 "경로 샘플 유무" 판정 (P1) | gps-tracking-engineer |
| §8.2 | 주간 랭킹 동점 처리 PRD 정합화 (§6 참고 항목) | gamification-designer |

---

## 10. 검증 결과

```
dart run build_runner build   → 128 outputs, 성공
dart analyze                  → No issues found!
flutter test                  → 기존 38건 + 신규 18건 전부 통과
```

기존 코드에 컴파일 에러 없음 — `Tier`는 신규 enum이고 `RankingScope` / `BadgeCategory`에는
값을 추가하지 않았으므로 exhaustive switch가 깨지지 않는다.
