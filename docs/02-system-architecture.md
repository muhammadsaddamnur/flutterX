# FlutterX — System Architecture

> **Document status:** Draft v1.0 · Design phase
> **Audience:** Implementers and reviewers
> **Related docs:** [03-sdk-intelligence.md](03-sdk-intelligence.md) · [05-storage-design.md](05-storage-design.md) · [06-package-design.md](06-package-design.md)

---

## 1. Architectural Drivers

The architecture is derived from the product goals in [01-product-vision.md](01-product-vision.md):

| Driver | Architectural consequence |
|---|---|
| SDK Intelligence is the core product | Intelligence lives in its own package with **no CLI or I/O dependencies**, so it is testable and embeddable (IDE, CI, daemon) |
| Cross-platform parity | All OS specifics behind a `Platform` abstraction; no `dart:io` path logic outside infrastructure |
| Explainability | Every engine returns a *decision object* (result + evidence + score), never a bare value |
| Determinism | Resolution produces a lockfile; engines are pure functions of (project evidence, registry snapshot, rules) |
| Contributor-friendly | Clean Architecture, one responsibility per package, dependency rule enforced in CI |
| Future daemon/IDE | Application layer exposes use cases as plain Dart APIs; the CLI is just one adapter |

## 2. Style: Clean Architecture

FlutterX uses Clean Architecture with the dependency rule **pointing inward**:

```
Presentation (CLI, future: daemon, IDE bridge)
        │ depends on
        ▼
Application (use cases / orchestration)
        │ depends on
        ▼
Domain (entities, value objects, engine interfaces, rules)
        ▲ implemented by
        │
Infrastructure (git, filesystem, HTTP, process, OS)
```

**Why Clean Architecture (decision record):**
- The intelligence engines must run headless (tests, daemon, CI action). Keeping them free of I/O makes that trivial: infrastructure is injected as interfaces.
- Contributors can change the git strategy, HTTP client, or output formatting without touching decision logic.
- The cost (more interfaces, some indirection) is acceptable because the domain is genuinely complex; this is not ceremony for a CRUD app.

Rules enforced in CI (see [08-contributing-guide.md](08-contributing-guide.md)):
1. `domain` imports nothing but the Dart SDK core libraries and `flutterx_domain` itself.
2. `application` imports `domain` only.
3. `infrastructure` implements `domain` interfaces; never the reverse.
4. `cli` imports `application` (+ formatting utils); never `infrastructure` directly except in the composition root.

## 3. High-Level Architecture (C4 Level 1 — System Context)

```mermaid
C4Context
  title FlutterX — System Context
  Person(dev, "Flutter Developer", "Works on one or more Flutter projects")
  System(flutterx, "FlutterX", "Flutter Development Platform: SDK intelligence, provisioning, maintenance")
  System_Ext(github, "flutter/flutter git remote", "Source of SDK code (tags, branches)")
  System_Ext(storage_gcs, "Flutter infra CDN", "Engine artifacts, Dart SDK archives, releases metadata JSON")
  System_Ext(pub, "pub.dev API", "Package versions and SDK constraints")
  System_Ext(ci, "CI systems", "GitHub Actions, GitLab CI, etc.")

  Rel(dev, flutterx, "Runs commands / transparent shims")
  Rel(flutterx, github, "Fetches SDK git objects")
  Rel(flutterx, storage_gcs, "Downloads artifacts + releases index")
  Rel(flutterx, pub, "Queries package SDK constraints")
  Rel(ci, flutterx, "Uses for reproducible environments")
```

## 4. Container View (C4 Level 2)

```mermaid
C4Container
  title FlutterX — Containers
  Person(dev, "Developer")

  System_Boundary(fx, "FlutterX") {
    Container(cli, "flutterx CLI", "Dart AOT binary", "Command parsing, output, exit codes")
    Container(shims, "Shims", "Tiny native launchers", "flutter/dart wrappers that resolve per-project SDK, then exec")
    Container(app, "Application Layer", "Dart package", "Use cases: install, resolve, recommend, repair, upgrade...")
    Container(intel, "SDK Intelligence", "Dart package", "Resolver, Scanner, Solver, Rules, Recommendation, Dependency Intel, Upgrade Advisor, Repair")
    Container(store, "Storage Engine", "Dart package", "Git object store, worktrees, artifact CAS, cache GC")
    Container(registry, "SDK Registry", "Dart package + local cache", "Snapshot of known releases, version↔Dart mapping")
  }

  ContainerDb(disk, "~/.flutterx", "Filesystem", "Bare repo, worktrees, artifacts, config, logs, locks")

  Rel(dev, cli, "flutterx <command>")
  Rel(dev, shims, "flutter run / dart ...")
  Rel(shims, app, "resolve + exec")
  Rel(cli, app, "invokes use cases")
  Rel(app, intel, "decisions")
  Rel(app, store, "provisioning")
  Rel(intel, registry, "reads snapshots")
  Rel(store, disk, "reads/writes")
```

