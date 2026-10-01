---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.mts"
  - "**/*.cts"
---

# TypeScript rules

- `npm run typecheck` is the blocking gate. `npm run lint` (Biome) reports issues but is not blocking yet.
- Format only files you changed: `npx prettier --write <files>`.
- Typecheck: `npm run typecheck`. Avoid `any`; prefer explicit types at boundaries.
- Keep modules small and single-purpose. React components use `export default function`; other modules use named exports.
- Do not add dependencies without a clear need.
