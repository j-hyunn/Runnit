# Runnit 티어 시스템 백엔드 반영 보고

- 작성: backend-engineer
- 일자: 2026-08-21
- 입력 스펙: `_workspace/20260821_144047_tier_system_architecture.md` §7 (작업 목록)
- 원격 프로젝트: Supabase `Runnit` / `xwtbwexcofcgmbvktwdo` (ap-southeast-1) — **전 마이그레이션 적용 완료**
- 상태: **완료.** §7의 9개 항목 전부 반영 + 검증. 테스트 데이터 전량 삭제.

---

## 0. 신규 마이그레이션 파일 (기존 00~18은 수정하지 않음)

| 파일 | 내용 | 원격 적용명 |
|------|------|-------------|
| `supabase/migrations/20260821150000_19_tier_enum_and_profile_columns.sql` | `public.tier` enum, `tier_for_distance()`, `profiles` 3컬럼, `trg_profiles_guard` 확장 | `19_tier_enum_and_profile_columns` |
| `supabase/migrations/20260821150100_20_season_boundaries.sql` | `season_id_at` / `season_start` / `season_end` / `season_next_id` / `season_previous_id` | `20_season_boundaries` |
| `supabase/migrations/20260821150200_21_season_histories.sql` | `season_histories` 테이블 + 인덱스 + RLS | `21_season_histories` |
| `supabase/migrations/20260821150300_22_season_tier_recompute.sql` | `recompute_season_tier`, 트리거 배선, `reset_stale_seasons`, `sync_my_season`, cron 2건, 기존 프로필 백필 | `22_season_tier_recompute` |
| `supabase/migrations/20260821150400_23_leaderboard_tier_and_indoor_fix.sql` | 🔴 §8.3 결함 수정 + 리더보드 티어 차원(`tier`/`participant_count`/`tier_key`/PK 재정의) + `refresh_leaderboard(p_tier)` / `refresh_all_leaderboards` | `23_leaderboard_tier_and_indoor_fix` |

> ⚠️ 로컬 파일 번호는 19~23이지만 원격 `supabase_migrations` 이력에는 과거 세션의 번호 부여가
> 한 칸 밀려 기록돼 있다(원격 `17_remove_points…`, `18_anon_guest_access`). **파일명 기준으로 읽을 것.**
> 로컬 파일은 00~18까지 19개, 이번에 5개 추가되어 24개다.

---

## 1. §7 항목별 반영 결과

| # | §7 항목 | 반영 위치 | 스펙 대비 |
|---|---------|-----------|-----------|
| 1 | `public.tier` enum | 19 | 그대로 (`badge_tier`와 별개 타입) |
| 2 | `profiles` 3컬럼 + 서버 가드 | 19 | 그대로 + `tier_season_id` 형식 CHECK 추가 |
| 3 | 시즌 경계 SQL 함수 | 20 | 그대로 + `season_next_id`/`season_previous_id` 추가(Dart와 1:1) |
| 4 | 시즌 거리 재계산 + 티어 판정 | 22 | 별도 `recompute_season_tier()` 신설 후 `runs_recompute_stats` 트리거에 배선 |
| 5 | 시즌 리셋(멱등) | 22 | cron 2건 + `sync_my_season()` RPC(읽기 경로) + 쓰기 경로 자동 |
| 6 | `season_histories` | 21 | 그대로 |
| 7 | 🔴 §8.3 결함 수정 | 23 | 그대로. `recompute_profile_stats()`는 **손대지 않음** |
| 8 | 리더보드 티어 차원 | 23 | 그대로 (`tier_key` 생성식만 CASE로 — §3 참조) |
| 9 | RK-02 조회 경로 | 검증만 | PostgREST 응답에 `tier`/`participant_count` 별칭 없이 실림 확인 |

---

## 2. 필드 매핑 (Dart camelCase ↔ Postgres snake_case)

`FieldRename.snake` 변환 결과와 컬럼명이 **정확히 일치**한다. 쿼리에서 `as` 별칭 금지(계약서 §1.1).

### `AppUser` ↔ `profiles` (신규 3필드)

| Dart 필드 | 컬럼 | 타입 | 기본값 | 쓰기 주체 |
|-----------|------|------|--------|-----------|
| `currentTier` | `current_tier` | `public.tier not null` | `'bronze'` | **서버 전용** |
| `seasonDistanceMeters` | `season_distance_meters` | `double precision not null` | `0` | **서버 전용** |
| `tierSeasonId` | `tier_season_id` | `text` nullable | `null` | **서버 전용** |