## 5. Package Map and Responsibilities

The monorepo (managed with `melos`) contains these packages. Full API design in [06-package-design.md](06-package-design.md).

| Package | Layer | Responsibility | Depends on |
|---|---|---|---|
| `flutterx_domain` | Domain | Entities (`FlutterRelease`, `Project`, `Resolution`, `Diagnosis`…), value objects (`SemVer`, `Channel`), engine **interfaces**, rule contracts | — |
| `flutterx_intelligence` | Domain services | Implementations of Resolver, Scanner (parsing logic), Version Solver, Rule Engine, Recommendation, Dependency Intelligence, Upgrade Advisor, Repair planner — all pure | `flutterx_domain` |
| `flutterx_application` | Application | Use cases (`InstallSdk`, `UseSdk`, `ResolveProject`, `RepairEnvironment`…), orchestration, transactions, lockfile handling | `flutterx_domain`, `flutterx_intelligence` |
| `flutterx_git` | Infrastructure | Git operations: bare repo mgmt, fetch, worktree add/remove, integrity checks | `flutterx_domain` |
| `flutterx_storage` | Infrastructure | Filesystem layout, artifact CAS, download manager, cache GC, file locks | `flutterx_domain` |
| `flutterx_registry` | Infrastructure | Releases-index client, pub.dev client, local snapshot cache | `flutterx_domain` |
| `flutterx_platform` | Infrastructure | OS abstraction: paths, env, process exec, symlink/junction, shell detection | `flutterx_domain` |
| `flutterx_cli` | Presentation | Argument parsing, command tree, TTY output/spinners/tables, exit codes, composition root | `flutterx_application` (+ infra wired at root) |

```mermaid
graph TD
  CLI[flutterx_cli] --> APP[flutterx_application]
  APP --> INTEL[flutterx_intelligence]
  APP --> DOM[flutterx_domain]
  INTEL --> DOM
  GIT[flutterx_git] -. implements .-> DOM
  STOR[flutterx_storage] -. implements .-> DOM
  REG[flutterx_registry] -. implements .-> DOM
  PLAT[flutterx_platform] -. implements .-> DOM
  CLI -. composition root wires .-> GIT
  CLI -. wires .-> STOR
  CLI -. wires .-> REG
  CLI -. wires .-> PLAT
```

## 6. Component View (C4 Level 3 — SDK Intelligence)

```mermaid
C4Component
  title SDK Intelligence — Components
  Container_Boundary(intel, "flutterx_intelligence") {
    Component(resolver, "Resolver Engine", "Orchestrator", "Pipeline: scan → solve → rules → recommend → decision")
    Component(scanner, "Project Scanner", "Pure parser", "Extracts evidence from pubspec, lockfile, .metadata, CI, FVM/Puro config")
    Component(solver, "Version Solver", "Constraint solver", "Intersects constraints → candidate release set")
    Component(rules, "Rule Engine", "Policy filter", "Applies channel/team/org rules to candidates")
    Component(reco, "Recommendation Engine", "Scorer", "Ranks candidates, produces explainable scores")
    Component(depintel, "Dependency Intelligence", "Analyzer", "Package ⇄ SDK compatibility matrix")
    Component(upgrade, "Upgrade Advisor", "Planner", "Simulates upgrades, produces impact report")
    Component(repair, "Repair Engine (planner)", "Diagnoser", "Detects failure classes, emits fix plans")
  }
  Component_Ext(registry, "SDK Registry", "Snapshot of releases")
  Component_Ext(fs, "Evidence sources", "Files read by application layer, passed in")

  Rel(resolver, scanner, "1. evidence")
  Rel(resolver, solver, "2. candidates")
  Rel(resolver, rules, "3. filter")
  Rel(resolver, reco, "4. rank")
  Rel(solver, registry, "release data")
  Rel(reco, depintel, "compatibility signals")
  Rel(upgrade, depintel, "impact analysis")
  Rel(scanner, fs, "parses (content injected)")
```

