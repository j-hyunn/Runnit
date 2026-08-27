---
name: running-app-builder
description: "Orchestrator that coordinates development work for Runnit (a run-record/ranking/badge-gamification Flutter app). Use for feature development / implementation / modification requests for this project — GPS tracking, wearable (Apple Watch/Wear OS) integration, run records, ranking/leaderboard, badge·level gamification, Flutter screens, Supabase backend, etc. Examples: 'build the run-tracking screen', 'add a badge system', 'wire up the ranking API', 'improve GPS accuracy', 'add watch integration'. Follow-up keywords: modify/supplement/rework/bug-fix/update/improve an existing feature, 'just redo tracking', 'change the badge conditions', 'based on the previous result' — always use this skill for those too."
---

# Runnit Builder — running-app development orchestrator

The unified skill that coordinates feature development of the Runnit (**individual-centric** run-record·tier·ranking·badge) Flutter app through a team of specialist agents.

> 📌 **The single source of truth for product spec is `docs/PRD.md` (confirmed), and the business context is `docs/BRD.md`.**
> When any harness file, including this skill, conflicts with the PRD, **the PRD wins.**
> Core structure — **tier** (3-month quarterly season, absolute, 4 levels 0/25/100/250km) × **weekly ranking** (relative within tier) × **badge·level** (permanent). Points are Phase 4, out of MVP scope, and **crews/groups are P2.**
> Implementation structure (data model · Supabase schema · API spec) follows `docs/ARCHITECTURE.md` and `docs/TRD.md` — those two docs also translate the PRD into implementation structure, so if they conflict with the PRD, the PRD wins.

## Execution mode: agent team (supervisor + specialist pool hybrid)

This orchestrator does not summon all 6 members on every request. **The supervisor (leader) analyzes the request scope and dynamically forms a team of only the needed specialists**, and the selected members self-coordinate via the shared task list and SendMessage. QA is not run once at the end but deployed the moment a module is finished (incremental QA).

## Agent composition (specialist pool)

| Specialist | Agent type | Owns | Skill | Deliverables |
|------------|-----------|------|-------|--------------|
| mobile-architect | custom | app structure · state management · core data models | flutter-architecture-setup | `lib/models/`, `_workspace/*_architect_data-model.md` |
| gps-tracking-engineer | custom | GPS·wearable tracking, distance/pace calculation | gps-wearable-tracking | `lib/features/tracking/`, `_workspace/*_gps_tracking_notes.md` |
| gamification-designer | custom | badge·ranking logic·level·challenges | gamification-system-design | `lib/features/gamification/`, `_workspace/*_badge_rules.md` |
| backend-engineer | custom | Supabase schema·RLS·ranking API·server validation | supabase-running-backend | Supabase migrations, `lib/core/api/`, `_workspace/*_backend_schema.md` |
| flutter-ui-designer | custom | screens·widgets·design system | flutter-ui-patterns | `lib/features/*/presentation/`, `_workspace/*_ui_design_tokens.md` |
| qa-integration-tester | general-purpose | boundary integration-consistency verification | integration-qa-flutter | `_workspace/*_qa_report.md` |

Specify `model: "opus"` on every Agent/TeamCreate call.

## Workflow

### Phase 0: context check (follow-up support)

0. **Read `docs/PRD.md` first (not skippable).** Check the sections relevant to the request (tier §5.3 / weekly ranking §5.4 / badge §5.5 / policy §8), and if the request conflicts with the PRD's confirmed spec, **tell the user before implementing.** If the request is a new feature not in the PRD, report that fact and note that the PRD will need updating after implementation. **Then check the relevant sections of `docs/ARCHITECTURE.md` · `docs/TRD.md` (data model · schema · API spec)** — implementing differently from the already-confirmed structure causes boundary mismatches between teammates, so follow existing decisions first, and if an extension is needed, instruct teammates to update the docs alongside.
1. Check the `_workspace/` directory and `pubspec.yaml` (whether a Flutter project exists).
2. Decide the execution mode:
   - **No `pubspec.yaml`** → initial run. Always include mobile-architect and start from the project skeleton.
   - **`pubspec.yaml` exists + new feature request** → incremental run. Include existing `lib/models/`, `_workspace/*_architect_data-model.md`, etc. in teammate prompts so existing deliverables are respected.
   - **`_workspace/` exists + a specific-area modification/bug request** → partial re-run. Re-summon only the relevant specialists.
