---
name: targeted-validation
description: Use automatically whenever code or configuration is changed and validation, testing, linting, typechecking, building, formatting, regression checking, or verification may be needed. Portuguese triggers include: "testa isso", "valida", "confere se passou", "roda só o necessário", "verifica regressão". Prefer the smallest meaningful checks during iteration and the repository's required final validation gate before completion.
---

# Targeted Validation

Validation must be proportional to the change.

During iteration:

- CSS or visual change -> relevant formatter/linter and targeted UI verification.
- Isolated utility -> targeted unit test.
- Component behavior -> relevant component or UI test.
- TypeScript logic -> targeted tests and typecheck when useful.
- Backend endpoint -> endpoint-specific tests.
- Security-sensitive code -> targeted security and regression tests.

Do not repeatedly run the full test suite while iterating unless broad impact requires it.

Before completion, obey the repository's documented validation gate.

Do not suppress, bypass, or ignore failures.