Note the seam: **Scanner parses content, it does not read files.** The application layer gathers file contents via infrastructure and injects them. This keeps every engine deterministic and unit-testable with plain strings.

## 7. Runtime Architecture

### 7.1 Process model

- **`flutterx`** — short-lived AOT-compiled Dart binary. One invocation = one use case.
- **Shims** — `~/.flutterx/bin/flutter` and `dart`: minimal launchers that (a) find the project root, (b) read `.flutterx/resolution.lock` (fast path, no intelligence), (c) `exec` the real SDK binary. Cold path (no lock) delegates to `flutterx resolve`.
- **Concurrency safety** — all mutations of `~/.flutterx` take an advisory file lock (`locks/store.lock`); read paths are lock-free. Two `flutterx install` invocations serialize; `flutter run` via shim never blocks on the lock.
- **Future daemon (v2)** — same application layer hosted in a long-lived process over JSON-RPC; no redesign required because presentation is already an adapter.

### 7.2 Data at rest

Authoritative layout in [05-storage-design.md](05-storage-design.md). Summary:

```
~/.flutterx/
├── config.yaml            # global config + user prefs
├── bin/                   # shims on PATH
├── cache/
│   ├── git/flutter.git    # single bare repo (shared objects)
│   ├── registry/          # releases + pub metadata snapshots
│   └── downloads/         # resumable partial downloads
├── versions/<version>/    # git worktrees (checked-out SDKs)
├── artifacts/engine/<sha>/# content-addressed shared artifacts
├── locks/
└── logs/
```

Per project:

```
project/
├── flutterx.yaml          # committed: pin/policy ("what we want")
└── .flutterx/             # gitignored except lock
    ├── resolution.lock    # committed: resolved decision ("what we got")
    └── sdk -> ~/.flutterx/versions/3.22.2   # symlink/junction
```

## 8. Request Flows

### 8.1 `flutterx use 3.22.2` (explicit pin)

```mermaid
sequenceDiagram
  actor Dev
  participant CLI as flutterx_cli
  participant APP as UseSdkUseCase
  participant REG as SDK Registry
  participant GIT as Git Engine
  participant STO as Storage
  Dev->>CLI: flutterx use 3.22.2
  CLI->>APP: execute(project, "3.22.2")
  APP->>REG: lookup("3.22.2")
  REG-->>APP: FlutterRelease(tag, dart, hashes)
  alt version not installed
    APP->>GIT: ensureWorktree(tag)
    GIT->>GIT: fetch tag into bare repo (if missing)
    GIT-->>APP: worktree path
    APP->>STO: ensureArtifacts(release)
    STO-->>APP: linked artifacts
  end
  APP->>STO: writeProjectLink(project, version)
  APP->>APP: write flutterx.yaml + resolution.lock
  APP-->>CLI: Result(success, decision)
  CLI-->>Dev: "✓ Project pinned to Flutter 3.22.2 (Dart 3.4.3)"
```

### 8.2 `flutterx resolve` (intelligent path — the flagship flow)

```mermaid
sequenceDiagram
  actor Dev
  participant CLI as flutterx_cli
  participant APP as ResolveProjectUseCase
  participant SCN as Project Scanner
  participant SLV as Version Solver
  participant RUL as Rule Engine
  participant REC as Recommendation Engine
  participant STO as Storage/Git

  Dev->>CLI: flutterx resolve
  CLI->>APP: execute(projectDir)
  APP->>APP: collect evidence files (pubspec, lock, .metadata, CI, fvm/puro)
  APP->>SCN: scan(evidence)
  SCN-->>APP: ProjectEvidence(constraints, hints)
  APP->>SLV: solve(evidence, registrySnapshot)
  SLV-->>APP: CandidateSet
  APP->>RUL: apply(candidates, policies)
  RUL-->>APP: FilteredCandidates(+violations)
  APP->>REC: rank(filtered, signals)
  REC-->>APP: Recommendation(version, score, reasons)
  APP->>STO: provision if missing (as in 8.1)
  APP-->>CLI: Decision + explanation
  CLI-->>Dev: "✓ Resolved Flutter 3.22.2 — 3 reasons (run with --explain for details)"
```

