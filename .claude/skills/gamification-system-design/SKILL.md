---
name: gamification-system-design
description: "Design workflow for the running app's badges/achievements, level/points, ranking algorithm, and challenges. Covers badge-catalog design, trigger timing, tie-breaking, and the anti-cheat (server re-validation) principle. Use for 'set the badge conditions', 'how to calculate the ranking score', 'level-up criteria' requests."
---

# Gamification system design

The procedure for designing the badge·ranking·level system that drives sustained engagement in the running app.

> 📌 **`docs/PRD.md` is the single source of truth for product spec.** When this skill conflicts with the PRD, the PRD wins. Always confirm the distinction between tier (quarterly season · absolute) and weekly ranking (within tier · relative), and that crews are P2, before working.
>
> 📐 For implementation-structure detail, see `docs/ARCHITECTURE.md` §7 (gamification architecture) and `docs/TRD.md` §9~§10 (tier·ranking aggregation · badge-evaluation tech spec).

## 1. Badge-catalog design

Badges split into two trigger types. Implement both to avoid missing milestone badges.

| Type | Example | Trigger timing |
|------|---------|----------------|
| Session | "first 5km", "dawn-run badge" (started before 6 AM) | at run-session end |
| Cumulative | "cumulative 100km", "30 consecutive days" | every time a cumulative stat updates after session end |

**Motivation curve:** early badges (first run, first 1km) use low thresholds for quick achievement; later badges (cumulative 1000km, 100 consecutive days) are long-term goals. Listing thresholds at even intervals (10km, 20km, 30km...) makes the later part dull — use a log scale or meaningful units (half-marathon distance, marathon distance, etc.).

```
Badge-catalog doc format (_workspace/{date}_badge_rules.md):

## BADGE_ID: first_run
- Name: First Step
- Condition: first RunRecord ever created
- Trigger: session end
- Grade: bronze

## BADGE_ID: cumulative_100km
- Name: 100km Club
- Condition: user.totalDistanceMeters >= 100_000
- Trigger: cumulative-stat update
- Grade: gold
```

## 2. Ranking algorithm

- **Scoring**: plain cumulative distance is the default. If you add a pace weight, document the formula explicitly (e.g. `score = distance_km * pace_factor`).
- **Dual structure (Runnit confirmed spec)**: **tier = absolute evaluation of cumulative season distance**, **weekly ranking = relative evaluation within the tier**. The tier split already solves the problem of new users always staying at the bottom, so do not add a fairness correction to the ranking score formula (double correction). Details in `docs/PRD.md` §5.3~§5.4.
- **Tie-breaking**: always set an explicit rule. E.g. on equal score, ascending by the timestamp at which the score was first reached.
- **Scope**: the Runnit MVP has exactly one ranking scope — **weekly ranking within tier**. Crew/regional scopes are P2 and not in the MVP (PRD §5.9). Design per-scope independent caches only if you add scopes.

## 3. Level/point system

- On completing a run, compute XP as base points + distance/pace bonus.
- Increase level-up thresholds exponentially (e.g. `level_n_threshold = base * n^1.5`) to raise level-up frequency in the low-level range and secure early retention.

## 4. Challenge system

When designing individual time-boxed goals (e.g. "reach 50km this month") (⚠️ crew battles are P2, excluded from the MVP):
- State the challenge start/end time, and preserve participation records even after the challenge ends (do not delete them in a way that makes recomputation impossible).
- Agree with the backend-engineer on a cache strategy for challenge progress, same as ranking — not real-time full recomputation.

## 5. Anti-cheat principle

Badge earns / scores computed on the client are **provisional**. Fraudulent earns are possible via GPS manipulation or unrealistic pace (e.g. a walking app logging 40 km/h), so write the evaluation logic as pure functions so the backend-engineer can recompute and re-validate from the raw `RunRecord` on the server. Records that fail server validation are shown in a "pending verification" state and not auto-deleted — they may be false positives, so do not revoke without explanation to the user.
