## Harness: Runnit running-app development

**Trigger:** For any feature development / implementation / modification request for this app (GPS tracking, wearable integration, run records, tier/ranking, badge·level, Flutter screens, Supabase backend, etc.), use the `running-app-builder` skill. Simple questions may be answered directly.

## Language policy

- **Harness files are written in English** — this file, `.claude/agents/*`, `.claude/skills/*`, and `docs/HARNESS.md`. When you log or update anything in these files, write it in English.
- **Product docs stay in Korean** — `docs/PRD.md`, `docs/BRD.md`, `docs/ARCHITECTURE.md`, `docs/TRD.md`.
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
