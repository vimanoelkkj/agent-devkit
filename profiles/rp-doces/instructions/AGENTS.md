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

## Execution autonomy and approval granularity

Approval is stage-level, not command-level. Never convert an already approved workflow into a sequence of per-command permission prompts.

Once a task or stage has been approved by the user, execute autonomously all routine, non-destructive commands necessary to complete it, including:
- Reading and searching files;
- Repository inspection (`git status`, `git diff`, `git log`, `git show`, `git grep`, `git ls-files`, `git rev-parse`, and other read-only queries);
- Targeted test execution;
- Typechecking, linting, formatting checks, and project builds;
- Validation gates prescribed by workflows;
- Temporary, non-destructive sandbox operations.

Do not prompt for confirmation command-by-command when these operations are already part of an approved task.

Continue requiring explicit approval before high-impact or destructive operations, specifically:
- History rewrites;
- Force pushes;
- Destructive deletion of files or data outside the approved scope;
- Production or remote database mutations;
- Deployment or release publication;
- Installing or executing unreviewed external code;
- Material expansion of the originally approved scope.

Use `README.md` and `docs/architecture/` as the architectural and technical source of truth.
