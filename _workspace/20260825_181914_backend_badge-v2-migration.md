# 뱃지 시스템 v2 마이그레이션 — 적용 완료 보고

작성: backend-engineer / 2026-08-25
대상 프로젝트: Supabase `xwtbwexcofcgmbvktwdo`
기준 문서: `docs/PRD.md` §5.5(GM-01~09)·§8.1·§8.4 · `docs/TRD.md` §3.6/§4.1/§5 ·
`docs/badge-catalog.csv`(158행 정본) · `_workspace/20260825_architect_badge-model-v2.md`

---

## 1. 적용한 마이그레이션

| 로컬 파일 | 원격 version | 원격 name | 상태 |
|---|---|---|---|
| `supabase/migrations/20260825120000_25_badge_catalog_v2_schema.sql` | `20260825091038` | `25_badge_catalog_v2_schema` | ✅ 적용 |
| `supabase/migrations/20260825120100_26_badge_catalog_v2_seed.sql` | `20260825091438` | `26_badge_catalog_v2_seed` | ✅ 적용 |

> 로컬 파일명 타임스탬프와 원격 version이 다른 것은 **이 저장소의 기존 관례**다
> (00~24도 전부 다르다 — 로컬은 파일 순서용, 원격은 apply 시각). 맞추지 않았다.

### 25번이 한 일

1. **선행 정리** — v1 컬럼을 참조하던 plpgsql 함수 3종을 먼저 교체했다.
   `evaluate_badges`(스텁화) / `recompute_profile_stats`(뱃지 포인트 합산 제거) /
   `recompute_challenge_progress`(뱃지 포인트 가산 제거, 보상 뱃지는 `verified=true`).
   ⚠️ plpgsql 본문은 컬럼 의존성을 추적하지 않는다 — 이 단계를 건너뛰면 `DROP COLUMN`이
   성공해도 런타임에 42703으로 터진다.
2. **`badges` 재구성** — `tier`/`icon_asset`/`criteria_type`/`threshold`/`points`/
   `sort_order`/`is_secret`/`is_active` 삭제.
   `category`를 enum(7종) → **text + CHECK(16종)**, `scope`/`trigger_type`/`condition_type`
   (CHECK 44종)/`condition`(jsonb)/`badge_grade`(CHECK 6종)/`season_id` 추가.
3. **`user_badges`** — `verified`, `revoked` 추가(둘 다 `not null default false`).
   `source_run_id`는 **유지**했다(아래 §6 판단 근거).
4. **가드 트리거 갱신** — 클라이언트 UPDATE 경로에서 `verified`/`revoked`를 되돌린다.
5. **RLS 재설정** (§4).
6. **판정 스텁 2종** — `evaluate_badges`, `evaluate_badge_condition` (§5).

### 26번이 한 일

`docs/badge-catalog.csv` 158행을 `badges`에 시드. `on conflict (id) do update`로 멱등하며,
말미에 `count(*) <> 158`이면 `raise exception`하는 총계 단언을 넣었다 —
CSV에서 삭제된 뱃지가 DB에 남는 조용한 드리프트를 막는다.

---

## 2. 삭제된 기존 데이터

| 테이블 | 건수 | 비고 |
|---|---|---|
| `badges` | **29건** | v1 카탈로그(`criteria_type`/`threshold` 기반) |
| `user_badges` | **53건** | 위 29종에 대한 획득 기록 |
| `challenges.reward_badge_id` 참조 | **0건** | 영향 없음 |

v1 뱃지는 판정 축 자체가 달라(`criteria_type` 12종 스칼라 → `condition_type` 44종 + jsonb)
v2 카탈로그로 매핑할 대응 관계가 없다. 프로덕션 사용자가 없는 개발 단계라 전량 폐기했다.

---

## 3. 시드 검증 결과 — **158/158 정확 일치**

CSV를 원천으로 기대값을 만들어 DB와 기계적으로 대조했다. 눈으로 훑은 게 아니다.

| 검증 항목 | 결과 |
|---|---|
| 총 행 수 | **158** ✅ |
| id 집합 (CSV full outer join DB) | **차집합 0건** ✅ |
| 텍스트 9개 컬럼 md5 (`id`,`name`,`description`,`category`,`scope`,`trigger_type`,`condition_type`,`badge_grade`,`season_id`) | `90cfc07b2776bd6180dfa23cba8e2496` — **CSV 계산값과 동일** ✅ |
| `condition` jsonb 158건 전수 비교 | **불일치 0건** ✅ |
| distinct `condition_type` | **44** ✅ |
| distinct `category` | **16** ✅ |
| `season_id is not null` | 0 (전부 템플릿) ✅ |

### 분포 — architect 문서 §1 통계와 전부 일치

