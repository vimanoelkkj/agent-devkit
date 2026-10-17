# Agent DevKit

**Agent DevKit** is a lightweight, declarative manager for AI coding agent environments, skills, and hooks across software projects.

It establishes a single source of truth for agent capabilities while allowing project-specific customizations, immutable third-party dependency pinning, and safe physical materialization into consumer repositories.

---

## Core Concepts

The architecture separates responsibilities into four clear layers:

1. **Core (`core/`)**
   - Reusable, project-agnostic skills and hooks.
   - The DevKit repository is the canonical source of truth for these components.
   - Core Skills: `targeted-repo-search`, `targeted-validation`, `minimal-diff`, `efficient-coding-workflow`.
   - Core Hooks: `hook-io.mjs`, `session-scratch.mjs`, `secret-scan.mjs`, `guard-git-destructive.mjs`, `large-file-warning.mjs`, `set-files-changed.mjs`, `guard-applied-migrations.mjs`.

2. **Profiles (`profiles/<name>/`)**
   - Project-specific extensions and bundled compositions.
   - Houses components specific to a particular repository or domain (e.g., `profiles/rp-doces/skills/rp-targeted-workflow`, `profiles/rp-doces/hooks/guard-d1-remote.mjs`).
   - Profile definitions (`profile.json`) curate skills, hooks, and configurations for downstream projects.

3. **Third-Party Registry (`registry/third-party.json`)**
   - Catalog of external components pinned to immutable, full 40-character Git commit hashes.
   - Adheres to a strict **data-only policy**: third-party dependencies are cataloged for declarative installation without arbitrary code execution during synchronization.
   - Fetched safely via native `git.exe` into an isolated temporary sandbox with custom hooks disabled (`core.hooksPath=""`).
   - Validates `git rev-parse HEAD` against the pinned commit, verifies subpaths, and enforces security constraints (anti-traversal, reparse-point rejection, script/binary extension blocking).

4. **Consumer Manifest & Lockfile (`agent-devkit.json` & `agent-devkit.lock`)**
   - Consumer projects declare desired profile, skills, and hooks in `agent-devkit.json`.
   - The engine generates `agent-devkit.lock` recording exact SHA-256 checksums, full commit references, repository origin, and subpaths for every materialized file.
   - Physical copies are materialized independently into agent discovery directories (e.g., `.agents/skills`, `.claude/skills`, and `.claude/hooks`).

---

## Directory Layout

```text
agent-devkit/
├── bin/
│   └── agent-devkit.ps1          # Command-line entry point
├── core/
│   ├── hooks/                    # Project-agnostic core hooks
│   │   ├── guard-applied-migrations.mjs
│   │   ├── guard-git-destructive.mjs
│   │   ├── hook-io.mjs
│   │   ├── large-file-warning.mjs
│   │   ├── secret-scan.mjs
│   │   ├── session-scratch.mjs
│   │   └── set-files-changed.mjs
│   └── skills/                   # Project-agnostic core skills
│       ├── efficient-coding-workflow/
│       ├── minimal-diff/
│       ├── targeted-repo-search/
│       └── targeted-validation/
├── profiles/
│   └── rp-doces/                 # Profile for R&P Doces project
│       ├── hooks/                # Profile-specific hooks
│       │   └── guard-d1-remote.mjs
│       ├── skills/               # Profile-specific skills
│       │   ├── money-test/
│       │   ├── new-migration/
│       │   └── rp-targeted-workflow/
│       └── profile.json          # Profile specification
├── registry/
│   └── third-party.json          # External component registry
├── src/
│   └── DevKit.Engine.psm1        # Core engine module (PowerShell 5.1 & 7+)
├── tests/
│   ├── devkit-engine.test.ps1    # Automated engine test suite
│   └── rp-doces-manifest.json    # Parity test manifest fixture
├── .gitignore
├── LICENSE                       # MIT License
└── README.md
```

---

## CLI Usage

### Linux (Bash + Node.js 24)

The independent `bin/agent-devkit.mjs` CLI requires Node.js 24+ and Git on
`PATH`. It has no npm dependencies and does not invoke PowerShell. The
existing PowerShell CLI and engine are unchanged.

Start with this read-only preview in Bash:

