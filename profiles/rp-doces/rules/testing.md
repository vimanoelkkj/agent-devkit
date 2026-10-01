---
paths:
  - "**/*"
---

# Testing

Test what can break, not every function. Full rubric: `.claude/rules/05-testing.md`.

- Test: branching logic (CC ≥ 2) that also hits ≥1 of business rules, money/security/auth, algorithms, high fan-in, hotspots, blast radius, or bug regressions.
- Skip (or integration-only): trivial getters/wrappers, pass-through, config, presentational UI, generated code.
- Run `npm run test` before claiming done.