### 8.3 Shim fast path (`flutter run` in a resolved project)

```mermaid
sequenceDiagram
  actor Dev
  participant SHIM as flutter shim
  participant LOCK as .flutterx/resolution.lock
  participant SDK as Real flutter binary
  Dev->>SHIM: flutter run
  SHIM->>SHIM: walk up to project root
  SHIM->>LOCK: read pinned version (µs)
  LOCK-->>SHIM: 3.22.2 → ~/.flutterx/versions/3.22.2
  SHIM->>SDK: exec bin/flutter run (argv passthrough)
  Note over SHIM,SDK: No intelligence, no network, ~0 overhead
```

Cold path: lock missing → shim prints a one-line hint and (configurable) invokes `flutterx resolve` first.

### 8.4 `flutterx repair`

```mermaid
sequenceDiagram
  actor Dev
  participant CLI
  participant APP as RepairUseCase
  participant DIA as Repair Engine (planner)
  participant EXE as Fix Executors (infra)
  Dev->>CLI: flutterx repair
  CLI->>APP: execute()
  APP->>APP: gather health probes (fs, git fsck summary, symlinks, versions)
  APP->>DIA: diagnose(probes)
  DIA-->>APP: [Diagnosis(id, severity, FixPlan)]
  APP-->>CLI: show plan, confirm (unless --yes)
  CLI->>APP: confirmed
  loop each FixPlan step
    APP->>EXE: apply(step)  // idempotent, ordered, logged
  end
  APP-->>CLI: RepairReport
```

## 9. Error-Handling & Observability Strategy

- **Typed failures.** Domain operations return `Result<T>` (success value or an `FxFailure` — definition in [06-package-design.md](06-package-design.md) §2.1); failures carry a stable `code` (e.g. `FX-GIT-003 partial-fetch-failed`) used in docs and issue templates. Exceptions are reserved for programmer errors.
- **Exit codes** are a public contract (defined in [04-cli-specification.md](04-cli-specification.md)).
- **Structured logs** to `~/.flutterx/logs/` (JSON lines, rotated); `--verbose` mirrors to stderr. No network telemetry.
- **Every mutation is journaled** (intent → steps → outcome) so `repair` can roll back or complete interrupted operations (crash-safe provisioning; see [05-storage-design.md](05-storage-design.md) §7).

## 10. Extensibility Points

Designed-in seams (stable from Beta onward):

1. **Rules** — implement `Rule` (domain interface); registered via config. Team policies are just rules loaded from `flutterx.yaml`/org files.
2. **Evidence extractors** — Scanner is a pipeline of `EvidenceExtractor`s; adding "read Bitrise config" is one class.
3. **Repair strategies** — `Diagnosis` → `FixPlan` pairs are pluggable.
4. **Presentation adapters** — CLI today; daemon (JSON-RPC) and GitHub Action reuse the same use cases.
5. **Artifact transports** — download source behind an interface → org mirrors later.

## 11. Key Design Decisions (ADR summary)

| ID | Decision | Alternatives considered | Rationale |
|---|---|---|---|
| ADR-1 | Dart as implementation language | Rust, Go | Audience = Flutter devs (contributor pool), reuse of `pub_semver`/`yaml`, AOT gives fast startup; shims cover the hot path |
| ADR-2 | Bare repo + worktrees for SDK storage | Full clones (FVM-style), tarball extraction | Proven by Puro; ~O(1) marginal cost per version |
| ADR-3 | Content-addressed artifact store | Per-version artifact dirs | Identical engine binaries shared across versions; integrity = free (hash is the address) |
| ADR-4 | Engines are pure; I/O injected | Engines read disk directly | Determinism, unit tests with strings, daemon/IDE reuse |
| ADR-5 | Two project files: `flutterx.yaml` (intent) + `resolution.lock` (outcome) | Single file | Mirrors pubspec/pubspec.lock mental model; lock enables byte-identical CI |
| ADR-6 | Shims resolve via lockfile only (no intelligence in hot path) | Always-resolve shims | `flutter run` latency must be ~0; intelligence runs explicitly or on lock miss |

---

*Next: [03-sdk-intelligence.md](03-sdk-intelligence.md) — the engines in depth, with algorithms and edge cases.*
