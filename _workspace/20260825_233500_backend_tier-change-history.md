# tier_change_history 추가 + season_max_tier_reached_before_pct 실제 판정

작성: backend-engineer / 2026-08-25
대상 프로젝트: Supabase `xwtbwexcofcgmbvktwdo`
작업 위치: 공유 체크아웃 `/Users/jehyun/Runnit/.claude/worktrees/phase-0-start-0f9ff3`(격리 worktree
아님 — `lib/`·`pubspec.yaml` 등이 이 체크아웃에만 untracked로 존재하기 때문. 최초 실수로 main
체크아웃 `/Users/jehyun/Runnit/supabase/migrations/`에 파일을 하나 잘못 썼다가, 삭제 권한이 막혀
`rm` 대신 그 파일 내용을 "잘못 만든 파일" 안내문으로 덮어썼다 — 실제 마이그레이션은 전부 이
worktree 체크아웃에 있다.)

기준 문서: `_workspace/20260825_220000_backend_season-badge-instantiation.md` §3(스텁 사유) ·
`_workspace/20260825_193000_backend_badge-evaluation-logic.md`

---

## 1. 적용한 마이그레이션

| 파일 | 이름 | 상태 |
|---|---|---|
| `supabase/migrations/20260825230000_33_tier_change_history.sql` | `33_tier_change_history` | ✅ 적용 (이후 34번으로 정정) |
| `supabase/migrations/20260825233000_34_tier_change_history_rising_only.sql` | `34_tier_change_history_rising_only` | ✅ 적용 |

**33번을 그대로 두지 않고 34번으로 정정한 이유**: 33번은 "매 recompute 호출마다 무조건
INSERT 시도 + UNIQUE + ON CONFLICT DO NOTHING"으로 중복만 막았다. 이 방식대로 마이그레이션
말미에 기존 유저 전원에 대해 `recompute_season_tier`를 강제 호출하는 백필 단계를 넣었더니,
이미 플래티넘인 기존 유저(a8 등)에게 "지금(마이그레이션 적용 시각)"을 근사 도달 시각으로
1행씩 만들어 넣는 부작용이 생겼다. 작업 도중 오케스트레이터가 사용자의 추가 지시를 전달했다 —
"티어가 **상승**할 때만 기록해야 하고, 소급 복원은 하지 말고 안 되면 안 된다고 솔직히
적으라"는 것. 33번의 "무조건 시도 + 중복 방지"는 이 요구와 미묘하게 다르다(백필처럼 "이미
그 티어인 상태의 재확인"도 통과시켜 버린다). 그래서 34번에서 (1) 33-5 백필로 생성된 근사
행을 전부 삭제하고 (2) `recompute_season_tier`의 이력 삽입을 `v_new_tier > v_prev_tier`
(엄격한 상승) 가드 안으로 옮겼다. 최종 결과물은 34번 적용 후 상태다 — 아래 설명은 전부
34번 기준.

---

## 2. 티어가 실제로 갱신되는 지점 (재확인)

`public.recompute_season_tier(p_user_id, p_at)`(마이그레이션 22, `20260821150300_22_season_tier_recompute.sql`)
가 `profiles.current_tier`를 쓰는 유일한 함수다. 진입점은 3곳(전부 이 함수를 호출):
- `trg_runs_recompute_stats()` — 러닝 저장/삭제 시 트리거
- `sync_my_season()` — 홈 화면 진입 시 읽기 경로 RPC
- `reset_stale_seasons()` — 분기 첫날 00:05 KST cron

이 함수는 매번 **현재 시즌 누적 거리를 전체 재계산**하고 `tier_for_distance()`로 티어를
다시 판정한다(델타 갱신 아님). 이 재계산 직후, 새 34-2 로직이 "직전 값보다 실제로
올랐는가"를 확인해 이력을 남긴다.

`public.season_histories`(마이그레이션 21)는 시즌 **마감** 시점의 `final_tier` 스냅샷만
가진다 — 시즌 중 언제 그 티어에 도달했는지는 기록하지 않는다. 이 사실이 바로
`season_max_tier_reached_before_pct`가 32번에서 스텁으로 남았던 이유였다.

---

## 3. `public.tier_change_history` 테이블

```sql
create table public.tier_change_history (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid        not null references public.profiles (id) on delete cascade,
  season_id  text        not null,
  tier       public.tier not null,
  reached_at timestamptz not null default now(),

  constraint tier_change_history_season_id_format check (season_id ~ '^\d{4}-Q[1-4]$'),
  constraint tier_change_history_user_season_tier_uniq unique (user_id, season_id, tier)
);
create index tier_change_history_user_season_idx on public.tier_change_history (user_id, season_id);
```