```bash
cd ~/dev/agent-devkit
node --version
node bin/agent-devkit.mjs profile show chopp-delivery
node bin/agent-devkit.mjs sync \
  --profile chopp-delivery \
  --project-dir "$HOME/dev/chopp-delivery" \
  --dry-run
```

The `chopp-delivery` profile is restricted by the Node engine to the exact
GitHub origin `vimanoelkkj/chopp-delivery` (HTTPS or SSH) and requires the
`package.json` marker. It contains only `efficient-coding-workflow`,
`minimal-diff`, `targeted-repo-search` and `targeted-validation`. It creates
physical copies under `.agents/skills` and enables no Claude hooks, settings,
R&P Doces components or third-party Skills. Git is used only to read local
origin configuration, with includes disabled; no network is accessed.

After reviewing the dry-run and obtaining authorization for the real sync:

```bash
node bin/agent-devkit.mjs sync \
  --profile chopp-delivery \
  --project-dir "$HOME/dev/chopp-delivery"
node bin/agent-devkit.mjs verify \
  --profile chopp-delivery \
  --project-dir "$HOME/dev/chopp-delivery"
```

`verify` is always read-only and can also be run before installation; it
returns exit code 1 when files or the lock are missing or out of sync.
`sync --dry-run` writes nothing, including no directories, lock, transaction
guard or Git exclude entries. Exit codes are 0 for successful sync/preview
or verification, 1 for errors/failed verification, and 2 for a blocked sync
(including dry-run). JSON output lists each target's state and the lock path.

The Node implementation supports local core and profile Skills, `skills`,
legacy `components.core/profile/skills`, and both array and object forms of
`targets`. Supported Skills destinations are `.agents/skills` and
`.claude/skills`; absent targets default to both, as in PowerShell. The Chopp
profile explicitly selects only `.agents/skills`. Explicit `--manifest-file`
overrides `--profile`, which overrides the project's `agent-devkit.json`,
following the current engine's resolution order. A manifest/profile mismatch
is refused. Manifests are never created or rewritten.

Lock placement and schema follow the existing engine: if the project has
`agent-devkit.json`, use its `agent-devkit.lock`; otherwise use
`state/<profile>/agent-devkit.lock` in this DevKit. The latter is the sole
managed-state write outside the consumer project; Skills destinations cannot
escape the project. Locks retain `lockfileVersion: "1.0.0"`,
`profile: "<name>@1.0.0"`, `generatedAt`, component maps, local provenance
(`core` or `profile:<name>`), Skill version and per-file lowercase SHA-256.
An unchanged sync preserves the lock bytes and timestamps. State is shared
per profile as in PowerShell; use one checkout per profile with external
state, or project manifests for separate checkout locks.

All requested files are validated before writes. Local modifications,
conflicts and untracked files in selected Skills targets block the entire
sync; nothing is pruned. Retired locked Skills/files require explicit
reconciliation. Traversal, absolute/Windows paths, symlinks (including dangling
links and ancestors), hardlinks and special files are rejected. Sources are
copied as static bytes: no Skill, hook, project script or downloaded code is
executed. Nonempty third-party declarations, rules, agents, configs and
overlays fail explicitly. Unsupported CLI options,
including force, auto-discovery, custom state directories and Git exclude
mutation, also fail rather than silently succeeding.

Writes use exclusive temporary files, atomic per-file replacement and a
project transaction guard; the lock is committed last. Recoverable I/O
failures roll back prior writes, file modes and created directories. Rollback
refuses to overwrite concurrent edits and reports incomplete recovery.
This is not a crash-safe multi-file transaction: power loss, SIGKILL,
filesystem failure or malicious concurrent directory replacement may require
manual recovery. Do not run Node and PowerShell syncs simultaneously or
modify targets during sync. A leftover `.agent-devkit-sync` guard must be
reviewed and removed manually after ensuring no sync is running. SHA-256
detects drift; it does not authenticate a tampered DevKit or lockfile.

Run the Linux suite without installing dependencies:

```bash
cd ~/dev/agent-devkit
node --test tests/devkit-linux.test.mjs
node --test tests/devkit-linux-resources.test.mjs
git diff --check
```

