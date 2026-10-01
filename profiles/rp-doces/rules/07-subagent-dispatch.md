---
paths:
  - "**/*"
---

# Subagent Dispatch

## Rule

This project has one project agent, `money-path-reviewer` (`.claude/agents/`). Dispatch it
after changing money, stock or idempotency code (the paths in its description) and before
committing such a change.

For everything else there is no project specialist:

1. Use a namespaced plugin agent when one clearly fits — e.g. `feature-dev:code-explorer`
   (map unfamiliar code), `feature-dev:code-architect` (design), `pr-review-toolkit:code-reviewer`
   (general review), `pr-review-toolkit:silent-failure-hunter` (swallowed errors / fallbacks).
2. Otherwise use `general-purpose`.
3. Pass the exact name as `subagent_type`.

## Superpowers bridging

When a superpowers skill example shows `general-purpose`, keep it unless the task is a
money/stock/idempotency review (→ `money-path-reviewer`) or a namespaced plugin agent above
clearly covers it.

## Dispatch mechanics

- **Parallel by default** — 2+ independent domains → one agent per domain, all
  dispatched **in the same message** (separate messages run sequentially).
  Sequential only when A's output feeds B. Never two agents writing the same file.
- **Self-contained prompt** — a subagent inherits none of this conversation: give it
  scope, goal, constraints, and the expected output shape. It may also lack MCP servers
  you have — fetch what it needs yourself and paste the result into its prompt.