- **append-only, "상승" 이력만.** `recompute_season_tier` 안에서 `v_new_tier > v_prev_tier`
  (public.tier enum의 선언 순서 bronze<silver<gold<platinum 비교, 하드코딩 없음)일 때만
  `insert ... on conflict (user_id, season_id, tier) do nothing`을 실행한다. 매 recompute
  호출마다(같은 티어 유지, 강등, 시즌 경계를 넘어 낮은 값으로 재시작) 아무 일도 하지
  않는다 — "실제로 바뀔 때만" 요구사항을 함수 로직 자체(조건문)로 보장하며, UNIQUE +
  ON CONFLICT는 동시 호출 레이스에 대한 안전망으로만 남겨뒀다.
- **RLS**: `enable row level security` + 본인 행만 `select`(`auth.uid() = user_id`).
  insert/update/delete 정책 없음 = 클라이언트 write 전면 금지, 유일한 쓰기 경로는
  `recompute_season_tier`(SECURITY DEFINER, anon/authenticated EXECUTE 회수).
  `season_histories`(전체 공개)와 달리 본인만 조회 가능하게 좁혔다 — "언제 그 티어에
  도달했는가"라는 세부 타임스탬프를 굳이 공개할 이유가 없다고 판단했다(필요해지면 완화
  가능).

---

## 4. `evaluate_badge_condition` — `season_max_tier_reached_before_pct` 실제 판정

```sql
when 'season_max_tier_reached_before_pct' then
  v_pct := (p_condition ->> 'pct')::double precision;

  select t into v_top_tier
  from unnest(enum_range(null::public.tier)) as t
  order by t desc
  limit 1;                                   -- "최고 티어" 하드코딩 금지

  select tch.reached_at into v_reached_at
  from public.tier_change_history tch
  where tch.user_id = p_user_id and tch.season_id = v_season and tch.tier = v_top_tier;

  if v_reached_at is null or v_pct is null then
    return false;
  end if;

  v_cutoff := v_season_start + (v_season_end - v_season_start) * (v_pct / 100.0);
  return v_reached_at < v_cutoff;
```

`condition->>'pct'`를 그대로 쓰고, "최고 티어"는 `enum_range(null::public.tier)`에서
정렬해 마지막 값을 구한다 — `public.tier` enum에 티어가 추가/변경돼도 이 코드는 수정할
필요가 없다. 나머지 43개 case는 32번 그대로(문자 그대로) 복사 유지했다 — 로직 변경 없음.

---

## 5. 기존 유저 소급 처리 — 결론: 불가능, 백필하지 않음

- **역산 근거가 없다.** `season_histories`는 시즌 마감 시점의 `final_tier` 스냅샷만
  가진다 — "언제 그 티어에 도달했는가"는 애초에 저장 대상이 아니었어서 역산할 원본
  데이터 자체가 없다. 억지로 만들지 않았다.
- 33번에서 한 번은 "지금(마이그레이션 적용 시각)"을 근사치로 기존 유저 전원에게
  1행씩 채워 넣는 백필을 시도했으나(오지급 방향으로는 틀리지 않는 근사 — 사용자가
  실제보다 항상 늦은 시각으로만 기록되므로 false negative만 유발), 사용자가 명시적으로
  "안 되면 안 된다고 솔직히 적어라 / 소급 복원은 하지 말라"고 확인해 34번에서 이 백필을
  완전히 되돌렸다(`delete from public.tier_change_history` 후 로직을 "상승만 기록"으로
  변경).
- **결과**: 2026-08-25(마이그레이션 33/34 적용) 이전에 이미 어떤 티어에 도달해 있던
  기존 유저는 이 테이블에 행이 전혀 없다. 이번 시즌(`2026-Q3`) 동안 강등(기록
  삭제/플래그) 없이 다시 "상승"할 기회가 없는 한, 이미 플래티넘인 기존 유저는
  `sevent_tier_early`를 이번 시즌엔 받을 수 없다 — 오지급 방향 오류는 절대 없고,
  정직하게 "정확한 시각을 모르면 주지 않는다"는 원칙을 지켰다.
- **이 테이블 생성 이후 새로 티어에 도달하는 경우부터는 완전히 정상 동작한다**
  (다음 시즌 시작, 또는 강등 후 재상승 포함).

---

## 6. 검증

### 6.1 실제 트리거 발동 — 상승 시 정확히 1행, 반복 호출 시 중복 없음

테스트용 신규 유저(`auth.users` 직접 insert → `handle_new_auth_user` 트리거로 profile
자동 생성, 테스트 후 `delete from auth.users`로 cascade 정리 완료 — 시드 데이터 원본은
전혀 건드리지 않았다):

1. 30km 러닝 insert → `trg_runs_recompute_stats` 트리거 발동 →
   `current_tier: bronze→silver`, `tier_change_history`에 `(silver, 2026-08-25 14:07:02)` **정확히 1행**.
