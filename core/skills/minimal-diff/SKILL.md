---
name: minimal-diff
description: Use automatically for any task that modifies existing code, configuration, tests, styles, documentation, or project files. Portuguese triggers include: "mexe só nisso", "sem mexer no resto", "correção mínima", "não refatora", "altera só esse trecho". Make the smallest safe change that satisfies the request, preserve unrelated behavior, and avoid unrequested refactors, renames, reformatting, or adjacent cleanup.
---

# Minimal Diff

- Modify only code required by the task.
- Preserve unrelated behavior and formatting.
- Do not refactor adjacent code unless correctness requires it.
- Do not rename unrelated identifiers.
- Do not reorganize files without a concrete need.
- Reuse existing utilities, components, and patterns.
- Avoid abstractions for one-off behavior.
- Remove only artifacts introduced by the current change.
- Preserve backward compatibility unless explicitly asked otherwise.

If a broader improvement is useful but unnecessary, mention it instead of implementing it.