### `SeasonHistory` ↔ `season_histories` (신규 테이블)

| Dart 필드 | 컬럼 | 타입 |
|-----------|------|------|
| `id` | `id` | `uuid pk default gen_random_uuid()` |
| `userId` | `user_id` | `uuid not null` → `profiles(id)` on delete cascade |
| `seasonId` | `season_id` | `text not null` (`^\d{4}-Q[1-4]$`) |
| `finalTier` | `final_tier` | `public.tier not null` |
| `distanceMeters` | `distance_meters` | `double precision not null default 0` |
| `runCount` | `run_count` | `integer not null default 0` |
| `movingSeconds` | `moving_seconds` | `integer not null default 0` |
| `bestWeeklyRank` | `best_weekly_rank` | `integer` nullable |
| `closedAt` | `closed_at` | `timestamptz not null default now()` |
| `isVoided` | `is_voided` | `boolean not null default false` |
| — | — | `startAt`/`endAt`은 **컬럼 없음**. `seasonId`에서 파생되는 Dart getter |

### `RankingEntry` ↔ `leaderboard_entries` (신규 2필드 + 내부 1)

| Dart 필드 | 컬럼 | 타입 |
|-----------|------|------|
| `tier` | `tier` | `public.tier` **nullable** (null = 티어 미분할 통합 보드) |
| `participantCount` | `participant_count` | `integer` nullable |
| **(모델에 없음)** | `tier_key` | `text` 생성 컬럼. `ON CONFLICT` 추론용 내부 키 — `crew_key`와 동일 패턴. json_serializable이 미인식 키를 무시하므로 `fromJson`을 깨지 않는다 |

---

## 3. 판단이 필요했던 지점 (스펙에 없어 결정한 것)

### 3-1. `tier_key` 생성식을 `coalesce(tier::text, '_all')`로 쓸 수 없었다
§7-8은 `coalesce(tier::text,'_all')`을 명시했지만 Postgres가 거부한다:

```
ERROR: 42P17: generation expression is not immutable
```

enum의 출력 함수 `enum_out`이 **STABLE**이라 생성 컬럼 식에 못 쓴다(`crew_key`의 `coalesce(uuid, uuid)`는
캐스트가 없어 통과했던 것). enum = enum 비교 연산자는 IMMUTABLE이므로 CASE로 같은 결과를 만들었다:

```sql
tier_key text generated always as (
  case tier when 'bronze' then 'bronze' when 'silver' then 'silver'
            when 'gold' then 'gold' when 'platinum' then 'platinum'
            else '_all' end
) stored
```

**저장값·PK 의미는 스펙과 100% 동일하다** (tier가 NULL이면 모든 WHEN이 NULL → ELSE → `'_all'`).

### 3-2. 읽기 경로 지연 복구 = `sync_my_season()` RPC
"읽기 경로"는 PostgREST의 `profiles` SELECT라 트리거를 걸 지점이 없다. 대신 인자 없는
`security definer` RPC를 두고 `authenticated`에만 개방했다. `auth.uid()`로만 동작하고
입력을 일절 받지 않으며 계산 소스가 전부 서버 데이터이므로 신뢰 경계를 넘지 않는다.
이미 현재 시즌이면 UPDATE 없이 즉시 반환한다(멱등 + 저비용).

**클라이언트 팀 인계**: 프로필/홈 진입 시 `supabase.rpc('sync_my_season')`을 한 번 호출하면
분기 전환 직후에도 배치를 기다리지 않고 티어가 정상화된다. 반환값은 현재 `Tier`.

### 3-3. `season_histories`의 값 출처
- `final_tier` / `distance_meters` ← 마감 시점 `profiles.current_tier` / `season_distance_meters` **스냅샷**
  (둘을 함께 못 박아야 티어와 거리가 모순되지 않는다 — §5 "소급 변경 금지")
- `run_count` / `moving_seconds` ← 이전 시즌 구간을 `runs`에서 집계(같은 필터: completed + not flagged + 실외)
- `best_weekly_rank` ← 그 시즌 구간의 `leaderboard_entries` weekly/distance/global `min(rank)`

### 3-4. `season_histories` RLS의 `is_voided` 처리
§7-6은 "본인 + 공개 프로필 select"만 명시했다. `profiles`가 이미 전체 공개이므로 그대로면
`using (true)`가 된다. 다만 **무효화된 행은 본인에게만** 보이게 했다 —
남의 무효 기록을 노출할 이유가 없고, 본인은 이의 제기(§8.4)를 위해 봐야 한다.

