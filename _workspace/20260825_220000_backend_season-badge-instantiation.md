# 시즌 뱃지 인스턴스화 + 판정 로직 활성화

- 작업일: 2026-08-25
- 담당: backend-engineer
- 관련 마이그레이션: `supabase/migrations/20260825200000_31_season_badge_instantiation.sql`,
  `supabase/migrations/20260825210000_32_season_badge_condition_logic.sql`
- 프로젝트: `xwtbwexcofcgmbvktwdo`

## 0. 재시도 컨텍스트

직전 세션이 세션 사용량 한도로 중단됐다. 재개 시 `supabase/migrations/`를 먼저 확인한 결과
**31번 파일(`20260825200000_31_season_badge_instantiation.sql`, 211줄)이 이미 작성돼 있었다** —
그러나 `list_migrations`로 실제 DB에는 아직 적용되지 않은 상태였다(로컬 파일만 존재). `_workspace/`에는
이 작업에 대한 보고서가 없었다. 즉 직전 세션은 인스턴스화 함수 설계까지는 끝냈지만 (a) DB 적용, (b) 판정
로직 확장(스코프 항목 2), (c) 보고서 작성을 못 하고 끊긴 것으로 판단했다. 31번 파일 내용은 검토 후 그대로
재사용(수정 없이 적용)했고, 판정 로직(32번)만 이번에 새로 작성했다.

## 1. 재사용한 기존 인프라 (재조사 결과)

27번 마이그레이션은 `scope='seasonal'` 19개 condition_type을 전부 "seasons/user_season_tier/
weekly_ranking_cache 테이블이 없다"는 이유로 스텁 처리했다. 하지만 19~24번 마이그레이션을 다시 읽어보니
**그 세 테이블과 기능적으로 동등한(오히려 더 정교한) 인프라가 이미 있었다**:

| TRD 원안 테이블 | 실제 대체 구현 | 근거 마이그레이션 |
|---|---|---|
| `seasons` | `season_id_at(ts)` / `season_start(id)` / `season_end(id)` / `season_next_id` / `season_previous_id` — 순수 계산 함수. 분기는 달력에서 결정론적으로 유도되므로 테이블 불필요 | 20 |
| `user_season_tier` | `profiles.current_tier` / `season_distance_meters` / `tier_season_id` (진행 중 시즌) + `season_histories`(마감된 시즌 스냅샷: `final_tier`, `distance_meters`, `run_count`, `best_weekly_rank`) | 19, 21, 22 |
| `weekly_ranking_cache` | `leaderboard_entries` (`period='weekly', metric='distance', scope='global', tier=<티어>`) — 5분마다 티어별 4개 보드가 `refresh_all_leaderboards()`로 갱신되고, 지난 주차 행은 삭제되지 않고 누적 보존됨(같은 `period_start`끼리만 정리) | 23, 24, 15(cron) |

이 재발견 덕분에, 애초에 "테이블이 없어서 못 한다"는 전제가 더 이상 유효하지 않았고, 19종 중 **18종을
실제로 판정 가능**하게 됐다(이전 라운드는 19종 전부 보류).

## 2. 인스턴스화 (마이그레이션 31, 이미 작성돼 있던 것을 검토 후 그대로 적용)

- `ensure_season_badge_instances(p_season_id text default null)`: `scope='seasonal' and season_id is null`
  인 41개 템플릿을 `{templateId}@{seasonId}` id로 복제해 현재(또는 지정) 시즌 인스턴스를 발급. `on conflict
  (id) do nothing`으로 멱등.
- **발급 시점: lazy + 3개 기존 진입점**(신규 크론 없음, 셋 다 멱등이라 어느 순서로 와도 안전):
  1. `evaluate_badges()` — 러닝 업로드 시 (뱃지 지급 전에 인스턴스가 있어야 함)
  2. `sync_my_season()` — 홈 화면 진입 시 읽기 경로 (러닝 없이도 갤러리에 시즌 뱃지가 보여야 함)
  3. `reset_stale_seasons()` — 분기 첫날 00:05 KST 크론 (사용자가 열기 전에 미리 발급)
- 백필: 마이그레이션 말미에 `select public.ensure_season_badge_instances();`로 현재 시즌(`2026-Q3`)
  인스턴스를 즉시 발급.

### 검증 결과
```sql
select count(*) from public.badges where scope='seasonal' and season_id is not null;
-- 41, id 예: 'sdist_100km@2026-Q3', season_id = '2026-Q3'
```
`Season.currentId()`(`lib/models/season.dart`)와 동일한 `"{year}-Q{quarter}"` 포맷을 SQL
`season_id_at()`으로 재현했으므로 클라이언트·서버 시즌 id가 어긋나지 않는다.

## 3. 판정 로직 확장 (마이그레이션 32, 신규 작성)

