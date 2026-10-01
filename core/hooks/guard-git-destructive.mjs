#!/usr/bin/env node
/**
 * PreToolUse guard (matcher "Bash"): block git commands that publish or destroy
 * work — any `git push` (a push to main is a production deploy), `git reset
 * --hard`, and `git clean -f`. Complements the settings.json deny rules, which
 * only match command prefixes (they miss `git -C dir push`, trailing flags, or
 * chained commands). The user runs these themselves with the `!` prefix.
 *
 * Exit 2 blocks the tool call; exit 0 allows it. Fails open on unreadable input.
 */
import { parseHookEvent, readStdinRaw } from "./hook-io.mjs";

const event = parseHookEvent(readStdinRaw());
if (!event) process.exit(0);

const raw = typeof event.tool_input?.command === "string" ? event.tool_input.command : "";
// Ignore quoted text so a commit message mentioning "git push" is not blocked.
const command = raw.replace(/'[^']*'|"(?:\\.|[^"\\])*"/g, "''");

// `git` followed by optional global options (-C dir, -c k=v, --flag[=v]) then the subcommand.
const GIT = String.raw`\bgit(?:\s+-[Cc]\s+\S+|\s+--?[\w-]+(?:=\S+)?)*\s+`;
const push = new RegExp(`${GIT}push\\b`);
const resetHard = new RegExp(`${GIT}reset\\b[^|;&]*\\s--hard\\b`);
const cleanForce = new RegExp(`${GIT}clean\\b[^|;&]*\\s(?:-[a-zA-Z]*f[a-zA-Z]*|--force)\\b`);

const hit = push.test(command)
  ? "git push"
  : resetHard.test(command)
    ? "git reset --hard"
    : cleanForce.test(command)
      ? "git clean -f"
      : null;

if (hit) {
  process.stderr.write(
    `guard-git-destructive: blocked \`${hit}\` — it publishes or discards work (a push to main ` +
      "deploys to production). Ask the user to run it themselves with `! <command>`.\n"
  );
  process.exit(2);
}

process.exit(0);
