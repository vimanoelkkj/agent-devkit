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
   - Catalog of external components pinned to immutable Git commits or release tags.
   - Adheres to a strict **data-only policy**: third-party dependencies are cataloged for declarative installation without arbitrary code execution during synchronization.

4. **Consumer Manifest & Lockfile (`agent-devkit.json` & `agent-devkit.lock`)**
   - Consumer projects declare desired profile, skills, and hooks in `agent-devkit.json`.
   - The engine generates `agent-devkit.lock` recording exact SHA-256 checksums and source origins for every materialized file.
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

### 1. List Available Components

Inspect all cataloged core skills, core hooks, profile-specific skills/hooks, and registered third-party components:

```powershell
.\bin\agent-devkit.ps1 list
```

### 2. Verify Consumer Project Integrity

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