`evaluate_badge_condition`을 `create or replace`로 전체 재정의하며 seasonal 스텁 블록(기존 27번의
`when 'season_tier_reached', ... then raise notice ... return false;` 19-way 블록)을 실제 케이스들로
교체했다. 기존 21종(permanent) 로직은 그대로 복사 유지 — 변경 없음.

### 실제로 판정 가능해진 것 (18종)

| condition_type | 판정 근거 |
|---|---|
| `season_tier_reached` | `profiles.current_tier >= 조건.tier` (tier enum 순서 bronze<silver<gold<platinum 그대로 비교 가능) AND `tier_season_id = 현재시즌` |
| `season_cumulative_distance_gte` | `profiles.season_distance_meters >= distanceKm*1000` |
| `season_weekly_rank_lte` | `leaderboard_entries`에서 `tier=조건.tier`, 이번 시즌 주차, `bucket`(top1/top10/top10pct, top10pct는 `participant_count*0.1` 올림) 매칭 존재 여부 |
| `season_first_run` | 이번 시즌 완료 기록 존재 |
| `season_first_run_within_days` | 이번 시즌 첫 기록의 `started_at`이 `season_start + days` 이전 |
| `season_weekly_attendance_full` / `_gte_pct` | 시즌 시작 주~현재 주 범위에서 활동한 주 비율 계산 |
| `season_weekly_rank_rising_streak_gte` | 이번 시즌 내 티어 보드 주차별 순위를 `lag`로 비교, 연속 개선 구간 최장 길이 |
| `season_pb_achieved` | 이번 시즌 실외 기록의 거리가 시즌 이전 전체 최장거리보다 큰 경우 존재 |
| `season_best_week_distance_pb` | 이번 시즌 주간(티어무관 보드) 거리가 시즌 이전 모든 주차 최고 기록보다 큰 경우 존재 |
| `season_challenge_completed` | `challenge_participations.completed_at`이 이번 시즌 범위 내(현재 챌린지 0건이라 항상 false — 스텁 아니라 데이터 없음) |
| `season_comeback_run` | 이번 시즌 최근 두 기록의 시간 간격이 `gapWeeks` 이상 |
| `season_first_long_distance` | 이번 시즌 기록 중 `distanceKm*0.98` 이상 존재 |
| `season_start_streak_weeks_gte` | 시즌 시작 후 첫 N주(각 7일 단위) 전부 활동 존재 |
| `season_streak_weeks_gte` | 이번 시즌 범위로 제한한 주 단위 연속 스트릭(기존 permanent `streak_weeks_gte`와 동일한 island 기법 재사용) |
| `season_final_week_active` | 현재 시각이 시즌 마지막 7일 이내이고 그 구간에 기록 존재 |
| `season_first_and_last_week_active` | 시즌 첫 주 + 마지막 주(현재 시각 기준) 모두 활동 존재 |
| `consecutive_seasons_participated_gte` | 현재 시즌(진행 중 데이터) + `season_histories`(과거 마감 스냅샷)를 `season_previous_id`로 거슬러 올라가며 연속 참여 확인 |

### 계속 스텁(false)으로 남긴 것 — 1종, 진짜 데이터 부재

- **`season_max_tier_reached_before_pct`**: "시즌 중 최초로 현재 티어에 도달한 시각"이 필요하다.
  `profiles`는 현재 티어값만 들고 있고, `season_histories`는 시즌 **마감** 시점 스냅샷만 남긴다.
  티어 변경 이력을 타임스탬프와 함께 남기는 테이블(`tier_history` 류)이 없으면 "50% 시점 이전에
  이미 도달했는가"를 사후에 복원할 방법이 없다 — 진짜 스키마 갭이다. 해소하려면
  `profiles`에 트리거를 추가해 티어가 오를 때마다 이력 행을 쌓는 별도 테이블이 필요하다(후속 작업으로
  분리 권장).

### 명시적으로 깔고 간 가정 (문서화, 후속 튜닝 여지)
- `season_weekly_rank_rising_streak_gte`: "연속 상승" 최장 구간이 시즌 어디에서든 존재하면 인정 —
  반드시 가장 최근 주까지 이어질 필요는 없다고 해석.
- `season_start_streak_weeks_gte`: 시즌 첫 N주는 "시즌 시작일이 속한 KST 캘린더 주"부터 7일 단위로
  끊는다. 분기 시작일이 항상 월요일은 아니므로 첫 주에 이전 분기 며칠이 섞여 계산될 수 있다.
- `season_pb_achieved` / `season_best_week_distance_pb`: "이번 시즌 이전 전체 이력" 대비 이번 시즌에
  신기록이 나왔는지를 본다(이번 시즌 내부에서의 상대적 최고 기록이 아님).