```sql
using (is_voided = false or user_id = (select auth.uid()))
```

anon(게스트)에는 열지 않았다 — 17번 파일의 공개 범위(badges + global 랭킹) 유지.

### 3-5. cron 스케줄 = 2건
Supabase cron은 UTC다. 분기 첫날 00:05 KST = 직전 분기 마지막 날 15:05 UTC이고,
말일이 31일인 달(3·12월)과 30일인 달(6·9월)로 갈려 두 잡이 된다.

```
runnit-season-reset-31   5 15 31 3,12 *
runnit-season-reset-30   5 15 30 6,9  *
```

### 3-6. 기존 프로필 백필
22번 말미에 `select public.reset_stale_seasons();`를 넣었다. `tier_season_id`가 전부 NULL이라
마감(1단계)을 건너뛰고 현재 시즌 집계만 수행 → 유령 시즌 기록이 생기지 않는다.
원격의 기존 사용자 1명(`dev.tester`)이 `bronze / 0 / 2026-Q3`으로 정상 백필됐다.

---

## 4. 🔴 §8.3 결함 수정 — 재현 전/후 검증

문서 §6의 재현 절차를 원격 DB에서 그대로 실행했다.

### 준비
테스트 auth 사용자 `tiertestA` 생성 → 트레드밀 기록 1건(`indoor_run`, 5,000m, 이번 주 KST 안) 삽입.

### 수정 **전** (마이그레이션 23 적용 직전)
```sql
select public.refresh_leaderboard('weekly','distance','global');
select user_id, score, run_count, rank from public.leaderboard_entries
 where user_id='…' and period='weekly' and metric='distance' and scope='global';
```
```
score = 5000, run_count = 1, rank = 1      ← ❌ PRD §8.3 위반 (결함 재현 성공)
```

### 수정 **후** (마이그레이션 23 적용 후, 동일 쿼리)
```
rows_for_treadmill_only_user = 0           ← ✅ 기대대로 보드에 아예 나타나지 않음
```

### 함께 확인 — `recompute_profile_stats()`는 손대지 않았다
같은 사용자의 프로필:
```
total_distance_meters  = 5000   ← 누적 통계에는 트레드밀 반영 (§8.3 "✅ 반영")
season_distance_meters = 0      ← 티어 거리에는 미반영     (§8.3 "❌ 미반영")
```
**PRD가 의도한 비대칭이 그대로 성립한다.**

---

## 5. 시즌 경계 함수 ↔ Dart 대조 결과

`test/models/tier_season_test.dart`의 경계 케이스를 SQL로 직접 select해 대조했다. **17건 전부 일치.**

| 케이스 | SQL 결과 | Dart 기대 | |
|--------|----------|-----------|---|
| `season_id_at('2026-06-30T15:00Z')` | `2026-Q3` | `2026-Q3` | ✅ |
| `season_id_at('2026-06-30T14:59Z')` | `2026-Q2` | `2026-Q2` | ✅ |
| `season_id_at('2026-08-21T00:00Z')` | `2026-Q3` | `2026-Q3` | ✅ |
| `season_id_at('2026-09-30T14:30Z')` (경계 걸침 러닝) | `2026-Q3` | `2026-Q3` | ✅ |
| `season_start('2026-Q3')` | `2026-06-30 15:00:00+00` | `2026-06-30T15:00Z` | ✅ |
| `season_end('2026-Q3')` | `2026-09-30 15:00:00+00` | `2026-09-30T15:00Z` | ✅ |
| `season_end('2026-Q3') = season_start('2026-Q4')` | 일치 | 일치 | ✅ |
| `season_next_id('2026-Q4')` | `2027-Q1` | `2027-Q1` | ✅ |
| `season_previous_id('2027-Q1')` | `2026-Q4` | `2026-Q4` | ✅ |
| `season_start('2027-Q1')` | `2026-12-31 15:00:00+00` | `2026-12-31T15:00Z` | ✅ |
| `season_start('2026-Q5')` | `ERROR 22000 잘못된 seasonId 형식` | `FormatException` | ✅ |
| 티어 기준선 0 / 24999 / 25000 / 99999 / 100000 / 250000 / 999999 | bronze/bronze/silver/silver/gold/platinum/platinum | 동일 | ✅ (7건) |