Tests use only temporary consumer projects, including a temporary Git origin
for the Chopp profile. They cover installation, SHA-256/provenance, existing
lock compatibility, verification, read-only dry-run, idempotence, conflicts,
unsupported resources, traversal, links, special files, concurrency checks
and rollback for injected write/rename failures. They never sync the actual
Chopp Delivery checkout. The existing PowerShell suite requires Windows
facilities such as `cmd /c mklink /J`; it cannot complete unchanged on Linux.

### Linux local resources (stage 2A)

The Linux engine uses one read-only plan and one rollback-capable transaction
for Skills, local Hooks and local instructions. Each Skills destination is an
independent physical copy and is checked separately. A conflict in any selected
destination blocks the entire operation, including the lock update. Nothing is
pruned or merged automatically. The existing `chopp-delivery` profile is
unchanged: four core Skills, `.agents/skills` only, no Hooks or instructions.
This capability does not opt that consumer into any additional resources.

Supported declarations retain the PowerShell JSON schema: arrays of names,
not objects with invented `source`, `target`, or execution fields. For example,
an explicitly configured disposable profile/manifest can declare:

```json
{
  "profile": "example",
  "skills": ["minimal-diff"],
  "hooks": ["guard-git-destructive.mjs"],
  "instructions": ["AGENTS.md", "CLAUDE.md"],
  "targets": {
    "skills": [".agents/skills", ".claude/skills"],
    "hooks": [".claude/hooks"]
  }
}
```

This example is not installed or activated by adding documentation. It requires
an existing selected profile and explicit local instruction sources. Sources
resolve first under `profiles/<selected-profile>/<category>/<name>`, then under
`core/<category>/<name>`, matching PowerShell precedence. No other profile is
searched. Provenance records the actual source as `profile:<name>` or `core`.
Hooks specific to `rp-doces` are never fallback sources for another profile.
No new Hooks or instruction files are bundled in this stage.

The supported Linux resource subset is deliberately bounded:

| Resource | Manifest declaration | Source directory | Allowed destination |
| --- | --- | --- | --- |
| Skills | `skills`, `components.core/profile/skills` | `skills/<name>/` | `.agents/skills/<name>/`, `.claude/skills/<name>/` |
| Static Hooks | `hooks`, `components.hooks` | `hooks/<name>.mjs` | `.claude/hooks/<name>.mjs` |
| Instructions | `instructions` | `instructions/AGENTS.md` or `instructions/CLAUDE.md` | Root `AGENTS.md` or `CLAUDE.md` |

Hook names are single basenames matching letters/digits, hyphens and
underscores with a `.mjs` extension. Other extensions, nested resource names,
custom instruction targets, unknown target categories and declaration objects
fail explicitly. `targets.hooks` defaults to `.claude/hooks`. Legacy target
arrays classify entries containing `hook` as Hook targets; all entries still
must match the allowlist. Resource-only profiles do not require a Skill.

Existing unmanaged `AGENTS.md`, `CLAUDE.md` and requested Hook files block sync
with `untracked`, even if byte-identical to the source. The engine does not
adopt or merge them and has no force flag. Existing managed files can only be
updated while their bytes still match their previous locked SHA-256. Otherwise
the whole sync is blocked as `modified` or `conflict`. To preserve handwritten
instructions, omit that declaration and review any future integration manually.
Removing a locked resource declaration requires explicit reconciliation; it
does not silently discard provenance or delete consumer files.

Instruction distribution only places the explicitly requested files. It makes
no claim that Codex, Claude Code and Antigravity discover the same files or
apply the same precedence. Harness discovery and configuration require separate
verification and authorization; no discovery rules are installed here.

Hook distribution, registration in a harness, and actual execution are three
different operations. This engine implements only distribution as static data
with mode `0644` for new files. It never imports or executes Hooks, never adds
event registrations, never creates or edits `.claude/settings.json`, and never
modifies `.gitignore` or `.git/info/exclude`. It does not create or activate
`guard-cloudflare-remote.mjs`.

