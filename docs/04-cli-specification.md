# FlutterX — CLI Specification

> **Document status:** Draft v1.0 · Design phase
> **Audience:** Implementers of `flutterx_cli`; users reading reference docs
> **Related docs:** [03-sdk-intelligence.md](03-sdk-intelligence.md) · [05-storage-design.md](05-storage-design.md)

---

## 1. Conventions

### 1.1 General syntax

```
flutterx <command> [subcommand] [arguments] [--flags]
```

- **Version specifiers** accepted anywhere a `<version>` is expected: exact (`3.22.2`), partial (`3.22` → latest patch), channel (`stable`, `beta`, `master`), or `latest`.
- All commands support: `--help`, `--verbose`, `--json` (machine-readable output, stable schema), `--no-color`.
- Mutating commands support `--dry-run` where meaningful.
- Interactive prompts appear only on a TTY; in CI (non-TTY) prompts become failures with a documented exit code, unless `--yes`.

### 1.2 Exit codes (public contract)

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic/unexpected failure |
| 2 | Usage error (bad arguments) |
| 10 | Network failure |
| 11 | Resolution conflict (no candidate satisfies constraints) |
| 12 | Low-confidence resolution refused in non-interactive mode |
| 13 | Denied by policy (all candidates denied, or a specific version denied — e.g. retracted without `--force`) |
| 14 | Version not found in registry |
| 15 | Storage/integrity failure (repair suggested) |
| 16 | Upgrade blocked (advisor verdict) |
| 17 | Refused: resource still in use (e.g. `remove` while projects reference the version) |
| 20 | Passthrough: exit code of proxied `flutter`/`dart` process |

### 1.3 Error message format

```
✗ FX-SOLVE-001: pinned version 3.21.9 not found in registry.
  → flutterx list --remote 3.21    # see available 3.21.x releases
  → flutterx cache refresh         # refresh registry snapshot
```

Every error: stable code, one-line cause, concrete next actions.

---

## 2. Command Tree Overview

| Command | Purpose | Mutates |
|---|---|---|
| `install` | Provision an SDK version into the store | store |
| `remove` | Delete an SDK version from the store | store |
| `use` | Pin a project to a version | project |
| `resolve` | Run SDK Intelligence, pin the result | project (+store) |
| `recommend` | Show recommendation without applying | — |
| `current` | Show active SDK for this context | — |
| `list` | List installed / available SDKs | — |
| `doctor` | Diagnose environment (read-only) | — |
| `repair` | Diagnose and fix | store/project |
| `upgrade` | Advise/apply SDK upgrade | project (+store) |
| `cache` | Inspect/refresh/GC storage | store |
| `shell` | Subshell with a chosen SDK on PATH | — |
| `workspace` | Monorepo management | workspace |
| `run` / `build` / `test` / `pub` | Proxy to resolved SDK | project (indirect) |
| `config` | Read/write global config | config |

---

## 3. Commands

### 3.1 `flutterx install`

Provision an SDK into the global store (does **not** pin any project).

**Syntax**
```
flutterx install <version> [--force] [--skip-artifacts] [--precache <platforms>]
```

**Arguments & flags**

| Name | Description |
|---|---|
| `<version>` | Required. Exact, partial, or channel specifier |
| `--force` | Reinstall even if present; allows retracted versions |
| `--skip-artifacts` | Worktree only; artifacts fetched lazily on first run |
| `--precache <p>` | Comma list forwarded to `flutter precache` (e.g. `android,ios`) |

**Examples**
```
$ flutterx install 3.22.2
⠸ Fetching tag 3.22.2 into shared repo…        (2.1s — objects mostly present)
⠸ Creating worktree…                            (0.8s)
⠸ Linking engine artifacts (3 shared, 1 new)…   (11.4s)
✓ Flutter 3.22.2 (Dart 3.4.3) installed — 214 MB added (1.9 GB shared)

$ flutterx install 3.22
✓ 3.22 → 3.22.2 (latest patch)
✓ Flutter 3.22.2 already installed — nothing to do
```

**Errors**

| Condition | Code | Behavior |
|---|---|---|
| Unknown version | 14 | Suggest close matches + `cache refresh` |
| Network down, objects missing | 10 | Resumable; re-run continues from journal |
| Retracted version without `--force` | 13 | Explain retraction reason |
| Disk full | 15 | Report needed vs available; suggest `cache gc` |

---

### 3.2 `flutterx remove`

**Syntax**
```
flutterx remove <version> [--yes]
```

**Behavior:** refuses (exit 17 — still in use) if any known project lock references the version — lists the projects; `--yes` skips only the confirmation, not the reference check. Removes the worktree; shared git objects and artifacts are reclaimed later by `cache gc` (reference-counted).

**Example**
```
$ flutterx remove 3.19.6
✗ 2 projects still pinned to 3.19.6:
    ~/work/app-legacy
    ~/work/app-kiosk
  Re-pin them first (flutterx use/resolve) or pass --force to break links.
```

