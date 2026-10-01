---
name: targeted-repo-search
description: Use automatically whenever the task requires locating code, tracing behavior, finding references, understanding where a feature is implemented, investigating an error, or exploring an unfamiliar part of the repository. Portuguese triggers include: "onde está", "acha onde", "descobre por que", "onde é usado", "investiga esse erro". Prefer targeted search and the smallest relevant files over broad repository scans.
---

# Targeted Repository Search

Use evidence-driven exploration.

1. Start from identifiers directly related to the request:
   - component
   - endpoint
   - function
   - CSS class
   - error message
   - test
2. Search references before opening directories broadly.
3. Open the smallest relevant files first.
4. Follow imports, callers, and dependencies only when necessary.
5. Do not recursively inspect unrelated directories.
6. Do not reread unchanged files without a specific reason.
7. Stop exploring once enough evidence exists to act safely.

Prefer:

search -> relevant file -> necessary dependency/caller

Avoid:

repository-wide scan -> architecture essay -> implementation