| 축 | 값 | 기대 | |
|---|---|---|---|
| scope | permanent **117** / seasonal **41** | 117 / 41 | ✅ |
| grade | bronze **31** / silver **27** / gold **27** / platinum **19** / diamond **6** / special **48** | 동일 | ✅ |
| trigger | cumulative **97** / session **61** | 97 / 61 | ✅ |

### `functional_name` 열 — 시드하지 않음 (재확인 완료)

`lib/`·`test/`·`docs/`·`supabase/` 전체 grep 결과 **참조 0건**.
내용도 `"누적거리 5km 달성"` 형태로 `description`의 부분집합이고 Dart `Badge` 모델에
대응 필드가 없다. 버려도 잃는 정보가 없다. (TRD §4.1에 이 결정을 명시해 두었다.)

---

## 4. RLS 정책 최종본

### `badges`

```sql
create policy badges_select_all on public.badges for select
  to anon, authenticated using (true);

revoke insert, update, delete, truncate on public.badges from anon, authenticated;
grant select on public.badges to anon, authenticated;
```

쓰기 정책을 **두지 않는 것**으로 service_role 전용을 표현한다(BYPASSRLS).
권한까지 회수해 오류가 RLS 필터가 아니라 권한 거부로 더 이르게 나게 했다.
v1의 `badges_select_all`(authenticated) + `badges_select_anon`(anon) 2개 정책을
1개로 합쳤다 — 게스트도 카탈로그를 봐야 한다(마이그레이션 17 정책 승계).

### `user_badges`

```sql
create policy user_badges_select_own on public.user_badges for select
  to authenticated using (user_id = (select auth.uid()));

create policy user_badges_select_public on public.user_badges for select
  to authenticated using (
    user_id <> (select auth.uid())
    and revoked = false
    and verified = true
  );

revoke insert, delete, truncate on public.user_badges from anon, authenticated;
-- UPDATE: 기존 user_badges_update_seen 유지. 컬럼 제한은 trg_user_badges_guard 가 강제.
```

- 본인은 **미검증·회수분 포함 전량**을 본다(자기 상태는 자기가 알아야 한다).
- 타인은 `verified=true and revoked=false`만 (PRD §8.1/§8.4).
- INSERT 정책 **없음** → 클라이언트는 뱃지를 확정할 수 없다.
- 부분 인덱스 `user_badges_public_idx (user_id, earned_at desc) where revoked=false and verified=true`
  가 타인 조회 RLS 술어와 정확히 같은 조건이라 그대로 쓰인다.

### 실제 RLS 동작 검증 (역할 전환 + JWT 클레임 주입으로 실측)

테스트 뱃지 3건(검증완료 / 미검증 / 회수됨)을 심고 확인 후 정리했다.

| 시나리오 | 결과 |
|---|---|
| 본인 조회 (`badges` 임베드 조인 포함) | **3행** (기대 3) ✅ |
| 타인 조회 | **1행** — verified & not revoked만 ✅ |
| 클라이언트 INSERT | **차단됨** (`permission denied for table user_badges`) ✅ |
| anon 카탈로그 조회 | **158행** ✅ |
| 정리 후 잔여 | 0건 ✅ |

---

## 5. 판정 함수 — 스텁만 배치 (구현은 후속 라운드)

```sql
public.evaluate_badge_condition(p_user_id uuid, p_condition_type text, p_condition jsonb default '{}')
  returns boolean   -- 44종 전부 미구현. raise notice 후 항상 false.

public.evaluate_badges(p_user_id uuid, p_source_run_id uuid default null)
  returns integer   -- 항상 0. 시그니처 유지로 runs 트리거/챌린지 경로가 계속 컴파일된다.
```

⚠️ **미구현은 반드시 `false`를 반환해야 한다.** `true`로 두면 시드 직후 158종이
전원에게 지급된다. 두 함수 모두 `public, anon, authenticated`에서 EXECUTE를 회수했다.

`evaluate_badges` 스텁화로 **뱃지 자동 지급이 현재 완전히 멈춰 있다.** 의도된 상태다 —
v1 판정 로직은 삭제된 컬럼에 의존하므로 남겨둘 수 없었다. 후속 라운드에서
`evaluate_badge_condition` 디스패치로 복구한다.

---

## 6. 판단이 필요했던 지점과 그 근거

### 6.1 `source_run_id`를 **남겼다**

