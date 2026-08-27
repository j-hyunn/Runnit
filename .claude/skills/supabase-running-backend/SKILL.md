---
name: supabase-running-backend
description: "Design workflow for the running app's Supabase backend (schema, RLS, ranking aggregation, realtime sync, server re-validation). Covers table design, camelCase↔snake_case mapping, and leaderboard performance strategy. Use for 'write the Supabase schema', 'RLS policy', 'optimize the ranking query', 'realtime sync' requests."
---

# Supabase running-backend design

The procedure for designing the running app's Supabase schema and API. Use the Supabase MCP tools (`list_tables`, `apply_migration`, `execute_sql`, `get_advisors`) to apply it to the real project.

> 📌 **`docs/PRD.md` is the single source of truth for product spec.** When this skill conflicts with the PRD, the PRD wins. Always confirm the distinction between tier (quarterly season · absolute) and weekly ranking (within tier · relative), and that crews are P2, before working.
>
> 📐 For implementation-structure detail, see `docs/ARCHITECTURE.md` §5 (backend architecture) and `docs/TRD.md` §4~§7 (DDL·RLS·API·server-validation rules) — if this skill's example DDL differs from the TRD, update the TRD to the current baseline.

## 1. Schema skeleton

```sql
-- users: extends Supabase Auth's auth.users
create table public.profiles (
  id uuid primary key references auth.users(id),
  display_name text not null,
  total_distance_m numeric not null default 0,  -- cache field, updated by trigger
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
  samples jsonb,  -- if large, consider a separate storage/table
  created_at timestamptz not null default now()
);

create table public.badges (
  id text primary key,          -- a meaningful slug like 'cumulative_100km'
  name text not null,
  trigger_type text not null check (trigger_type in ('session', 'cumulative')),
  condition jsonb not null
);

create table public.user_badges (
  user_id uuid references public.profiles(id),
  badge_id text references public.badges(id),
  earned_at timestamptz not null default now(),
  verified boolean not null default false,  -- server re-validation result
  primary key (user_id, badge_id)
);

-- ⚠️ Runnit confirmed spec: tier (cumulative season, absolute) and weekly ranking (within tier, relative)
--    have different aggregation cycles and evaluation methods, so keep the tables separate. Details: docs/PRD.md §5.3~§5.4.
--    Required tables: seasons / user_season_tier / weekly_ranking_cache
--    Below is a basic example of the ranking cache.
create table public.leaderboard_cache (
  scope text not null,          -- 'global' | 'weekly' | 'crew:{id}'
  user_id uuid references public.profiles(id),
  rank integer not null,
  score numeric not null,
  computed_at timestamptz not null default now(),
  primary key (scope, user_id)
);
```

## 2. Document the camelCase ↔ snake_case mapping

Handle the conversion between Dart models (camelCase) and Postgres columns (snake_case) in `supabase_flutter`'s serialization layer (freezed's `@JsonKey(name: 'distance_m')` or a shared converter), but **document every single field**. If this mapping is implicit, it's easy to get a mismatch with the backend column name when the mobile-architect adds a model field.

```
_workspace/{date}_backend_schema.md example:

| Dart field (RunRecord) | Postgres column (run_records) | Type |
|---|---|---|
| distanceMeters | distance_m | numeric |
| avgHeartRate | avg_heart_rate | integer nullable |
```

## 3. Leaderboard performance strategy

As the user count grows, a query that aggregates all of `run_records` on every read gets slow. Pick one of the following to match the project scale:

1. **Batch refresh**: refresh the `leaderboard_cache` table periodically with a scheduled function (Supabase Edge Function + cron), e.g. every 5 minutes. Fits early scale, simple to implement.
2. **Trigger-based incremental refresh**: on `run_records` insert, recompute only that user's rank via a trigger. When real-time fidelity is needed.
3. **Materialized view**: consider it when the aggregation logic gets complex (multiple scopes, multiple periods).

At the early stage, recommend option 1 (batch refresh) as the default — favor simplicity over premature optimization.

## 4. RLS policy principles

- `run_records`: only rows where `user_id = auth.uid()` can be inserted/updated; select is own-rows-only (rankings are exposed separately via `leaderboard_cache`)
- `leaderboard_cache`: select allowed for everyone; insert/update only by the service role (Edge Function)
- `user_badges`: select own-rows-only; insert only after server re-validation via the service role (update to `verified = true`)

## 5. Server re-validation (anti-cheat)

Do not reflect badges/scores the client computed and uploaded as-is. Recompute average pace on the server from the raw data of `run_records` (distance, time); if the value is unrealistic (e.g. a speed above the walking/running ceiling), exclude that record from ranking aggregation and mark it `flagged`. Why not delete: false positives are possible, so the supporting data must remain for user inquiries.

## 6. Realtime sync

Subscribing to `leaderboard_cache` changes via Supabase Realtime lets the client receive ranking changes without polling. But if the refresh cycle is a batch (5 min etc.), the perceived effect of a realtime subscription is limited, so agree with the flutter-ui-designer on exposing a "when was this refreshed" timestamp in the UI.
