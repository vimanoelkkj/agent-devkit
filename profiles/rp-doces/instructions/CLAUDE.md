# rp-doces

> Project memory for Claude Code. Keep this file short and high-signal —
> bloated memory gets ignored. Put hard guarantees in hooks, not prose.

## Communication

Talk to the user in Brazilian Portuguese (pt-BR). Code, identifiers, commands, SQL, commit
messages and this rule/doc file set (`CLAUDE.md`, `.claude/rules/**`) stay in English, as
already used throughout the project.

## Behavioral guidelines

<!-- aia-harness:behavioral — non-negotiable; do not edit, reorder, or remove during enrichment -->

1. **Think before coding** — state assumptions explicitly; if multiple interpretations exist, present them instead of picking silently; say so when a simpler approach exists; if something is unclear, stop and ask.
2. **Simplicity first** — minimum code that solves the problem. No speculative features, no abstractions for single-use code, no unrequested configurability, no error handling for impossible scenarios. If 200 lines could be 50, rewrite.
3. **Surgical changes** — touch only what the request requires; match existing style; don't refactor, reformat, or "improve" adjacent code. Remove orphans _your_ change created; leave pre-existing dead code alone (mention it, don't delete it). Every changed line should trace directly to the user's request.
4. **Goal-driven execution** — turn tasks into verifiable goals ("fix the bug" → "write a test that reproduces it, then make it pass"). For multi-step work, state a brief plan with a verify check per step, then loop until verified.

## Stack

TypeScript, JavaScript, SQL · React · npm

Architecture: **layered**.

## Canonical commands

Always use these exact commands (do not guess):

- **Install:** `npm install`
- **Format:** `npx prettier --write <changed files>` — only files you touched; Prettier is not pinned in `package.json`, never run it on `.`
- **Lint:** `npm run lint` (Biome, `recommended` preset) — informational, not yet a blocking gate in CI or the Stop hook; do not add `--write`
- **Typecheck:** `npm run typecheck`
- **Test:** `npm run test`
- **Build:** `npm run build`
- **Run/Dev:** `npm run dev` (Vite only — no `/api`); full stack with Functions + D1: `npm run build && npm run pages:dev`

## Skills — for this stack

> Invoke the matching skill before working in its domain.

- **React** → `vercel-react-best-practices` — components, hooks, performance
- **UI/UX** → `ui-ux-pro-max:ui-ux-pro-max` — component design, accessibility, UX

### Automatic skill usage

Automatically invoke every relevant project skill before acting. If multiple skills apply, combine them.
Do not wait for the user to name a skill explicitly.

## Workflow & Agents

Invoke `superpowers:subagent-driven-development` for **non-trivial** implementation — trigger it when the request meets **≥2** of:

- touches **3+ files** or **2+ domains/layers** (UI + agent, API + DB…)
- is a **new feature / epic / cross-cutting refactor** (not a one-line or single-function change)
- needs a **multi-step plan** or ordered tasks, each with its own verification
- has **unclear scope or root cause** and needs exploration before coding

Skip it — implement inline — for typo/copy fixes, single-function edits, config tweaks, or one-file bugs with an obvious cause.

### Parallel wave execution (subagent-driven-development)

<!-- aia-harness:parallel-sdd — parallel wave execution override; do not remove -->

Override `superpowers:subagent-driven-development`'s serial one-implementer-at-a-time default with
parallel waves of independent tasks. Its "never dispatch implementers in parallel" red flag is
superseded here because its two premises are removed: disjoint file ownership per wave, and
controller-serialized commits instead of implementer self-commits. During planning, tag each task
`Files:` / `Depends-on:`; batch tasks with disjoint `Files` and no mutual dependency into one wave,
and dispatch their implementers in a single message using the best-fitting available agent type.
Keep the skill's implementer/reviewer prompt contracts intact — the only change is implementers do
NOT self-commit. Untagged or uncertain tasks run serial (no regression). Full protocol:
`.claude/rules/08-parallel-subagent-driven-development.md`.

## Technical & Architecture Documentation

Canonical product architecture and contracts are maintained in neutral documentation:
- `README.md` — platform overview and deployment model
- `docs/architecture/overview.md` — edge runtime, trust boundaries, and shared domain modules
- `docs/architecture/financial-ledger.md` — ledger principles, integer centavos, refund rows, and A1 idempotency
- `docs/architecture/pix-and-stock.md` — Pix lifecycle, stock reservations, SQLite CHECK guard, and Mercado Pago verification
- `docs/architecture/database-migrations.md` — Cloudflare D1 policies, foreign key cascade hazards, and safe recreation protocol
- `docs/architecture/testing-strategy.md` — Miniflare test harness and deterministic concurrency barriers
- `docs/ROLLBACK.md` — production incident recovery

## Operational Conventions

- Domain code and identifiers are in Portuguese (`pedido`, `comanda`, `reembolso`, `estoque`); money is integer cents (`*_centavos`) end to end.
- Every financial write or order mutation carries a client-generated `operationKey`, validated in `functions/lib/operacoes.ts`.
- Subsystems `ledger/`, `pix/`, and `paymentSync/` are accessed exclusively through their public facades.
- Tests use `node:test` + `node:assert/strict` in `tests/*.test.mjs` with deterministic barriers for race conditions.

## Engineering rules

<!-- aia-harness:fixed — non-negotiable; do not edit, reorder, or remove during enrichment -->

- Match the style of surrounding code; do not introduce new patterns unprompted.
- Test what can break — business rules, branching logic, money/security/auth, bug regressions; skip trivial getters, wrappers, config, presentational UI (rubric: `.claude/rules/05-testing.md`).
- Run the typecheck + test commands above before claiming work is complete.
- Never commit secrets: server secrets live in `.dev.vars` (local, gitignored) and Cloudflare Pages secrets (production); anything in `VITE_*` ships to the browser.
- Fix every compilation/syntax/lint error found during a session — regardless of whether you edited the file. Never leave the build broken or label errors "pre-existing, not related".

## graphify

This project may have a local knowledge graph at `graphify-out/`.
- For codebase queries, use `graphify query "<question>"`, `graphify path "<A>" "<B>"`, and `graphify explain "<concept>"`.
- If `graphify-out/wiki/index.md` exists, use it for architectural navigation.
- After modifying code, run `graphify update .` to keep the local graph current.