지시서는 삭제/유지를 내 판단에 맡겼다. **유지**를 택한 이유:
이번에 `revoked`(PRD §8.1 부정 기록 회수)를 추가했는데, 회수를 판정하려면
"이 뱃지가 **어느 러닝 때문에** 지급됐는가"를 알아야 한다. 그 링크가 없으면
특정 러닝이 부정으로 판명됐을 때 어떤 뱃지를 회수할지 역추적할 수 없다.
클라이언트 `UserBadge`에 대응 필드가 없지만 `json_serializable`이 미지 키를 무시하므로
`select *`로 내려가도 무해하다. 컬럼 코멘트에 "서버 전용 감사 컬럼"임을 명시했다.

### 6.2 seasonal 41종 — `season_id = null` 템플릿으로 시드

**클라이언트 규약 (문서화 필요 — flutter-ui-designer / mobile-architect 확인 요망):**

> `scope = 'seasonal' AND season_id IS NULL` 인 행은 **"다가올 시즌 뱃지"** 다.
> 획득 불가 상태이며 **진행률 바를 그리지 않는다.** 카탈로그에는 노출하되
> "시즌 시작 시 활성화" 류의 안내를 붙인다.

**현재 클라이언트 동작을 코드로 확인했다** (`badge_progress.dart`):

`forCatalog`의 제외 조건은 `scope == seasonal && seasonId != null && seasonId != currentSeasonId`다.
`seasonId != null`을 요구하므로 **우리가 시드한 41종(season_id = null)은 걸러지지 않고
갤러리에 그대로 노출된다.**

다만 실질 피해는 작다 — 41종의 `condition_type`은 전부 SERVER/partial 분류라
`currentValueFor`가 null을 반환하고, 따라서 **진행률 바는 그려지지 않는다**(조건 텍스트만 표시).
즉 기능 버그가 아니라 **UX 라벨링 문제**다: 사용자에게는 "아직 못 딴 일반 뱃지"처럼 보이는데
실제로는 "시즌이 시작돼야 딸 수 있는 뱃지"다.

**권고(P2, 이번 범위 밖):** `BadgeProgress`에 "다가올 시즌" 상태를 하나 추가하거나,
갤러리에서 `scope == seasonal && seasonId == null`을 별도 섹션으로 묶는다.
§7.3의 시즌 인스턴스 발급 잡이 들어가면 자연히 해소되는 문제이기도 하다.
→ mobile-architect / flutter-ui-designer 확인 요망.

### 6.3 `category`를 enum이 아니라 text + CHECK로

v1은 `badge_category` enum(7종)이었다. 16종으로 늘리면서 **text + CHECK**로 바꿨다 —
카탈로그 운영 중 카테고리가 늘어날 수 있는데 enum 값 추가는 트랜잭션 제약이 있고
롤백이 어렵다. CHECK는 단순 재정의로 끝난다. `condition_type`(44종)도 같은 이유로 text다.

### 6.4 `condition`에 표현식 인덱스를 만들지 않음

architect 문서 §6-3이 `(condition->>'distanceKm')` 인덱스를 검토하라고 했으나 **보류**했다.
카탈로그는 158행이고 판정은 "사용자 1명 × 뱃지 전량" 루프라 어차피 전체 스캔이 더 싸다.
행이 수천으로 늘고 특정 키 조회가 병목으로 확인되면 그때 만든다.
대신 판정 배치가 대상을 좁히는 경로로 `badges_trigger_scope_idx (trigger_type, scope)`를 뒀다.

---

## 7. 미해결 사항

### 7.1 backend 담당 — `district_diversity_gte` 역지오코딩 소스 (architect §7-5)

**여전히 미정이다.** 영향 뱃지 2종(`route_district_3` 브론즈, `route_district_10` 골드).

조사해 본 선택지와 트레이드오프:

| 방안 | 장점 | 문제 |
|---|---|---|
| PostGIS + 행정구역 경계 shapefile을 DB에 적재 | 외부 의존 없음, 오프라인 판정, 비용 0 | PostGIS 확장 + 법정동 경계 데이터(용량 수백 MB) 적재·갱신 부담. 행정구역 개편 시 수동 갱신 |
| 카카오/네이버 로컬 API 역지오코딩 | 정확·최신, 구현 단순 | 외부 API 호출량 = 러닝 건수. 쿼터/비용/장애 전파. 러닝 업로드 경로에 외부 의존이 생긴다 |
| VWorld(국토부) 무료 역지오코딩 | 공공 데이터, 무료 | 안정성·SLA 불확실 |

**권고: PostGIS + 법정동 경계.** 이유 — 이 판정은 **실시간일 필요가 없다**(cumulative 뱃지).
배치로 돌려도 되고, 업로드 경로에 외부 API 의존을 넣는 대가가 뱃지 2종의 값어치보다 크다.
다만 경계 데이터 적재는 별도 작업이므로, **이 2종은 판정 미구현 상태로 두고
후속 작업으로 분리**한다. 결정 필요 — 사용자 확인 요망.

### 7.2 판정 함수 44종 구현 (후속 라운드)