Lockfile version remains `1.0.0`. Skills continue using
`skills.<name>.files.<relative-path>.sha256`; local single-file resources use
`hooks.<name>` and `instructions.<name>` with `{ "source": "core", "sha256": "..." }`
or the selected profile provenance. Existing metadata is retained, and unchanged
compatible locks retain their exact bytes (including BOM/format) and timestamps.
Changes to any supported resource map update the lock last. Invalid versions,
resource maps, hashes, names and foreign-profile provenance fail before writing.
Local third-party downloads, rules, agents, configs and overlays remain unsupported.

The stage 2A suite exercises mixed-resource transactions, links, conflicts,
resource isolation and actual bidirectional lock interoperability with the
unchanged PowerShell engine. `pwsh` is required for the two cross-engine tests;
if absent, those tests explicitly report skipped coverage. Contract compatibility
does not imply identical security policy: Linux restricts destinations and refuses
unmanaged instructions/Hooks even where PowerShell would adopt matching bytes.
The complete legacy Windows suite still needs Windows junction facilities.

The CLI script `bin/agent-devkit.ps1` supports PowerShell 7+ (`pwsh`) as well as Windows PowerShell 5.1 (`powershell.exe`).

### 1. Catalog & Skill Management

Query and inspect all cataloged skills (core, profile-specific, and third-party):

```powershell
# List all skills with ownership, state, policy, and profile associations
.\bin\agent-devkit.ps1 skill list

# Inspect detailed metadata, provenance, ref, and description for a specific skill
.\bin\agent-devkit.ps1 skill info caveman
.\bin\agent-devkit.ps1 skill info rp-targeted-workflow
```

### 2. Profile Composition Management

Manage project profiles declaratively:

```powershell
# List available profiles with component counts
.\bin\agent-devkit.ps1 profile list

# Show detailed profile composition (declared and available skills, hooks)
.\bin\agent-devkit.ps1 profile show rp-doces

# Add a core, profile-specific, or third-party skill to a profile
.\bin\agent-devkit.ps1 profile add rp-doces caveman

# Remove a skill declaration from a profile (preserves local files and locks)
.\bin\agent-devkit.ps1 profile remove rp-doces caveman
```

### Automatically discover a consumer checkout

The `rp-doces` profile declares the expected GitHub repository and safe,
bounded search roots relative to the **current user's** home directory:
`$HOME/dev` and `$HOME/Projetos`. Discovery inspects only each root and its
immediate children, verifies the exact Git origin plus the `package.json`
marker, and refuses to guess if multiple checkouts match. Nothing is written
until normal `sync` is executed. `verify` remains read-only.

```powershell
# From the local agent-devkit directory, at work or at home:
.\bin\agent-devkit.ps1 sync -Profile rp-doces -AutoDiscover -DryRun
.\bin\agent-devkit.ps1 sync -Profile rp-doces -AutoDiscover
.\bin\agent-devkit.ps1 verify -Profile rp-doces -AutoDiscover
```

To search another directory, use `-SearchRoots` explicitly (one-level scan).

```powershell
.\bin\agent-devkit.ps1 sync -Profile rp-doces -AutoDiscover -SearchRoots 'D:\code' -DryRun
```

Use `-ProjectDir` instead if multiple checkouts match. `-AutoDiscover` cannot
be combined with `-ProjectDir`, and requires `-Profile`. It never searches
all drives, relies on the folder name, calls GitHub's network, or modifies a
repository merely to find it. HTTPS, SCP-style SSH and `ssh://git@github.com/`
origin URLs are accepted. Other profiles must declare their own
`discovery.githubRepository` and search roots to opt in.

### 3. Overview of Available Components (Legacy)

Inspect a high-level overview of core skills/hooks, profiles, and third-party registry:

```powershell
.\bin\agent-devkit.ps1 list
```

### 4. Verify Consumer Project Integrity

Compare the files in a consumer repository against its manifest/lockfile:

```powershell
.\bin\agent-devkit.ps1 verify -ProjectDir "C:\path\to\project"
```

The engine classifies each component file into one of the following states:
- `synced`: file exists on disk and exactly matches the expected SHA-256 hash.
- `missing`: file is expected by manifest/lock but absent on disk.
- `modified`: file was altered locally in the consumer project.
- `update_available`: upstream source changed while consumer has unmodified older version.
- `conflict`: upstream source changed and consumer also modified local file.
- `untracked`: untracked component found in target directories.

### 3. Synchronize Project Dependencies

