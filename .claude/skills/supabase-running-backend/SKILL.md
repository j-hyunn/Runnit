---
name: supabase-running-backend
description: "Design workflow for the running app's Supabase backend (schema, RLS, ranking aggregation, realtime sync, server re-validation). Covers table design, camelCase↔snake_case mapping, and leaderboard performance strategy. Use for 'write the Supabase schema', 'RLS policy', 'optimize the ranking query', 'realtime sync' requests."
---

# Supabase running-backend design

The procedure for designing the running app's Supabase schema and API. Use the Supabase MCP tools (`list_tables`, `apply_migration`, `execute_sql`, `get_advisors`) to apply it to the real project.

> 📌 **`docs/PRD.md` is the single source of truth for product spec.** When this skill conflicts with the PRD, the PRD wins. Always confirm the distinction between tier (quarterly season · absolute) and weekly ranking (within tier · relative), and that crews are P2, before working.
>
> 📐 For implementation-structure detail, see `docs/ARCHITECTURE.md` §5 (backend architecture) and `docs/TRD.md` §4~§7 (DDL·RLS·API·server-validation rules) — if this skill's example DDL differs from the TRD, update the TRD to the current baseline.

> 🛑 **The schema is already built** (`supabase/migrations/00~42`). A new feature **extends** it, it does not recreate it. Actual tables: `profiles` · `runs` (samples in `runs.samples jsonb`) · `badges` · `user_badges` · `leaderboard_entries` · `season_histories` · `tier_change_history` · `lunar_holidays` · `challenges` · `challenge_participations`. Seasons are the `season_id_at()` computed function, tier is the `profiles.current_tier` column. **No Deno Edge Functions** — server logic is entirely Postgres triggers/functions (`runs_guard`, `evaluate_badges`, `recompute_profile_stats`, `refresh_all_leaderboards`, …). Run `list_migrations` / `list_tables` first; details in `docs/TRD.md` §3.8·§4.0~§4.3·§10.2.

## 1. Schema skeleton (initial design — see the note above for what was actually built)

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
--    have different aggregation cycles and evaluation methods, so keep the LOGIC separate. Details: docs/PRD.md §5.3~§5.4.
--    Actual implementation (migrations 19~24, 03·40):
--      - tier  -> profiles.current_tier / season_distance_meters / tier_season_id columns
--                (updated synchronously by the upload trigger). Season boundary = season_id_at() function.
--      - weekly ranking -> leaderboard_entries (period='weekly', metric='distance',
--                scope='global', tier=<4 levels>). refresh_all_leaderboards() + pg_cron every 5 min.
--                reached_at column drives the PRD §8.2 three-stage tie-break.
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

1. **Batch refresh (current choice)**: refresh `leaderboard_entries` every 5 minutes with a SQL scheduled function (`refresh_all_leaderboards()` + `pg_cron`). Fits early scale, simple to implement.
2. **Trigger-based incremental refresh**: on `runs` insert, recompute only that user's rank via a trigger. When real-time fidelity is needed.
3. **Materialized view**: consider it when the aggregation logic gets complex (multiple scopes, multiple periods).

At the early stage, recommend option 1 (batch refresh) as the default — favor simplicity over premature optimization.

## 4. RLS policy principles

- `runs`: only rows where `user_id = auth.uid()` can be inserted/updated; select is own-rows-only. Server-owned columns (`is_flagged`/`awarded_points` etc.) are overwritten by the `runs_guard` trigger. Rankings are exposed via `leaderboard_entries`
- `leaderboard_entries`: select allowed for everyone; writes only by `refresh_all_leaderboards()` (SECURITY DEFINER)
- `user_badges`: own rows fully, others see only `revoked=false and verified=true`; insert only by the `evaluate_badges` trigger; the only column the client may update is `is_seen`

## 5. Server re-validation (anti-cheat)

Do not reflect badges/scores the client computed and uploaded as-is. The `runs_guard` BEFORE trigger recomputes distance/average pace from `runs.samples` (jsonb raw data); if the value is unrealistic it sets `is_flagged=true` + `flag_reason` and the record is excluded from tier/ranking aggregation (the row is not deleted — supporting data must remain for appeals). Thresholds and rules: `docs/TRD.md` §7·§10.2.

## 6. Realtime sync

Subscribing to `leaderboard_entries` / `user_badges` changes via Supabase Realtime lets the client receive ranking/badge changes without polling (`lib/core/api/realtime_refetch.dart`). But if the refresh cycle is a batch (5 min etc.), the perceived effect of a realtime subscription is limited, so agree with the flutter-ui-designer on exposing a "when was this refreshed" timestamp in the UI.
