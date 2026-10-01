---
name: efficient-coding-workflow
description: Use automatically for any software development task involving implementation, debugging, refactoring, maintenance, code review, or repository changes. Portuguese triggers include: "corrige", "implementa", "refatora", "analisa esse código", "faz essa alteração". Prioritize minimal token usage, minimal tool calls, no routine progress narration, and concise final reporting without sacrificing correctness.
---

# Efficient Coding Workflow

Optimize for useful work per token.

- Do not repeat the user's request.
- Do not narrate routine progress or tool calls.
- Do not restate established project context.
- Inspect only files likely to affect the task.
- Prefer targeted searches over repository-wide exploration.
- Reuse existing project patterns instead of inventing abstractions.
- Avoid intermediate reports unless user input or approval is required.
- Do not explain obvious changes unless requested.
- Never sacrifice correctness, security, or required validation to save tokens.

At completion report only:
1. what changed
2. validation performed
3. actual remaining risks or blockers
