## Harness: Runnit running-app development

**Trigger:** For any feature development / implementation / modification request for this app (GPS tracking, wearable integration, run records, tier/ranking, badge·level, Flutter screens, Supabase backend, etc.), use the `running-app-builder` skill. Simple questions may be answered directly.

## Language policy

- **Match the document's existing language when updating it.** A document written in English is updated, logged, and appended to in English; a document written in Korean stays Korean. Never switch a document's language as a side effect of an edit.
- **Harness files are English** — this file, `.claude/agents/*`, `.claude/skills/*`, `docs/HARNESS.md`. New harness files are authored in English.
- **Product docs are Korean** — `docs/PRD.md`, `docs/BRD.md`, `docs/ARCHITECTURE.md`, `docs/TRD.md`. Existing `_workspace/*` deliverables are Korean; keep each one in its own language.
- **Always reply to the user in Korean**, regardless of which document you read.

## Reference documents — read the section you need directly

| Document | What it holds | When to read |
|----------|---------------|--------------|
| [docs/PRD.md](docs/PRD.md) | **The single source of truth for product spec.** Features, policy, priorities | Always, before designing / implementing / verifying a feature |
| [docs/BRD.md](docs/BRD.md) | Business context, revenue model, GTM, P&L structure | When judging monetization / growth-lever questions |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture — client/backend structure, data flow, module boundaries | When deciding structure, state management, module boundaries |
| [docs/TRD.md](docs/TRD.md) | Data-model code, Supabase DDL, API / validation-rule specs | When implementing schema, API, validation logic |
| [docs/HARNESS.md](docs/HARNESS.md) | Harness goal, core-structure summary (tier/ranking/badge), retired assumptions, change history | When checking harness background / history |

## Rules

1. Before designing / implementing / verifying a feature, **you MUST read the relevant section of `docs/PRD.md`.** For architecture / schema work, also check the relevant sections of ARCHITECTURE / TRD.
2. When a harness file (agents, skills, this file) or ARCHITECTURE / TRD conflicts with the PRD, **the PRD wins.**
3. ARCHITECTURE / TRD do not define new spec — they translate the PRD into implementation structure and are living documents. When the implementation evolves past them (schema extensions, batch-strategy changes, etc.), update the documents so code and docs do not drift apart.
4. If you implement a new feature not in the PRD, or need to change a confirmed spec, **get the user's confirmation, then update `docs/PRD.md` and record it in the change history.** Record harness-configuration changes in the `docs/HARNESS.md` change history.