- `season_challenge_completed`: 메커니즘은 완성돼 있으나 `challenges`/`challenge_participations`가
  현재 0건이라 계속 false — 챌린지가 시딩되면 코드 변경 없이 바로 동작한다.

## 4. 검증

```sql
-- 인스턴스 41개, 포맷 확인
select count(*), array_agg(distinct season_id) from public.badges
where scope='seasonal' and season_id is not null;
-- 41, {"2026-Q3"}

-- season_cumulative_distance_gte / season_tier_reached 수동 검증
-- (a8: platinum, 252,500m / a6: silver, 33,000m / a5: silver, 32,200m)
select
  evaluate_badge_condition(a8, 'season_cumulative_distance_gte', '{"distanceKm":200}') -- true
  evaluate_badge_condition(a6, 'season_cumulative_distance_gte', '{"distanceKm":200}') -- false
  evaluate_badge_condition(a8, 'season_tier_reached', '{"tier":"gold"}')               -- true (platinum >= gold)
  evaluate_badge_condition(a5, 'season_tier_reached', '{"tier":"gold"}')               -- false (silver < gold)
-- 전부 기대값과 일치

-- season_weekly_rank_lte: bronze 티어 보드(rank 1~4, participant_count=4)
-- rank=1 유저에게 top1 조건 -> true, rank=4 유저에게 top1 -> false, top10 -> true
-- 전부 기대값과 일치

-- evaluate_badges() 엔드투엔드 (플래티넘/최고거리 유저 a8)
select evaluate_badges(a8);
-- stier_bronze/silver/gold/platinum, srank_platinum_top1/top10/top10pct,
-- sdist_10~200km(6종 전부), sevent_welcome/half_attendance/early_start/season_pb/
-- best_week/start_dash_3w/streak_4w/streak_8w 등 20개 시즌 뱃지가 실제 지급됨
-- (조건에 맞는 뱃지만 정확히 골라 지급 — 오지급 없음)
```

`get_advisors(security)`: 신규 경고 없음. 기존 경고 3건(모두 이번 변경과 무관, 사전부터 존재)
- `rls_auto_enable` anon/authenticated 실행 가능 경고 2건
- `auth_leaked_password_protection` 비활성화 경고 1건
`ensure_season_badge_instances` / `evaluate_badges` / `evaluate_badge_condition`은 모두
`public, anon, authenticated`로부터 EXECUTE가 회수되어 있어(=클라이언트가 직접 호출 불가) 새 경고를
유발하지 않았다.

## 5. 클라이언트 반영 확인

`lib/features/gamification/domain/badge_progress.dart`의 `BadgeProgressCalculator.forCatalog`는
`scope=seasonal && (season_id is null || season_id != 현재시즌id)`인 뱃지를 걸러낸다. 이번 작업으로
현재 시즌(`2026-Q3`) 인스턴스 41개가 실제로 존재하므로, 다음에 어떤 사용자든 (a) 러닝을 업로드하거나
(b) 홈 화면에 진입해 `sync_my_season()`이 호출되면 그 시점에 인스턴스가 보장되고, 판정 결과에 따라
`user_badges`가 채워지며 갤러리 시즌 섹션에 즉시 반영된다. 신규 시즌이 시작되면 같은 메커니즘이 새
`season_id`로 새 인스턴스 41개를 만들고, 지난 시즌 인스턴스는 그대로 남아 이력이 보존되므로 "시즌마다
미획득 상태로 리셋" 요구사항이 삭제 없이 자연히 충족된다.

## 6. `docs/TRD.md` 갱신

TRD §3.6 앞에 갱신 경고 블록을 추가했다 — TRD 원안(§4)의 `seasons` / `user_season_tier` /
`weekly_ranking_cache` 테이블 설계가 실제로는 만들어지지 않았고, 계산 함수 + 기존 `profiles`/
`leaderboard_entries`/`season_histories` 재사용으로 대체됐다는 점, 뱃지 인스턴스 id 포맷이
`{templateId}_{season}`이 아니라 `{templateId}@{seasonId}`라는 점을 명시했다. §4의 DDL 블록 자체를
새로 쓰지는 않았다 — 이 TRD는 애초에 19~30번 마이그레이션이 이미 여러 차례 갱신해온 "원안"이라
전면 재작성은 별도 작업으로 분리하는 게 낫다고 판단했다(범위 밖 이슈로 spawn_task 고려 가능).

## 파일 목록

- `supabase/migrations/20260825200000_31_season_badge_instantiation.sql` (기존 파일, 이번에 DB 적용)
- `supabase/migrations/20260825210000_32_season_badge_condition_logic.sql` (신규 작성 + 적용)
- `docs/TRD.md` (§3.6 앞 갱신 경고 블록 추가)
- `_workspace/20260825_220000_backend_season-badge-instantiation.md` (본 보고서)
