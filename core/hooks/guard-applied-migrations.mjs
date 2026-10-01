#!/usr/bin/env node
/**
 * PreToolUse guard (matcher "Edit|Write|MultiEdit"): refuse to modify a
 * migration that is already committed (`git ls-files` knows it). Applied
 * migrations are immutable — schema changes go in a NEW `NNNN_name.sql`.
 * Untracked migration files (the one being authored) remain editable.
 *
 * Exit 2 blocks the tool call; exit 0 allows it. Fails open (exit 0) when the
 * event is unreadable or git is unavailable, so it never blocks unrelated edits.
 */
import { execFileSync } from "node:child_process";
import path from "node:path";
import { parseHookEvent, readStdinRaw } from "./hook-io.mjs";

const event = parseHookEvent(readStdinRaw());
if (!event) process.exit(0);

const filePath = typeof event.tool_input?.file_path === "string" ? event.tool_input.file_path : "";
if (!filePath) process.exit(0);

// Purpose A (see .claude/rules/hooks-cwd-resolution.md): live session directory.
const cwdArg = typeof event.cwd === "string" && event.cwd ? event.cwd : "";
const projectDir = cwdArg || process.env.CLAUDE_PROJECT_DIR || process.cwd();

const rel = path.relative(projectDir, path.resolve(projectDir, filePath)).split(path.sep).join("/");
if (!/^migrations\/\d{4}_[^/]+\.sql$/.test(rel)) process.exit(0);

let tracked = false;
try {
  execFileSync("git", ["ls-files", "--error-unmatch", "--", rel], {
    cwd: projectDir,
    stdio: "ignore",
    windowsHide: true,
    timeout: 5000
  });
  tracked = true;
} catch {
  tracked = false; // untracked, or git unavailable -> allow
}

if (tracked) {
  process.stderr.write(
    `guard-applied-migrations: blocked — ${rel} is already committed and may be applied in ` +
      "production. Never edit an applied migration; create the next-numbered migration instead " +
      "(see migrations/CLAUDE.md).\n"
  );
  process.exit(2);
}

process.exit(0);
