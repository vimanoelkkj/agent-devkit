#!/usr/bin/env node
/**
 * PreToolUse guard (matcher "Bash"): block commands that write to the
 * PRODUCTION Cloudflare account — remote D1 writes/migrations/time-travel and
 * deploys. Read-only remote commands (e.g. `d1 migrations list --remote`) pass.
 * The user can still run a blocked command themselves with the `!` prefix.
 *
 * Exit 2 blocks the tool call (stderr is fed back to Claude); exit 0 allows it.
 * Fails open (exit 0) on unreadable input so a broken event never wedges Bash.
 */
import { parseHookEvent, readStdinRaw } from "./hook-io.mjs";

const event = parseHookEvent(readStdinRaw());
if (!event) process.exit(0);

const command = typeof event.tool_input?.command === "string" ? event.tool_input.command : "";
if (!/\bwrangler\b/.test(command)) process.exit(0);

const remoteD1Write =
  /\bd1\s+(?:execute|migrations\s+apply|time-travel\s+restore)\b/.test(command) &&
  /--remote\b/.test(command);
const deploy = /\bwrangler(?:\.cmd)?\s+(?:pages\s+deploy|deploy)\b/.test(command);

if (remoteD1Write || deploy) {
  process.stderr.write(
    "guard-d1-remote: blocked — this command writes to the production Cloudflare account " +
      "(remote D1 or deploy). Use `--local` for D1 work, and ask the user to run production " +
      "commands themselves with `! <command>` (see docs/ROLLBACK.md).\n"
  );
  process.exit(2);
}

process.exit(0);