---

### 3.3 `flutterx use`

Pin the current project explicitly (the manual counterpart of `resolve`).

**Syntax**
```
flutterx use <version> [--pin|--policy <channel>] [--no-install]
```

| Flag | Description |
|---|---|
| `--pin` | (default) write exact version to `flutterx.yaml` |
| `--policy <c>` | write channel policy instead of exact pin (e.g. `stable` → track latest stable on each `resolve`) |
| `--no-install` | write config only; provision later |

**Example**
```
$ flutterx use 3.22.2
✓ Installed (already present)
✓ flutterx.yaml written  (flutter: 3.22.2)
✓ .flutterx/resolution.lock written
✓ .flutterx/sdk → ~/.flutterx/versions/3.22.2
ℹ Add .flutterx/sdk to .gitignore (resolution.lock should be committed)
```

**Errors:** unknown version → 14; not a Dart/Flutter project dir → 2 (with cwd shown).

---

### 3.4 `flutterx resolve` / `flutterx recommend`

The intelligence entry points (full pipeline in [03-sdk-intelligence.md](03-sdk-intelligence.md)).

**Syntax**
```
flutterx resolve   [--explain] [--deep] [--accept-low] [--refresh]
flutterx recommend [--explain] [--deep] [--matrix] [--candidates <n>]
```

`resolve` applies the decision (writes lock, provisions); `recommend` only reports. `--deep` enables Dependency Intelligence deep mode; `--matrix` prints the package×version compatibility matrix.

**Example**
```
$ flutterx resolve
⠸ Scanning project…       4 evidence sources found
⠸ Solving…                38 candidates → policy → 31
⠸ Checking dependencies…  41/41 packages verified on 3.19.6
✓ Resolved Flutter 3.19.6 (Dart 3.3.4) — confidence: high
  Reason: project evidence points to 3.19.x (run with --explain for full trace)
ℹ 3.22.2 is available and compatible — see `flutterx upgrade --advise`
```

**Errors:** conflict → 11 with minimal conflicting pair; all denied → 13 with denial table; low confidence in CI → 12.

---

### 3.5 `flutterx current`

**Syntax**
```
flutterx current [--global] [--json]
```

**Example**
```
$ flutterx current
Project : ~/work/shop-app
Flutter : 3.22.2 (stable) — pinned via flutterx.yaml
Dart    : 3.4.3
SDK path: ~/.flutterx/versions/3.22.2
Lock    : fresh (evidence unchanged since resolve)
```

Outside a project: prints global default or "no global default set". Never fails except on storage corruption (15).

---

### 3.6 `flutterx list`

**Syntax**
```
flutterx list [--remote [<filter>]] [--channel <c>] [--json]
```

**Example**
```
$ flutterx list
  VERSION   DART    CHANNEL  SIZE(Δ)   USED BY
* 3.22.2    3.4.3   stable   214 MB    shop-app, admin-app
  3.19.6    3.3.4   stable   198 MB    app-legacy
  3.24.1    3.5.1   stable   231 MB    —          (orphan — `cache gc` reclaims)

Shared store: 1.9 GB · Total on disk: 2.5 GB · Saved vs full copies: ~7.3 GB
```

`--remote` lists registry releases (filterable: `flutterx list --remote 3.22`).

---

### 3.7 `flutterx doctor`

Read-only diagnosis (same probes as `repair`, see [03-sdk-intelligence.md](03-sdk-intelligence.md) §9).

**Syntax**
```
flutterx doctor [--project|--store|--all] [--json] [--path-fix]
```