선행 의존성이 걸린 것들:

| 대상 | 막고 있는 것 | 담당 |
|---|---|---|
| `level_gte` 9종 | GM-04 XP/레벨 공식 미정 | gamification-designer |
| `season_*` 41종 템플릿 | **`seasons` / `user_season_tier` / `weekly_ranking_cache` 테이블이 아직 없다** (현재 `season_histories`만 존재) | backend |
| `district_diversity_gte` 2종 | 위 §7.1 | backend |
| `device_source_diversity_gte` 1종 | `"watchApple_or_watchGarmin"` OR 표현식 파서 규약 | gamification-designer + gps-tracking-engineer |
| `season_weekly_rank_lte` 12종 | `bucket` 값 도메인(`top1`/`top10`/`top10pct`) 확정 | gamification-designer |
| `streak_weeks_gte` 9종 | 주 단위 스트릭 + 1회 유예 규칙. 현 `recompute_profile_stats`는 **일 단위**만 계산 | gamification-designer |

### 7.3 시즌 인스턴스 발급 잡 — **별도 후속 작업으로 명시**

시즌 시작 시 seasonal 템플릿 41종을 `{templateId}@{seasonId}` id로 복제하고
`season_id`를 채우는 배치가 필요하다. `badges_id_slug_format` CHECK가 이미 이 형태를
허용하고(`^[A-Za-z0-9_]{3,64}(@[A-Za-z0-9-]{1,20})?$`),
`badges_season_id_scope` CHECK가 permanent에 `season_id`가 붙는 걸 막는다.
**선행 조건: `seasons` 테이블 생성.** 현재 `badges.season_id`는 FK 없는 text다.

### 7.4 카탈로그 문구 오류 3건 (backend 범위 밖 — 정본 CSV 수정 필요)

시드는 CSV를 **그대로** 옮겼으므로 아래는 DB에도 그대로 들어가 있다.
`docs/badge-catalog.csv`를 고친 뒤 26번을 재적용(멱등)하면 반영된다.

| id | 현재 | 문제 |
|---|---|---|
| `device_watchGarmin_1` / `_50` | "**가민로** 기록한 러닝이…" | 조사 오류 → "가민으로" |
| `session_dist_ultra50` | "단일 러닝 세션에서 **ultra50** 이상 거리를…" | 코드값 미번역 → "50km" |
| `pb_half_sub100` | 표시명 "**언더텐**" (조건: 하프 1시간 40분) | 1:40인데 "텐"? 의도 확인 필요 |

담당: gamification-designer (카탈로그 카피 소유자)

---

## 8. 그 외

### `get_advisors(security)` — 뱃지 관련 신규 경고 **0건**

기존 경고 4건만 남아 있고 전부 이번 작업과 무관하다:

- `public.rls_auto_enable()` — SECURITY DEFINER인데 **anon이 실행 가능**. 선재 이슈지만
  실질적 위험이라 별도 정리 권고.
- `public.sync_my_season()` — authenticated 실행 가능(클라이언트가 호출하므로 의도된 것).
- Auth leaked-password protection 비활성 (대시보드 설정 사항).

`badges`/`user_badges`에 대해 RLS 미설정·정책 누락 경고는 **없다.**

### TRD 갱신 (§4.1)

기존 표에 `Badge.*` 신규 필드는 이미 반영돼 있었다. 빠져 있던 것을 채웠다:
`UserBadge.id/userId/badgeId/earnedAt`, `Badge.name`(+`functional_name` 미시드 결정),
그리고 **서버 전용 컬럼 2개**(`user_badges.revoked`, `user_badges.source_run_id`)를
"대응 Dart 필드 없음"으로 명시 — 왜 모델에 추가하지 않는지 근거도 함께 적었다.
TRD §5 RLS 표는 이번 구현과 이미 일치해 수정 불필요.

### 클라이언트 호환성

`lib/features/gamification/data/supabase_gamification_repository.dart`의 3개 경로를
실제 스키마에 대해 확인했다:

- `fetchBadgeCatalog()` — `select().order('id')`. anon으로 158행 반환. 반환 shape가
  Dart `Badge` 필드와 1:1 (`id/name/description/category/scope/trigger_type/condition_type/condition/badge_grade/season_id`). ✅
- `fetchUserBadges()` / `watchUnseenBadges()` — `select('*, badge:badges(*)')` 임베드 조인 동작 확인. ✅
- `markBadgesSeen()` — `is_seen`만 UPDATE. 가드 트리거가 나머지 컬럼을 되돌린다. ✅

`.eq('is_active', true)` / `.order('sort_order')`는 클라이언트에서 이미 제거돼 있어
삭제된 컬럼을 참조하지 않는다.
