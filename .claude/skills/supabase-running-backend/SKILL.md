---
name: supabase-running-backend
description: "러닝 앱의 Supabase 백엔드(스키마, RLS, 랭킹 집계, 실시간 동기화, 서버 재검증) 설계 워크플로우. 테이블 설계, camelCase↔snake_case 매핑, 리더보드 성능 전략을 다룬다. 'Supabase 스키마 짜줘', 'RLS 정책', '랭킹 쿼리 최적화', '실시간 동기화' 요청 시 사용."
---

# Supabase 러닝 백엔드 설계

러닝 앱의 Supabase 스키마와 API를 설계하는 절차. Supabase MCP 도구(`list_tables`, `apply_migration`, `execute_sql`, `get_advisors`)를 사용해 실제 프로젝트에 반영한다.

## 1. 스키마 골격

```sql
-- users: Supabase Auth의 auth.users를 확장
create table public.profiles (
  id uuid primary key references auth.users(id),
  display_name text not null,
  total_distance_m numeric not null default 0,  -- 캐시 필드, 트리거로 갱신
  created_at timestamptz not null default now()
);

create table public.run_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null,
  ended_at timestamptz not null,
  distance_m numeric not null,
  duration_s integer not null,
  avg_heart_rate integer,
  samples jsonb,  -- 대용량이면 별도 storage/테이블 분리 검토
  created_at timestamptz not null default now()
);

create table public.badges (
  id text primary key,          -- 'cumulative_100km' 같은 의미있는 slug
  name text not null,
  trigger_type text not null check (trigger_type in ('session', 'cumulative')),
  condition jsonb not null
);

create table public.user_badges (
  user_id uuid references public.profiles(id),
  badge_id text references public.badges(id),
  earned_at timestamptz not null default now(),
  verified boolean not null default false,  -- 서버 재검증 결과
  primary key (user_id, badge_id)
);

create table public.leaderboard_cache (
  scope text not null,          -- 'global' | 'weekly' | 'crew:{id}'
  user_id uuid references public.profiles(id),
  rank integer not null,
  score numeric not null,
  computed_at timestamptz not null default now(),
  primary key (scope, user_id)
);
```

## 2. camelCase ↔ snake_case 매핑 문서화

Dart 모델(camelCase)과 Postgres 컬럼(snake_case)의 변환은 `supabase_flutter`의 직렬화 계층(freezed의 `@JsonKey(name: 'distance_m')` 또는 공통 컨버터)에서 처리하되, **필드 하나하나를 문서로 남긴다**. 이 매핑이 암묵적이면 mobile-architect가 모델 필드를 추가했을 때 백엔드 컬럼명과 어긋나는 사고가 나기 쉽다.

```
_workspace/{date}_backend_schema.md 예시:

| Dart 필드 (RunRecord) | Postgres 컬럼 (run_records) | 타입 |
|---|---|---|
| distanceMeters | distance_m | numeric |
| avgHeartRate | avg_heart_rate | integer nullable |
```

## 3. 리더보드 성능 전략

사용자 수가 늘어나면 매 조회마다 `run_records`를 전체 집계하는 쿼리는 느려진다. 다음 중 하나를 프로젝트 규모에 맞게 선택한다:

1. **배치 갱신**: `leaderboard_cache` 테이블을 스케줄 함수(Supabase Edge Function + cron)로 주기 갱신 (예: 5분마다). 초기 규모에 적합, 구현이 단순.
2. **트리거 기반 증분 갱신**: `run_records` insert 시 트리거로 해당 사용자의 랭킹만 재계산. 실시간성이 필요할 때.
3. **머티리얼라이즈드 뷰**: 집계 로직이 복잡해지면(다중 스코프, 다중 기간) 고려.

초기 단계에서는 1번(배치 갱신)을 기본값으로 권장한다 — 과도한 최적화보다 단순함을 우선한다.

## 4. RLS 정책 원칙

- `run_records`: `user_id = auth.uid()`인 행만 insert/update 가능, select는 본인 것만 (랭킹은 별도 `leaderboard_cache`를 통해 공개)
- `leaderboard_cache`: 전체 조회(select) 허용, insert/update는 service role(Edge Function)만
- `user_badges`: 본인 것만 select, insert는 service role을 통한 서버 재검증 후에만 (`verified = true`로 갱신)

## 5. 서버 재검증 (부정행위 방지)

클라이언트가 계산해 올린 뱃지/점수는 그대로 반영하지 않는다. `run_records`의 원시 데이터(거리, 시간)로 평균 페이스를 서버에서 재계산해 비현실적 값(예: 도보/러닝 상한을 초과하는 속도)이면 해당 기록을 랭킹 집계에서 제외하고 `flagged` 처리한다. 삭제하지 않는 이유: 오탐 가능성이 있으므로 사용자 문의 시 근거 데이터가 남아있어야 한다.

## 6. 실시간 동기화

`leaderboard_cache` 변경을 Supabase Realtime으로 구독하면 클라이언트가 폴링 없이 랭킹 변동을 받을 수 있다. 단, 갱신 주기가 배치(5분 등)라면 실시간 구독의 체감 효과는 제한적이므로, "언제 갱신됐는지" UI에 타임스탬프를 노출하는 것을 flutter-ui-designer와 협의한다.
