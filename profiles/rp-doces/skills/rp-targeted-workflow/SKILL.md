---
name: rp-targeted-workflow
description: Engineering workflow for rp-doces covering bug fixes, technical backlog investigations, audits, security hardening, minor improvements, and controlled refactoring. Use whenever tackling an engineering issue in rp-doces to work systematically through triage, targeted investigation, evidence gathering, report/approval, minimal implementation, proportional validation, review, and commit.
---

# RP-Doces Targeted Engineering Workflow

A disciplined, evidence-driven engineering workflow tailored for the R&P Doces codebase.

## Project Context & Critical Invariants

- **Stack**: React 18, TypeScript, Vite, Cloudflare Pages Functions, Cloudflare D1 (SQLite), Cloudflare R2, Mercado Pago (Pix).
- **Core Invariants**:
  - **Financial integrity & idempotency (A1)**: Ledger principles (additive refunds, settled amount conservation), state transitions, stable operation keys (see `docs/architecture/financial-ledger.md`).
  - **Stock consistency**: Strict reservation conversion/release, SQLite `CHECK` guard, no duplicate deductions (see `docs/architecture/pix-and-stock.md`).
  - **Security & CSRF**: Mutation endpoints enforce `sameOrigin()`; admin routes enforce `requireUser()`.
  - **Concurrency**: SQLite/D1 integrity constraints (`CHECK`, `UNIQUE`) and atomic batch updates; never read-then-write without atomic guards (see `docs/architecture/pix-and-stock.md`).
  - **Storefront UX & A11y**: Mobile-first, responsive, accessible SVG icons/aria labels, `prefers-reduced-motion` compliance.

---

## The 8 Workflow Stages

### Stage 1 — Triage
Before touching code or running broad searches:
1. Parse the exact requested objective, issue, or backlog item.
2. Identify the narrowest relevant domain (e.g., checkout, public polling, admin comanda, stock, image upload).
3. Prioritize existing project skills and established procedures over inventing ad-hoc procedures or custom workflows in the prompt.
4. Select **only** the auxiliary skills genuinely needed for the task (e.g., `targeted-repo-search`, `targeted-validation`, `money-test`, `new-migration`, `vercel-react-best-practices`). Do not activate irrelevant skills.

### Stage 2 — Targeted Investigation
Before planning or proposing any changes:
1. Inspect the **current** codebase state. Never assume historical issues or outdated problem descriptions still exist.
2. Activate `targeted-repo-search` for focused lookups starting from specific symbols, endpoints, or error codes.
3. Open only directly relevant files; traverse imports and callers strictly on demand.
4. Consult git history (`git log -S`, `git log -p`) only when essential to clarify recent design intent or identify prior fixes.
5. Distinguish active implementations from legacy or obsolete code.

### Stage 3 — Evidence
Before proposing any code modification:
1. Prove the root cause or current state with concrete evidence (exact file lines, queries, or test behaviors).
2. Clearly distinguish observed facts from hypotheses.
3. Reproduce bugs with a minimal test or script whenever feasible.
4. For visual or browser runtime behaviors, start the local server via `npm run dev` and inspect the real application.
5. **Early exit**: If the investigation proves the issue is already resolved or nonexistent, report the findings with evidence, produce zero code diff, and stop.

### Stage 4 — Report & Approval
When the prompt requests an investigation or alignment before editing:
1. Deliver a concise report detailing:
   - Root cause / Current behavior
   - Observed evidence and active flow
   - Concrete impact and prerequisites
   - Affected files
   - Minimal recommended fix
   - Relevant targeted tests and risks
2. Stop and wait for user approval before making any file changes.

### Stage 5 — Minimal Implementation
Once changes are approved:
1. Make the smallest safe diff that satisfies the requirement (`minimal-diff`).
2. Preserve existing APIs, contracts, unrelated behavior, and formatting.
3. Avoid opportunistic refactoring, unsolicited cleanup, or unnecessary new dependencies.
4. Do not alter visual appearance or styles unless the task explicitly requires it.

### Stage 6 — Proportional Validation
Apply targeted validation proportional to the scope and risk (`targeted-validation`):
- **Fundamental Rule**: Do NOT run the entire test suite (`npm test`) for localized changes.
- **Validation Matrix**:
  - *Localized backend/frontend change*: Run the specific test file (e.g., `node --test tests/<target>.test.mjs`) + typecheck (`npm run typecheck:frontend` or `:functions`) + `git diff --check`.
  - *UI / CSS*: Target UI test + visual verification via dev server.
  - *Money / Stock / Idempotency*: Use `money-test` harness and deterministic concurrency barriers (`barrier`).
  - *D1 Database Migration*: Delegate procedure and specific validations to the `new-migration` skill.
  - *Broad cross-cutting refactor or pre-release*: Run the full quality gate (`npm run build`, `npm run lint`, full test suite).
- **Zero-Tolerance**: Never ignore failing tests, never disable assertions to pass, never add unjustified linter suppressions, and never use `continue-on-error`.

### Stage 7 — Review
Before declaring the task complete:
1. Inspect `git diff` to verify only intended changes are present.
2. Confirm untouched files remain unaffected and formatting is clean.
3. Run `git diff --check` to catch whitespace anomalies or conflict markers.
4. State explicitly what was validated and what was not validated.

### Stage 8 — Commit
1. Do not commit or push without explicit user consent.
2. When authorized, use the project commit convention:
   ```
   rp-doces: <mensagem>
   ```

---

## Skill Composition Guide

Compose with existing project skills without duplicating their contents:

| Need | Reusable Skill |
| :--- | :--- |
| Code navigation & tracing | `targeted-repo-search` |
| Scope-proportional testing | `targeted-validation` |
| Financial, stock & concurrency tests | `money-test` |
| D1 SQL schema migrations | `new-migration` |
| React hooks & performance rules | `vercel-react-best-practices` *(when applicable)* |
| Visual UI design & layouts | `frontend-design` *(when applicable)* |
| Design & accessibility review | `web-design-guidelines` *(when applicable)* |
