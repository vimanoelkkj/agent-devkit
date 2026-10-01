---
description: TypeScript coding standards and anti-patterns
paths:
  - "**/*.ts"
  - "**/*.tsx"
---

# TypeScript — Coding Standards

**Sources:** Google TypeScript Style Guide · google/gts · antigravity.codes

## Anti-patterns

| Forbidden                                    | Alternative                                               |
| -------------------------------------------- | --------------------------------------------------------- |
| `any`                                        | Explicit types, `unknown` with narrowing, generics        |
| `Record<string, any>`                        | Domain-specific interfaces                                |
| Type assertion `as Foo` without narrowing    | Type guard `isFoo(x)` or narrowing with `instanceof`/`in` |
| `// @ts-ignore`                              | `// @ts-expect-error` with mandatory comment              |
| `==` for comparison                          | `===` always                                              |
| `!` non-null assertion without justification | Explicit check or `?.`                                    |
| File > 350 LOC                               | Split into smaller modules by responsibility              |
| Repeated magic strings                       | Constants or `as const` enum objects                      |
| `namespace`                                  | ES modules (`import`/`export`)                            |
| Numeric `enum`                               | `const` object with `as const` or string union            |

## Conventions

- `strict: true` in `tsconfig.json` — never disable
- Relative imports — no path alias is configured in `tsconfig.json`
- `type` for unions/intersections · `interface` for extensible objects
- Derived types: `ReturnType<typeof fn>`, `Parameters<typeof fn>`, `Awaited<T>`
- Hand-written type guards (`isX(value: unknown): value is X`) for runtime validation at external boundaries — Zod is not a dependency
- Public functions: always type return type explicitly
- Generics: descriptive name when not obvious (`TEntity`, not `T` for multiple type params)

## Tooling

- `tsc --noEmit` in the pipeline (no build step = pure type check)
- No ESLint in this project — `npm run typecheck` (frontend + functions tsconfigs) is the blocking gate
- Biome (`npm run lint`, `recommended` preset) reports issues but does not block CI or the Stop hook yet
- Prettier (`.prettierrc`), run on changed files only