### 주간 경계도 대조 (RK-01, 기존 `leaderboard_period_bounds`)
| 케이스 | SQL | Dart `RankingWeek` | |
|---|---|---|---|
| 금 `2026-08-21T03:00Z` → 주 시작 | `2026-08-16 15:00+00` | `2026-08-16T15:00Z` | ✅ |
| 같은 케이스 → 주 종료 | `2026-08-23 15:00+00` | `2026-08-23T15:00Z` | ✅ |
| 일 `2026-08-23T14:59Z` (아직 같은 주) | `2026-08-16 15:00+00` | 동일 | ✅ |
| 월 `2026-08-23T15:00Z` (새 주) | `2026-08-23 15:00+00` | 동일 | ✅ |

---

## 6. 티어 승급 시나리오 검증 (TI-03 / RK-02 / RK-04 / RK-08 / §8.6)

`tiertestB` 사용자로 실행.

### (1) 24km → 브론즈
```
current_tier=bronze  season_distance_meters=24000  tier_season_id=2026-Q3
```
`refresh_all_leaderboards()` 후:
```
tier_key=_all     rank=1 score=24000 participant_count=1
tier_key=bronze   rank=1 score=24000 participant_count=1
```

### (2) +2km (26km) → **즉시 실버 승급** (TI-03: 배치 대기 없음)
러닝 INSERT 직후 프로필을 그대로 읽었다:
```
current_tier=silver  season_distance_meters=26000
```
`runs_recompute_stats` 트리거 경로에 태웠으므로 **기록 저장과 같은 트랜잭션에서 판정**된다.

### (3) RK-08 — 부분 갱신은 유령 행을 남긴다 (금지 근거 실증)
승급 후 **silver 조합만** 갱신:
```
tier_key=_all     rank=1 score=24000   ← 갱신 안 됨
tier_key=bronze   rank=1 score=24000   ← ❌ 유령 행 (승급 전 티어에 잔존)
tier_key=silver   rank=1 score=26000
```

### (4) `refresh_all_leaderboards()` (4티어 항상 함께) → 정리됨
```
tier_key=_all     rank=1 score=26000 run_count=2 participant_count=1
tier_key=silver   rank=1 score=26000 run_count=2 participant_count=1
(bronze 행 없음)
```
**§8.6 "주간 누적 거리 그대로 이관"이 별도 로직 없이 성립한다** — 점수 원천이 주간 합계이므로
새 티어 보드에 26,000m가 그대로 다시 계산된다.

### (5) 티어 내 순위 + `participant_count` (RK-02 / RK-04)
브론즈 2명(5km, 3km) + 실버 1명(26km) 상태에서:
```
_all    tiertestB rank=1 score=26000 participant_count=3
_all    tiertestD rank=2 score=5000  participant_count=3
_all    tiertestE rank=3 score=3000  participant_count=3
bronze  tiertestD rank=1 score=5000  participant_count=2   ← 모집단을 자른 뒤 그 안에서 순위
bronze  tiertestE rank=2 score=3000  participant_count=2
silver  tiertestB rank=1 score=26000 participant_count=1
```
트레드밀만 있는 `tiertestA`는 **어느 보드에도 없다**.

### (6) 시즌 리셋 · 마감 멱등성
`tiertestC`를 "2026-Q2 실버 / 30,000m" 상태로 만들고 리셋을 **3회** 실행
(`reset_stale_seasons()` ×2 + `recompute_season_tier()` ×1):
```
profiles:          current_tier=bronze  season_distance_meters=0  tier_season_id=2026-Q3
                   total_distance_meters=30000   ← 누적은 보존 (§8.3)
season_histories:  1행 (중복 없음)
  season_id=2026-Q2  final_tier=silver  distance_meters=30000
  run_count=1  moving_seconds=6000  best_weekly_rank=null  is_voided=false
```
`UNIQUE(user_id, season_id)` + `ON CONFLICT DO NOTHING`으로 **중복 마감 불가**.

### (7) 서버 전용 컬럼 가드 (§7-2)
`authenticated` 롤로 티어 3종을 직접 UPDATE 시도:
```sql
update public.profiles set current_tier='platinum', season_distance_meters=999999,
       tier_season_id='2099-Q1', bio='client edit' where id='…';
```
결과: `silver / 26000 / 2026-Q3` (전부 서버 값으로 되돌아감), `bio`만 반영.
05번 파일의 "예외가 아니라 조용한 덮어쓰기" 원칙 유지 — 정상적인 프로필 수정은 실패하지 않는다.

### (8) `season_histories` 클라이언트 write 차단
```
ERROR 42501: new row violates row-level security policy for table "season_histories"
```
anon도 전면 차단 (`permission denied for table season_histories`).

