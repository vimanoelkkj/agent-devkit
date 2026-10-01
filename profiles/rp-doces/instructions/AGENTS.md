# Agent Instructions

Talk to the user in Brazilian Portuguese (pt-BR). Keep code, identifiers, commands, SQL, commit messages, and project instruction files in English.

## Automatic skill usage

Automatically invoke every relevant project skill before acting. If multiple skills apply, combine them.
Do not wait for the user to name a skill explicitly.

Project skills live under `.agents/skills/`. Prefer skill-guided, targeted investigation over broad repository scans.

## Working style

- Make the smallest safe change that satisfies the request.
- Preserve unrelated behavior and formatting.
- Prefer targeted validation during iteration.
- Follow the repository's documented final validation gate before claiming completion.
- Reuse established project patterns instead of inventing new abstractions.
- Do not narrate routine progress or repeat already established context.
- Never suppress or bypass validation failures.

Use `README.md` and `docs/architecture/` as the architectural and technical source of truth.
