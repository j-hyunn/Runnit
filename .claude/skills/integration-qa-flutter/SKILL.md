---
name: integration-qa-flutter
description: "Integration-consistency verification checklist and methodology for the running app. Provides the procedure for verifying Flutter model↔Supabase schema, API↔frontend hooks, GPS event↔badge evaluation, and routing boundaries. Used by the qa-integration-tester agent right after each module is finished."
---

# Flutter running-app integration QA

Boundary (inter-module connection point) mismatches are not caught by verifying each module in isolation. Always open both sides and compare.

> 📌 **`docs/PRD.md` is the single source of truth for product spec.** When this skill conflicts with the PRD, the PRD wins. Always confirm the distinction between tier (quarterly season · absolute) and weekly ranking (within tier · relative), and that crews are P2, before working.
>
> 📐 During verification, also check whether `docs/ARCHITECTURE.md` · `docs/TRD.md` match the real code — especially cross-checking TRD §4.1 (mapping table) and §7 (validation rules) against the actual implementation.

## Verification checklist

### Model ↔ schema
- [ ] Does every field of the Dart freezed model map 1:1 to a Supabase table column (cross-check the mapping table in `_workspace/*_backend_schema.md` against the real code)
- [ ] Do nullable fields match on both the Dart (`?`) and Postgres (`nullable`) sides
- [ ] Is a multi-source model like `RunSample` (`source: phone | watch`) represented the same way in the schema

### API ↔ frontend
- [ ] Does the actual return shape of the Supabase query/RPC match the Repository's parsing type (if the response is wrapped, is there unwrap logic)
- [ ] Does the frontend distinguish the immediate response (local evaluation) from the final value after server re-validation (e.g. is there a separate UI for the badge `verified: false` state)

### GPS event ↔ badge evaluation
- [ ] Are the session-end event-publishing code (`lib/features/tracking/`) and the badge-evaluation subscription code (`lib/features/gamification/`) actually wired (do the event name/stream match)
- [ ] Are cumulative-badge conditions checked not only at session end but also at the cumulative-stat-update moment
- [ ] Do badges queued offline actually call the server-sync function on reconnect

### Routing
- [ ] Does every `context.go`/`Navigator.push` value in the code match a route actually defined in `go_router`
- [ ] Are dynamic segments (`/run/:id`) filled with the correct parameters

### Ranking consistency
- [ ] Does the score/rank the client shows use the server-re-validated `leaderboard_cache` value (is it exposing a client local calculation as-is)
- [ ] Is the tie-break rule (`_workspace/*_badge_rules.md`) reflected in the actual sort query

## Verification method: read both sides at once

| Target | Left (producer) | Right (consumer) |
|--------|-----------------|------------------|
| Model↔schema | `lib/models/*.dart` | Supabase migration SQL |
| API↔frontend | Supabase query/RPC definition | `lib/core/api/`, Repository |
| Event↔badge | the tracking module's event publisher | the gamification module's subscriber |
| Routing | `go_router` route definitions | every navigation call in the code |

## When to run

Verify each module's boundaries the moment it is finished. Do not batch all verification for after the whole project is done — if an early-stage mismatch propagates into later modules, the fix cost grows.

## Report format

`_workspace/{date}_qa_report.md`:

```
## [CONFIRMED] RunRecord.avgHeartRate ↔ run_records.avg_heart_rate type mismatch
- Files: lib/models/run_record.dart:23, supabase/migrations/0003_run_records.sql:8
- Problem: Dart is int?, Postgres is defined as numeric
- Suggested fix: unify the Postgres column to integer

## [PASS] GPS session-end event → badge-evaluation wiring confirmed
- lib/features/tracking/domain/run_session_notifier.dart:45 publishes onSessionEnd
- lib/features/gamification/domain/badge_evaluator.dart:12 subscription confirmed
```