Materialize missing components into the target project safely:

```powershell
# Preview actions without writing any file
.\bin\agent-devkit.ps1 sync -ProjectDir "C:\path\to\project" -DryRun

# Materialize components and generate/update agent-devkit.lock
.\bin\agent-devkit.ps1 sync -ProjectDir "C:\path\to\project"
```

---

## Third-Party Component Pipeline & Security Model

Third-party dependencies (such as external community skills) are managed through declarative pinning and a multi-layered security pipeline:

```text
registry/third-party.json
         ↓
Isolated temporary sandbox (%TEMP%\devkit-tp-git-<guid>)
         ↓
git.exe shallow fetch (-c core.hooksPath="")
         ↓
Deterministic commit validation (git rev-parse HEAD == expected_commit_sha)
         ↓
Package security audit:
  - Subpath existence & path-traversal prevention
  - Reparse point / directory junction / symlink rejection
  - Data-only extension allowlist (.md, .txt, .json, .yaml, .yml)
  - Forbidden extension blocklist (.exe, .bat, .ps1, .sh, .js, .mjs, etc.)
         ↓
SHA-256 hash calculation of staging tree
         ↓
Materialization into consumer directories (.agents/skills, .claude/skills)
         ↓
Lockfile update (agent-devkit.lock with full 40-char SHA & file digests)
         ↓
Sandbox cleanup (guaranteed in finally block)
```

### Frontend design (R&P Doces)

`frontend-design` comes from `anthropics/skills` as an immutable, data-only
third-party dependency (Apache-2.0). The `rp-doces` profile opts in.

After pulling Agent DevKit, run these commands in its repository:

```powershell
.\bin\agent-devkit.ps1 skill info frontend-design
.\bin\agent-devkit.ps1 profile show rp-doces
.\bin\agent-devkit.ps1 sync -Profile rp-doces -ProjectDir "C:\path\to\rp-doces" -DryRun
.\bin\agent-devkit.ps1 sync -Profile rp-doces -ProjectDir "C:\path\to\rp-doces"
.\bin\agent-devkit.ps1 verify -Profile rp-doces -ProjectDir "C:\path\to\rp-doces"
```

When a consumer has its own `agent-devkit.json`, also declare
`frontend-design` in `thirdPartySkills`; explicit manifests override profile
composition. The engine refuses to overwrite locally changed files.

For R&P Doces, preserve existing Fraunces/Manrope type, CSS theme tokens,
layouts and functionality. Use visual comparison and an approval-first
approach before implementing small refinements.

### Verified Integrations

- **`caveman`**: Verified integration against `JuliusBrussee/caveman` at commit `f5d729488caa8f6a5b6c8086fe2cccd3e8a63f91`, subpath `skills/caveman`.
- **Note on `graphify`**: Upstream `Graphify-Labs/graphify` generates skills dynamically via Python tooling (`tools/skillgen/gen.py`) rather than storing static directories. Integration requires generator pipeline support and is deferred to a future milestone.

---

## Safety Guarantees & Contract Separation

The DevKit architecture strictly separates operations:
- **`verify`**: Detects and reports discrepancies and drift.
- **`sync`**: Materializes components only when safe. **Never overwrites local modifications**. If any local file is modified (`status: modified` or `conflict`), `sync` refuses to overwrite it, protects the local customization, and issues a warning. There is deliberately **no `-Force` bypass** in `sync`.
- **`restore`**: Explicit future operation planned for restoring or discarding local changes intentionally.
- **Dry-Run Support**: All verification and sync routines can run in read-only preview mode (`-DryRun`).
- **Zero Arbitrary Execution**: Dependency resolution and file materialization operate purely on static files and SHA-256 hashes without running external scripts or remote evaluators (`irm | iex`).
- **Multi-Target Materialization**: Supports writing identical physical copies across `.agents/skills`, `.claude/skills`, and `.claude/hooks` to cleanly support multiple agent ecosystems without symlink/junction instability on Windows.

---

## Running Tests

Execute the automated test suite to verify SHA-256 hashing, component resolution (skills + hooks), dry-run safety, modification protection, and the absence of overwrite bypasses:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tests\devkit-engine.test.ps1
```

---

## License

MIT (c) 2026
