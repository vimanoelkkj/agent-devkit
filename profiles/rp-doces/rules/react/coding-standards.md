---
description: React coding standards and anti-patterns
paths:
  - "**/*.tsx"
  - "**/*.jsx"
---

# React — Coding Standards

**Sources:** Airbnb React Style Guide · antigravity.codes · React official docs

## Anti-patterns

| Forbidden                                                       | Alternative                                                                             |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Inline functions in JSX on components that re-render frequently | Extract + `useCallback` when referential stability matters to dependents                |
| `key={index}` on dynamic lists                                  | Stable IDs from the data                                                                |
| `useEffect` for synchronous logic derived from state            | Derived state calculated inline or with `useMemo`                                       |
| Prop drilling > 2 levels                                        | React context (`CartContext`, `StoreThemeContext`) + pure modules — no state library    |
| Duplicated state (same data in two `useState`)                  | Single source of truth; derive the rest                                                 |
| Direct state mutation                                           | Always create a new object/array                                                        |
| Component grows hard to follow                                  | Extract sub-components or custom hooks — check your linter's configured line-limit gate |
| `any` in prop types                                             | Explicit interfaces                                                                     |
| Business logic inside the component                             | Custom hook (`use<Name>`)                                                               |
| `document.querySelector` in a React component                   | `useRef`                                                                                |

## Conventions

- Components: `PascalCase` · Custom hooks: `useCamelCase`
- Props interface named `<ComponentName>Props`
- One component per file with `export default function` (project convention); helpers and hooks use named exports
- Composition over inheritance — never `extends` on components
- `memo()` only when profiling confirms a re-render problem
- Accessibility: every interactive element has an `aria-label` or visible text

## Tooling

- Biome (`npm run lint`, `recommended` preset) flags exhaustive-deps and a11y issues (`useExhaustiveDependencies`, `useButtonType`, `noLabelWithoutControl`, ...); it reports but does not block yet — still check both by hand in review
- React DevTools Profiler to measure before optimizing