`--path-fix` prints a copy-pasteable shell snippet that puts `~/.flutterx/bin` first in PATH (detected shell's rc file syntax); it does not modify any file.

**Example**
```
$ flutterx doctor
FlutterX 1.0.0 — environment check

 Store
  ✓ bare repo healthy (fsck clean, 3 tags materialized)
  ✓ artifact store consistent (0 missing hashes)
  ⚠ 1 orphaned version (3.24.1, 231 MB) — `flutterx cache gc`

 Project (~/work/shop-app)
  ✓ lock fresh, symlink valid
  ✓ shims first in PATH

 Platform
  ✓ git 2.43 (≥2.30 required)
  ⚠ PATH: ~/.flutterx/bin is after /usr/local/bin — system flutter may shadow shims
    → move ~/.flutterx/bin earlier in PATH (snippet: `flutterx doctor --path-fix`)

1 warning, 0 errors.
```

Exit 0 with warnings; non-zero only on errors (15) — CI-friendly.

---

### 3.8 `flutterx repair`

**Syntax**
```
flutterx repair [--yes] [--force] [--only <diagnosis-id,...>] [--dry-run]
```

**Example**
```
$ flutterx repair
Found 2 issues:
  [FX-R03] corrupt worktree 3.19.6 (7 files missing)   → recreate from shared repo
  [FX-R07] shim 'dart' missing from ~/.flutterx/bin    → reinstall shims
Apply 2 fixes? [Y/n] y
✓ FX-R03 fixed (worktree recreated, 3.2s)
✓ FX-R07 fixed
All issues resolved. Re-run `flutterx doctor` anytime.
```

**Errors:** destructive fix declined → partial report, exit 0; fix failed → 15 with journal reference.

---

### 3.9 `flutterx upgrade`

**Syntax**
```
flutterx upgrade [--advise] [--to <version>] [--bump-deps] [--yes] [--dry-run]
```

`--advise` (or no flags) prints the Upgrade Advisor report only. Applying: re-pins, provisions, optionally bumps blocking package versions in `pubspec.yaml` (`--bump-deps`), then runs `pub get` and prints a post-upgrade checklist. Blocked verdict → exit 16 with remediations. Full algorithm in [03-sdk-intelligence.md](03-sdk-intelligence.md) §8.

---

### 3.10 `flutterx cache`

**Syntax**
```
flutterx cache <status|refresh|gc|verify>
  gc:      [--dry-run] [--aggressive] [--keep <versions>]
  refresh: [--registry-only]
```

| Subcommand | Behavior |
|---|---|
| `status` | Sizes: bare repo, per-version delta, artifacts by refcount, downloads |
| `refresh` | Re-fetch registry snapshot; `git fetch` bare repo |
| `gc` | Remove orphaned worktrees, unreferenced artifacts, stale downloads; `--aggressive` also repacks git objects |
| `verify` | Hash-verify artifacts, `git fsck` — read-only integrity audit |

**Example**
```
$ flutterx cache gc --dry-run
Would reclaim 612 MB:
  231 MB  version 3.24.1 (no project references, unused 34 days)
  305 MB  2 unreferenced engine artifacts
   76 MB  stale partial downloads
Run without --dry-run to apply.
```

---

### 3.11 `flutterx shell`

Ephemeral subshell (or command) with a specific SDK first on PATH — no project changes.

**Syntax**
```
flutterx shell <version> [-- <command …>]
```

**Examples**
```
$ flutterx shell 3.24.1
(flutterx 3.24.1) $ flutter --version   # this shell only

$ flutterx shell beta -- flutter test   # one-shot, exit code passthrough (20)
```

---

### 3.12 `flutterx workspace`

Monorepo support: one policy, many packages.

**Syntax**
```
flutterx workspace init
flutterx workspace status
flutterx workspace resolve [--parallel]
flutterx workspace exec -- <command …>
```

`init` writes a root `flutterx.yaml` with `workspace:` globs; member projects inherit the root policy (a member may pin tighter, never looser — Rule Engine precedence). `resolve` runs resolution per member and reconciles: default policy `single-sdk` picks one version satisfying **all** members (intersection solve) and reports which member forces what.

**Example**
```
$ flutterx workspace resolve
Members: apps/shop, apps/admin, packages/ui_kit (3)
✓ Intersection solve: Flutter 3.22.2 satisfies all members
  apps/shop     constraint Dart >=3.3  ✓
  apps/admin    constraint Dart >=3.4  ✓  ← tightest
  packages/ui_kit any                  ✓
✓ 3 locks written
```

**Errors:** empty intersection → 11, report shows the two members whose constraints conflict.

---

### 3.13 `flutterx run` / `build` / `test` / `pub`

Context-aware proxies: resolve (fast path via lock), then `exec` the real tool with argv passed through untouched.

**Syntax**
```
flutterx run   [flutter run args…]
flutterx build <target> [args…]
flutterx test  [args…]
flutterx pub   <get|upgrade|outdated|…> [args…]
```

**Behavior contract**
- Exit code = proxied process (contract code 20 class).
- stdin/stdout/stderr fully passed through (hot reload keys work).
- If no lock exists: run `resolve` first (prints one line), then continue — this is the "clone → flutterx run" two-command experience.
- These exist for users who don't install shims; with shims on PATH, plain `flutter run` behaves identically.

---

### 3.14 `flutterx config`

**Syntax**
```
flutterx config [get <key>] [set <key> <value>] [unset <key>] [list]
```

Keys (dot notation): `channel.default`, `resolve.acceptLow`, `gc.keepOrphansDays`, `rules.<id>.*`, `network.mirror`, … Config lives in `~/.flutterx/config.yaml`; every key documented via `flutterx config list --describe`.

---

## 4. Global Files Written by the CLI

| File | Committed? | Owner |
|---|---|---|
| `flutterx.yaml` (project/workspace) | yes | user intent — hand-editable |
| `.flutterx/resolution.lock` | yes | machine outcome — never hand-edit |
| `.flutterx/sdk` symlink | no (gitignore) | machine |
| `~/.flutterx/**` | n/a | machine |

---

*Next: [05-storage-design.md](05-storage-design.md) — the store these commands operate on.*
