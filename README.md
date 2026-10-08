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