2. 추가로 3km 러닝 insert(여전히 silver 구간) → 행 수 그대로 1건.
3. `select recompute_season_tier(...)` 수동 재호출(같은 티어) → 행 수 여전히 1건 —
   **반복 갱신이 이력을 늘리지 않음을 확인**.
4. 110km 러닝 2건(정상 페이스로 조정 — 처음 시도한 24시간 220km 단일 세션은
   `validate_run`의 `implausible_distance`(>200km 단일 세션) 규칙에 걸려
   `is_flagged=true`가 됐고, 플래그된 기록은 `season_distance_meters` 집계에서 자동
   제외되어 티어에 반영되지 않았다 — 서버 재검증이 의도대로 작동함을 재확인한 셈이라
   테스트 시나리오를 200km 이하 2건으로 나눠 재시도) insert → 누적 253,000m,
   `current_tier: silver→platinum`. **주의**: 두 러닝을 하나의 다중 행 INSERT 문으로
   한 번에 넣었더니 두 트리거 실행 시점에 이미 두 행이 모두 테이블에 존재해(단일 INSERT
   문 내에서 AFTER ROW 트리거는 모든 행이 삽입된 뒤 발화) 매 recompute가 합계 253,000m를
   그대로 관측했다 — 그 결과 실제로는 "silver→gold→platinum" 순으로 올라야 할 것이
   "silver→platinum"으로 gold를 건너뛴 이력이 남았다. 이는 버그가 아니라 설계상 당연한
   결과다(전체 재계산 방식이라, 한 recompute 호출이 관측하는 티어는 그 시점의 최종
   상태뿐이며 중간값은 애초에 "도달"한 적이 없다). 실제 앱에서는 러닝을 한 건씩
   업로드하므로 이런 스킵은 발생하지 않는다.

### 6.2 `season_max_tier_reached_before_pct` — true/false 양쪽

같은 테스트 유저(`tier_change_history`에 `platinum, reached_at≈2026-08-25 14:08`,
2026-Q3 시즌 50% 지점은 `2026-08-15 15:00 UTC`):

```sql
select evaluate_badge_condition(uid, 'season_max_tier_reached_before_pct', '{"pct":50}');
-- false (실제 도달 시각이 8/25 → 50% 지점 8/15보다 늦음)

update tier_change_history set reached_at = '2026-08-01 00:00:00+00' where tier='platinum' and user_id=uid;
select evaluate_badge_condition(uid, 'season_max_tier_reached_before_pct', '{"pct":50}');
-- true (8/1 < 8/15)
```

두 값 모두 기대와 일치. `evaluate_badges(uid)`를 실행해 `sevent_tier_early@2026-Q3`가
`verified=true, revoked=false`로 실제 지급되는 것도 엔드투엔드로 확인했다.

### 6.3 `get_advisors(security)`

신규 경고 **0건**. 기존 4건(비관련, 사전부터 존재) 그대로:
`rls_auto_enable`/`sync_my_season` anon/authenticated 실행 가능 경고 2건, Auth
leaked-password protection 비활성 1건 — 이번 변경으로 늘어난 것 없음.
`recompute_season_tier`/`evaluate_badge_condition` 모두 SECURITY DEFINER이며
public/anon/authenticated로부터 EXECUTE 회수 유지.

### 6.4 시드 데이터 무결성

테스트에 사용한 유저는 신규 생성한 임시 `auth.users` 행(`tier-test-f1@example.com`)이며
작업 종료 시 `delete from auth.users`로 cascade 삭제 완료. 기존 시드 프로필(a1~a8,
6c27..., 4286...)의 `tier_change_history`는 34번 적용 시점에 전부 0건(백필 취소)이고
현재도 0건 — 의도한 상태.

---

## 7. `docs/TRD.md` 갱신

§3.6 앞 갱신 경고 블록(32번 작업 때 추가된 것)을 확장했다 — seasonal 19종이 이제 전부
실제 판정된다는 점, `tier_change_history` 테이블 도입 배경·상승 전용 기록 규칙·"최고
티어" 하드코딩 회피 방식·소급 불가 사실을 명시했다.

---

## 8. 다음 라운드로 넘기는 것

- 이전 보고서(`_workspace/20260825_193000_backend_badge-evaluation-logic.md` §8)의 항목
  1~6은 이번 작업 범위 밖으로 그대로 유효.
- `tier_change_history` 자체는 완결됐고 추가 작업 불필요. 다만 향후 "역대 티어 상승
  타임라인" 같은 프로필 UI 기능이 생기면 이 테이블을 그대로 재사용할 수 있다(현재는
  select 정책이 본인만 허용 — 필요 시 완화 검토).

## 파일 목록

- `supabase/migrations/20260825230000_33_tier_change_history.sql`
- `supabase/migrations/20260825233000_34_tier_change_history_rising_only.sql`
- `docs/TRD.md` (§3.6 앞 갱신 경고 블록 확장)
- `_workspace/20260825_233500_backend_tier-change-history.md` (본 보고서)