3. If a prior `_workspace/*_qa_report.md` exists, check its unresolved items and include any that overlap this work's scope as priority.

### Phase 1: request analysis and specialist selection (supervisor judgment)

The leader analyzes the user request and decides which specialists to involve. Criteria:

| Request keyword/nature | Specialists to summon |
|------------------------|-----------------------|
| Needs a new data model or is about app structure | mobile-architect (almost always included — start with this team when a new field/model appears) |
| GPS, location, watch, background tracking, distance/pace calculation | gps-tracking-engineer |
| Badge, achievement, **tier·season**, ranking rules, level, challenge, points | gamification-designer |
| Backend, DB, API, auth, ranking query, realtime sync | backend-engineer |
| Screen, UI, widget, design, map/chart display | flutter-ui-designer |

If a feature spans multiple layers (e.g. "build the GPS-tracking screen" → model + tracking + UI, at least 3 people), include all relevant specialists in the team. A single-layer modification (e.g. "just change the badge icon color") is fine to handle by calling one flutter-ui-designer as a **subagent** — team-communication overhead is unnecessary here, so use a direct `Agent` tool call.

Create `_workspace/` (on the initial run; on a new run where prior work must be preserved, move it to `_workspace_{YYYYMMDD_HHMMSS}/` then recreate).

### Phase 2: team formation

```
TeamCreate(
  team_name: "runnit-team",
  members: [
    { name: "architect", agent_type: "mobile-architect", model: "opus", prompt: "{request summary + existing deliverable paths + 'read docs/PRD.md first and follow the confirmed spec'}" },
    { name: "tracking", agent_type: "gps-tracking-engineer", model: "opus", prompt: "..." },
    { name: "gamification", agent_type: "gamification-designer", model: "opus", prompt: "..." },
    { name: "backend", agent_type: "backend-engineer", model: "opus", prompt: "..." },
    { name: "ui", agent_type: "flutter-ui-designer", model: "opus", prompt: "..." }
    // only the specialists selected in Phase 1
  ]
)
```

```
TaskCreate(tasks: [
  { title: "confirm data model", assignee: "architect" },
  { title: "implement GPS tracking", assignee: "tracking", depends_on: ["confirm data model"] },
  { title: "implement badge/ranking logic", assignee: "gamification", depends_on: ["confirm data model"] },
  { title: "backend schema·API", assignee: "backend", depends_on: ["confirm data model"] },
  { title: "implement screens", assignee: "ui", depends_on: ["implement GPS tracking", "implement badge/ranking logic", "backend schema·API"] }
])
```

> **Every teammate prompt MUST include an instruction to read `docs/PRD.md` · `docs/ARCHITECTURE.md` · `docs/TRD.md` first.** A teammate who starts without knowing these docs risks designing on retired assumptions (crew-centric, relative-evaluation leagues, etc.) or arbitrarily redefining the already-confirmed data model / schema structure.
>
> The mobile-architect's data model is the prerequisite for all other work. 3~5 tasks per teammate is the right range (see the team-size guideline).

### Phase 3: collaborative execution

**Execution style:** teammates self-coordinate from the shared task list.

- When the architect confirms the data model, immediately SendMessage-broadcast to everyone — the rest of the work starts on this broadcast as the signal.
- When tracking confirms the session-end event structure, SendMessage it to gamification.
- When backend confirms the schema, ask the architect to check the field mapping; on any mismatch, coordinate via SendMessage immediately.
- ui consumes the architect/gamification/backend deliverables sequentially, so it can build the skeleton with mock data first until the dependencies are done.
- The leader monitors teammate-idle notifications, and intervenes in a stuck teammate via SendMessage or re-balances work via TaskUpdate.

