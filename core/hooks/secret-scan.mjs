#!/usr/bin/env node
/**
 * PreToolUse guard: block an Edit/Write/MultiEdit/Bash whose payload looks like
 * a secret. Exit code 2 blocks the tool call; exit 0 allows it. Fails open on
 * unreadable input. Wired in .claude/settings.json under the
 * "Edit|Write|MultiEdit" and "Bash" matchers.
 */
import { parseHookEvent, readStdinRaw } from "./hook-io.mjs";

const event = parseHookEvent(readStdinRaw());
if (!event) process.exit(0);

const ti = event.tool_input ?? {};
const edits = Array.isArray(ti.edits) ? ti.edits.map(e => e?.new_string) : [];
const text = [ti.content, ti.new_string, ti.command, ...edits]
  .filter(v => typeof v === "string")
  .join("\n");

const patterns = [
  /\b(?:APP_USR|TEST)-\d{10,}-\d{6}-[0-9a-f]{32}-\d+\b/, // Mercado Pago access token
  /AKIA[0-9A-Z]{16}/, // AWS access key id
  /-----BEGIN (?:RSA|EC|OPENSSH|PGP|DSA) PRIVATE KEY-----/,
  /sk-(?:ant-|proj-)?[A-Za-z0-9_-]{20,}/, // OpenAI / Anthropic style secret
  /ghp_[A-Za-z0-9]{36}/, // GitHub PAT
  /xox[baprs]-[A-Za-z0-9-]{10,}/, // Slack token
  /AIza[0-9A-Za-z_-]{35}/ // Google API key
];

for (const re of patterns) {
  if (re.test(text)) {
    process.stderr.write(
      "secret-scan: refusing an apparent secret. Server secrets belong in .dev.vars (local, " +
        "gitignored) or `wrangler pages secret put` (production) — never in source, commands or VITE_* vars.\n"
    );
    process.exit(2);
  }
}

process.exit(0);