---

## 7. RK-02 조회 경로 검증 (별칭 금지 확인)

실제 PostgREST 응답 (anon 키, `?tier=eq.silver`):

```json
{
  "user_id": "…", "username": "tiertestB", "rank": 1, "metric": "distance",
  "score": 26000, "period": "weekly", "scope": "global",
  "period_start": "2026-08-16T15:00:00+00:00", "period_end": "2026-08-23T15:00:00+00:00",
  "run_count": 2, "total_moving_seconds": 5400,
  "crew_key": "00000000-…", "tier": "silver", "participant_count": 1, "tier_key": "silver"
}
```

- `.eq('tier', TierWire.wire)` 필터가 그대로 동작한다.
- `tier` / `participant_count`가 **별칭 없이** 실린다 → `RankingEntry.fromJson`이 채운다.
- `crew_key` / `tier_key`는 모델에 없는 내부 키지만 json_serializable이 무시한다.

---

## 8. `get_advisors` 결과

### security — **RLS 누락 0건**
| 항목 | 판단 |
|------|------|
| `public.sync_my_season()` — authenticated 실행 가능 (WARN) | **의도된 것.** 인자 없음 + `auth.uid()`로만 동작하는 본인 전용 지연 복구 RPC |
| `public.rls_auto_enable()` — anon/authenticated 실행 가능 (WARN) | **이번 작업과 무관한 기존 항목.** 저장소 마이그레이션 어디에도 없다(플랫폼 생성 추정). 별도 확인 필요 — 아래 §9 |
| `auth_leaked_password_protection` 비활성 (WARN) | 기존 항목. Auth 설정 영역 |

`season_histories`는 RLS 활성 + select 정책 1개, write 정책 없음 — 경고 없음.

### performance — INFO(unused index) 8건뿐
전부 "아직 사용된 적 없음" 통지다. 검증 데이터를 지운 빈 DB이므로 정상.
새로 만든 `leaderboard_entries_read_idx`(티어 차원 포함)와
`season_histories_user_season_desc_idx`도 여기 해당한다.

---

## 9. 후속 팀 인계

| 담당 | 내용 |
|------|------|
| **mobile-architect / flutter-ui-designer** | 프로필·홈 진입 시 `supabase.rpc('sync_my_season')` 1회 호출 권장(§3-2). 반환 `Tier`. 미호출이어도 러닝 업로드 시 자동 복구되지만, 분기 전환 후 첫 조회에서 이전 시즌 값이 보일 수 있다 |
| **qa-integration-tester** | `profiles` 3필드 / `leaderboard_entries` 2필드(+ `tier_key` 내부) / `season_histories` 전체의 모델↔스키마 대조. 실제 응답 shape은 §7에 있음 |
| **gamification-designer** | §8.2 주간 동점 처리 PRD 불일치는 **이번에도 손대지 않았다**(범위 밖). 현행: distance 지표 `sum(moving_seconds)` 오름차순 단일 기준 |
| **리더 확인 요망** | `public.rls_auto_enable()`이 anon에게 실행 가능한 상태다. 저장소 마이그레이션에 없어 출처가 불명확하다 — 이번 작업으로 생긴 것은 아니지만 별도 점검이 필요하다 |

### 알려진 지연 (설계상 수용)
TI-03의 **티어 판정**은 기록 저장 즉시 일어나지만, **티어 리더보드 행**은 `runnit-leaderboard`
cron(5분 주기)에서 움직인다. 승급 직후 5분 이내에는 랭킹 화면이 이전 티어 보드를 보여줄 수 있다.
기존 리더보드 배치 전략(03번 파일)과 동일한 성질이며, UI에 `computed_at` 기준 "N분 전" 표기를
함께 노출하는 것으로 다룬다.

---

## 10. 검증 데이터 정리

`runs` / `leaderboard_entries` / `season_histories` 전량 삭제, 테스트 auth 사용자 4명
(`tiertest.*@runnit.test`) 삭제 — 프로필은 cascade로 함께 제거.

```
auth_users=1  profiles=1  runs=0  season_histories=0  leaderboard_entries=0
user_badges=0 challenge_participations=0  badges_seed=29
```

남은 1명은 이전 세션의 `dev.tester@runnit.test`(2026-08-20 생성)로 **이번 작업 데이터가 아니다.**
마이그레이션 22의 백필로 `bronze / 0 / 2026-Q3`이 정상 부여됐다.
`badges` 29건은 09번 시드 마스터 데이터 — 유지가 정상.