**incremental QA:** when a teammate reports their module done (TaskUpdate complete), the leader immediately calls qa-integration-tester **as a subagent** to verify only that module's boundaries. Do not defer QA until the whole team's work is done. Pass any finding to the responsible teammate via SendMessage immediately so it's fixed within the same session.

### Phase 4: final integration verification

After all work is done (confirm via TaskGet), call qa-integration-tester once more to comprehensively re-verify all boundaries (model↔schema↔API↔UI↔event flow). Mark items covered in incremental QA as "recheck" and only newly-appeared integration points as new verification.

### Phase 5: cleanup

1. Send teammates a shutdown request (SendMessage), then TeamDelete
2. Preserve `_workspace/` (design docs and QA reports are reused as context for the next session)
3. Summary report to the user: implemented features, summoned specialists, QA result (pass/unresolved), next recommended work

## Data flow

```
[architect] --SendMessage(model confirmed)--> [tracking, gamification, backend, ui]
     |
     v
lib/models/*.dart  (common baseline for all teammates)
     |
     +--> [tracking] --event--> [gamification] --badge eval--> [backend] --re-validate--> leaderboard_cache
     |                                                              |
     +--> [backend] --schema confirmed--> [architect] (re-check field mapping)   |
     |                                                              v
     +----------------------------------------------------------> [ui] (final consumer)
     |
     v
[qa-integration-tester] --incremental--> verify each module the moment it's done
                        --final--> comprehensive verification after everything is done
```

## Error handling

| Situation | Strategy |
|-----------|----------|
| One teammate fails/stops | Leader detects via idle notification → SendMessage to check status → restart. If restart fails, the leader covers that area directly via a subagent call |
| Other teammates wait while the architect's model is unconfirmed | Leader asks the architect to raise priority; after 30+ min of delay, proceed with a provisional model for the rest and adjust later |
| A CONFIRMED issue found in QA | SendMessage the responsible teammate immediately; the module stays "incomplete" until the fix is done |
| Data conflict between teammates (field names, etc.) | Do not delete; report both claims to the user side by side; the architect makes the final call |
| **A teammate's deliverable conflicts with PRD·ARCHITECTURE·TRD** | qa-integration-tester detects it via doc cross-check → SendMessage the responsible teammate for a fix. The PRD is always top priority; if the PRD itself must change, **update `docs/PRD.md` after user confirmation**. If ARCHITECTURE/TRD divergence is a legitimate evolution of implementation detail (e.g. a batch-strategy change), **update the docs** to match the code |
| Supabase migration fails | backend-engineer reports the cause to the leader; if it's a destructive change, retry after user confirmation |

## Team size

This project repeats small-to-medium feature-unit work, so keep the Phase 1-selected team at 2~5 people on each run (per the guideline, small 2~3, medium 3~5). Requests that need all 6 (e.g. "lay out the whole MVP skeleton") can occur as an exception.

## Test scenarios

### Happy flow
1. User: "build a feature that records the route via GPS when a run starts and gives a completion badge when it ends"
2. Phase 0: no `pubspec.yaml` → initial run
3. Phase 1: needs data model (new) + GPS + badge + screen → select 4: architect, tracking, gamification, ui (backend excluded since it's not in this request)
4. Phase 2: TeamCreate 4, TaskCreate 4 (with dependencies)
5. Phase 3: architect confirms the RunSample/RunRecord/Badge models → broadcast → tracking·gamification·ui start in parallel → qa-integration-tester incremental verification as each finishes
6. Phase 4: comprehensive verification, confirm no boundary issues
7. Phase 5: team cleanup, report implementation summary to the user + "recommend wiring up ranking/backend next"

### Error flow
1. In Phase 3, gamification finds a missing field (grade) in the architect's `Badge` model while writing the badge-evaluation logic
2. gamification SendMessages the architect to add the field
3. architect extends the model and re-broadcasts the change to everyone
4. tracking·ui confirm no impact on their in-progress work; only gamification reworks with the updated model
5. incremental QA finds the extended field is not yet reflected in the actual DB schema (because backend wasn't in this request) → the report notes "backend not included — needs reflecting in the next session"
6. The Phase 5 report clearly includes this unresolved item
