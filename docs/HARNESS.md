# Harness operations doc (Runnit)

Harness background, core-structure summary, and change history split out of CLAUDE.md. The real spec always lives in PRD / ARCHITECTURE / TRD; if the summary below conflicts with them, the source document wins.

## Goal

Coordinate development of the Runnit Flutter running app — run records, GPS/wearable tracking, ranking, badge gamification — through a team of specialist agents.

## Core structure (the parts that get confused) — details in PRD §5.3~§5.5·§8, ARCHITECTURE §7

| Axis | Cycle | Evaluation | Summary |
|------|-------|------------|---------|
| **Tier** | 3 months (quarterly season) | **Absolute** | Based on cumulative season distance. 4 levels — Bronze 0 / Silver 25km / Gold 100km / Platinum 250km. No demotion mid-season |
| **Weekly ranking** | 1 week (Mon–Sun KST) | **Relative** | Rank by weekly cumulative distance **within the same tier**. Resets every week |
| **Badge · level** | Permanent | Absolute | Never resets |
| **Points** | Phase 4 | — | Out of MVP scope |

## ⚠️ Retired assumptions (left over from the initial harness setup)

- ~~Crew-centric design~~ → **Individual-centric app.** Crews/groups are **P2** (PRD §2.3, §5.9)
- ~~Relative-evaluation league matching~~ → **Absolute-evaluation tiers.** Do not build sub-group matching logic (PRD §5.4.1)
- ~~Points in the MVP~~ → **Phase 4**

## Change history

| Date | Change | Target | Reason |
|------|--------|--------|--------|
| 2026-08-19 | Initial setup (6 agents, 7 skills, 1 orchestrator) | All | New-project harness build |
| 2026-08-19 | Confirmed Supabase backend (no change, kept the existing default); set wearable priority to Apple Watch·Garmin — Garmin designed via Garmin Connect→HealthKit/Health Connect sync, added references/garmin-integration.md | agents/gps-tracking-engineer.md, skills/gps-wearable-tracking/ | User confirmed backend / watch priority |
| 2026-08-19 | **Wrote PRD/BRD and wired the harness** — added the product-spec entry point to CLAUDE.md, injected `docs/PRD.md` references into all 6 agents and 7 skills, added a PRD pre-read step to the orchestrator's Phase 0 | CLAUDE.md, agents/* (6), skills/* (7), docs/PRD.md, docs/BRD.md | Product spec was confirmed; wire the harness to work from it |
| 2026-08-19 | **Cleaned up retired assumptions** — replaced crew-centric ranking/challenges and relative-evaluation leagues with the tier (absolute) + weekly ranking (relative) dual structure. Documented seasons / user_season_tier / weekly_ranking_cache separation in the backend schema guide | agents/gamification-designer.md, agents/backend-engineer.md, agents/mobile-architect.md, skills/gamification-system-design/, skills/supabase-running-backend/ | Prevent the harness from designing on pre-confirmation assumptions |
| 2026-08-25 | **Wrote ARCHITECTURE/TRD drafts (Phase 0 deliverable)** — synthesized the technical decisions already reflected in PRD v1.3 and the harness agents/skills (data model, Supabase schema skeleton, GPS/wearable integration path, server-validation pipeline) into new `docs/ARCHITECTURE.md`, `docs/TRD.md` | CLAUDE.md, docs/ARCHITECTURE.md (new), docs/TRD.md (new) | Document the PRD §11 Phase 0 deliverable (architecture / data model / Supabase schema) to justify starting Phase 1 |
| 2026-08-26 | **Implemented 7 badge-system backlog items** — XP/level formula (max level 60), weekly streak + one grace, device-vendor array model (`runs.device_vendors`), unified PB/distance-badge tolerance (target − min(target×2%, 300m)), lunar-calendar lookup table (2026~2040), removed the `district_diversity_gte` badge. TRD stepped from v0.1→v0.8 | docs/TRD.md, Supabase migrations 36~42 | Handled item 1 (badge system) of the user's 5 backlog items |
| 2026-08-26 | **Implemented the share-card feature (PRD HI-08·HI-10, P0)** — confirmed client widget capture (`RenderRepaintBoundary`), fixed the spec as a 9:16 transparent overlay sticker per the reference image (no shadow, no background), bottom-sheet→full-page transition (including the bottom-nav-bar regression fix) | lib/features/sharing/*, docs/TRD.md §3.9 | Handled item 3 (share card) of the 5 backlog items; secures the free growth lever BRD §5.2 requires |
| 2026-08-27 | **PRD v1.4: narrowed HI-10 to PB-update sharing** — while switching badge-earned / tier-promotion celebration from dialog to full-page + animation (`_AchievementBurst`), kept the share button only for PB updates and left badge/tier as celebration-only. Removed the summary-screen inline celebration and the suppressor counter (`achievementCelebrationSuppressors`) — the global `AchievementCelebrationHost` full page is the sole consumption point | docs/PRD.md (v1.4), docs/TRD.md (v0.9, §3.9.3), docs/ARCHITECTURE.md (v0.2, §7.4.1), lib/features/sharing/presentation/widgets/achievement_celebration.dart | Over three passes during implementation the user narrowed the share scope to PB-only; aligned the docs with the actual implementation |
| 2026-08-27 | **Simplified CLAUDE.md into a reference-index structure** — moved the core-structure summary, retired assumptions, and change history into this file; CLAUDE.md keeps only the reference table + operating rules. Removed the pinned PRD version (v1.0) from running-app-builder | CLAUDE.md, docs/HARNESS.md (new), skills/running-app-builder/ | User asked for CLAUDE.md to be a thin reference index whose content lives in the referenced files |
| 2026-08-27 | **Converted all harness files to English** — CLAUDE.md, all 6 agents, all 8 skill files (SKILL.md + references), and this file. Added the language policy to CLAUDE.md: harness files and their updates in English, product docs (docs/PRD·BRD·ARCHITECTURE·TRD) stay Korean, always reply to the user in Korean | CLAUDE.md, agents/* (6), skills/* (8 files), docs/HARNESS.md | User asked for harness files to be authored and maintained in English while keeping Korean replies |
