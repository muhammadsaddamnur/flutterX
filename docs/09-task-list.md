# FlutterX — Implementation Task List

> **Document status:** Draft v1.0 · Derived from design docs 01–08
> **Audience:** Anyone picking up implementation work
> **How to use:** Tasks are grouped by roadmap phase ([07-development-roadmap.md](07-development-roadmap.md)) and ordered by dependency — within a phase, work top-to-bottom. Every task cites the design-doc section that specifies it; **read that section before starting**. Check off tasks as PRs merge.

Task ID format: `T<phase>.<milestone>.<n>` — e.g. `T1.3.2` = Phase 1, Milestone M1.3, task 2.

---

## Phase 0 — Repository Bootstrap (part of M1.1)

- [x] **T0.1** Initialize git repo, MIT license, Code of Conduct (Contributor Covenant v2.1), issue/PR templates — [08 §9](08-contributing-guide.md)
- [x] **T0.2** Create `melos.yaml` + the 8 package skeletons (`domain`, `intelligence`, `application`, `git`, `storage`, `registry`, `platform`, `cli`), each with the `lib/<name>.dart` barrel + `lib/src/` + `test/` convention — [06 §1](06-package-design.md) *(note: melos ≥7 on Dart pub workspaces — config lives in root `pubspec.yaml`, not `melos.yaml`)*
- [x] **T0.3** Shared `analysis_options.yaml`: `lints/recommended` + `prefer_final_locals`, `unawaited_futures`, `directives_ordering`, no-`print` — [08 §3](08-contributing-guide.md)
- [x] **T0.4** Write `tool/` custom lints: dependency-rule check (inward-only imports), no-`dart:io`-in-`intelligence`, no cross-package `src/` imports — [06 §1](06-package-design.md), [08 §1](08-contributing-guide.md)
- [x] **T0.5** CI skeleton (GitHub Actions): format, analyze, dependency-rule lint, unit tests on macOS/Linux/Windows matrix; commit-lint for Conventional Commits — [08 §5–6](08-contributing-guide.md) *(integration-test step deferred to T1.3.6 — no tagged suites exist yet)*
- [ ] **T0.6** Branch protection on `main`, rebase-merge only, required checks — [08 §6](08-contributing-guide.md) *(blocked: requires the GitHub remote to exist; apply in repo settings after first push)*

## Phase 1 — MVP (v0.1 → v0.5)

### M1.2 · `flutterx_domain` core

- [x] **T1.2.1** Value objects: `SemVer` (wrapping `pub_semver`), `VersionConstraintX`, `Channel { stable, beta, dev, master }`, `Confidence` — [06 §2.1](06-package-design.md)
- [x] **T1.2.2** Entities: `FlutterRelease`, `RegistrySnapshot`, `Project`, `InstalledSdk`, `Resolution`, `Reason`, `CandidateSet` — [06 §2.1](06-package-design.md), [03 §1.1](03-sdk-intelligence.md)
- [x] **T1.2.3** `Result<T>` + sealed `FxFailure` hierarchy with stable `code`/`message`/`nextActions`; start the failure catalogue file (`FX-GIT-*`, `FX-SOLVE-*`, `FX-STORE-*`) — [06 §2.1](06-package-design.md), [02 §9](02-system-architecture.md) *(Result implemented as sealed Ok/Err — exhaustive switch, per the open decision in 06 §2.1)*
- [x] **T1.2.4** Ports: `SdkRepository`, `RegistryPort`, `ProjectStore`, `PlatformPort`, `Journal` — [06 §2.1](06-package-design.md)
- [x] **T1.2.5** Engine contracts (interfaces only, no impls yet): `ProjectScanner`, `VersionSolver`, `Rule`, `RecommendationEngine`, `UpgradeAdvisor`, `RepairPlanner` — [06 §2.1](06-package-design.md)
- [x] **T1.2.6** Unit tests: SemVer ordering laws, constraint algebra, exhaustive failure→exit-code mapping compiles — [06 §10](06-package-design.md)

### M1.3 · `flutterx_git` engine

- [x] **T1.3.1** `GitEngine` interface impl over system git: version detection with ≥2.30 gate — [06 §5](06-package-design.md)
- [x] **T1.3.2** `ensureBareRepo` + `fetchTag` with `--filter=blob:none` partial clone and full-fetch fallback (no shallow/`--depth`) — [05 §4.1](05-storage-design.md)
- [x] **T1.3.3** `addWorktree` / `removeWorktree` via git porcelain — [05 §4.2](05-storage-design.md)
- [x] **T1.3.4** `fsck()` health summary + `repack({aggressive})` — [06 §5](06-package-design.md)
- [x] **T1.3.5** stderr→`FxFailure` translation table (`FX-GIT-*`) + network retry policy (3 attempts, backoff) — [06 §5](06-package-design.md)
- [x] **T1.3.6** Integration tests against a local fixture remote (tagged `integration`) — [06 §10](06-package-design.md) *(convention: tagged AND under `test/integration/`; CI integration step enabled)*

### M1.4 · `flutterx_storage` engine

- [x] **T1.4.1** Store layout init + `state.json` with `schemaVersion`; refuse-newer-schema guard — [05 §3, §10](05-storage-design.md)
- [x] **T1.4.2** `StoreLock` (advisory file lock; flock/LockFileEx behind one interface) — [05 §8](05-storage-design.md), [02 §7.1](02-system-architecture.md)
- [x] **T1.4.3** `DownloadManager`: resumable `.partial` downloads, sha256 verify, atomic rename — [05 §5.1](05-storage-design.md), [06 §6](06-package-design.md)
- [x] **T1.4.4** `ArtifactStore` (CAS): `ensure`, `linkInto` (hardlink→symlink→copy per probed link mode), `verify`, `unreferenced`; sharded lowercase-hex layout — [05 §5](05-storage-design.md) *(link mechanism injected as `CreateLink` — the platform-specific impl lands with `flutterx_platform`, M1.7/M1.11)*
- [x] **T1.4.5** `Journal`: begin/step/commit files, idempotent-step contract, 30-day pruning — [05 §7](05-storage-design.md)
- [x] **T1.4.6** `SdkRepository` impl composing `GitEngine` + CAS: the full `install()` provisioning algorithm incl. version stamp + `.flutterx-manifest.json` — [05 §4.1](05-storage-design.md) *(dep edge storage→git added to 06 §1 per 06 §5)*
- [x] **T1.4.7** `ProjectStore` impl: `readEvidence`, `writeLock`, `linkSdk` (project symlink/junction), project registry in `state.json` — [05 §6.1](05-storage-design.md)
- [x] **T1.4.8** Integration tests: install → verify layout; interrupted install (failure injection) → journal uncommitted → re-run rolls forward — [06 §10](06-package-design.md)

### M1.5 · `flutterx_registry` (basic)

- [ ] **T1.5.1** `ReleasesClient` for `releases_<os>.json` → `RegistrySnapshot` (incl. Flutter↔Dart mapping, retracted flag) — [03 §1](03-sdk-intelligence.md)
- [ ] **T1.5.2** `SnapshotCache`: TTL 6h, etag, offline fallback with staleness warning — [03 §1.2](03-sdk-intelligence.md)
- [ ] **T1.5.3** Bundled seed snapshot + build-time regeneration script — [03 §1.2](03-sdk-intelligence.md), [08 §7](08-contributing-guide.md)
- [ ] **T1.5.4** Contract tests against recorded HTTP fixtures; nightly live-endpoint test — [07 Risks](07-development-roadmap.md)

### M1.6 · `flutterx_cli` + first commands

- [ ] **T1.6.1** CLI scaffold: `package:args` command runner, `composition_root.dart`, global flags (`--help/--verbose/--json/--no-color`) — [06 §9](06-package-design.md), [04 §1.1](04-cli-specification.md)
- [ ] **T1.6.2** Output layer: tables, spinners, error formatter (`✗ code / cause / next actions`), versioned `--json` envelope — [04 §1.3](04-cli-specification.md), [06 §9](06-package-design.md)
- [ ] **T1.6.3** `exit_codes.dart`: exhaustive `FxFailure`→code switch per the public contract (0,1,2,10–17,20) — [04 §1.2](04-cli-specification.md)
- [ ] **T1.6.4** Use cases + commands: `install` (flags `--force/--skip-artifacts/--precache`) — [04 §3.1](04-cli-specification.md)
- [ ] **T1.6.5** `remove` (reference check → exit 17; `--yes` semantics) — [04 §3.2](04-cli-specification.md)
- [ ] **T1.6.6** `list` (installed table + `--remote` filter) — [04 §3.6](04-cli-specification.md)
- [ ] **T1.6.7** `use` (`--pin/--policy/--no-install`; writes `flutterx.yaml` + lock + link; gitignore hint) — [04 §3.3](04-cli-specification.md)
- [ ] **T1.6.8** `current` (project/global, lock freshness line) — [04 §3.5](04-cli-specification.md)
- [ ] **T1.6.9** Golden output tests (human + `--json`) + exit-code matrix tests — [06 §10](06-package-design.md)

### M1.7 · Shims + project linking

- [ ] **T1.7.1** POSIX `flutter`/`dart` shims: project-root walk, lock read fast path (≤10 ms), exec passthrough — [02 §8.3](02-system-architecture.md), [05 §9](05-storage-design.md)
- [ ] **T1.7.2** Cold path: missing lock → hint + configurable auto-`resolve` (MVP: hint only, points to `use`) — [02 §8.3](02-system-architecture.md)
- [ ] **T1.7.3** `flutter upgrade` interception inside managed SDKs + `FLUTTERX_UNMANAGED=1` escape hatch — [05 §4.3](05-storage-design.md)
- [ ] **T1.7.4** `ShimInstaller.ensure()` in `flutterx_platform` + PATH guidance text — [06 §8](06-package-design.md)
- [ ] **T1.7.5** E2E test: tmp `FLUTTERX_HOME`, `install → use → shim flutter --version` — [08 §4](08-contributing-guide.md)

### M1.8 · `doctor` + `cache status/refresh`

- [ ] **T1.8.1** Health probes (read-only, parallel): store, project, platform sections — [04 §3.7](04-cli-specification.md), [03 §9.2](03-sdk-intelligence.md)
- [ ] **T1.8.2** `doctor` command (`--project/--store/--all/--json/--path-fix`); exit 0 on warnings — [04 §3.7](04-cli-specification.md)
- [ ] **T1.8.3** `cache status` + `cache refresh [--registry-only]` — [04 §3.10](04-cli-specification.md)
- [ ] **T1.8.4** `config` command (get/set/unset/list, dot-notation keys) — [04 §3.14](04-cli-specification.md)

### M1.9 · Proxy commands

- [ ] **T1.9.1** `ProxyExec` use case: resolve-via-lock then exec, full stdio passthrough, signal forwarding, exit-code passthrough (class 20) — [04 §3.13](04-cli-specification.md)
- [ ] **T1.9.2** Commands `run`, `build`, `test`, `pub` — [04 §3.13](04-cli-specification.md)
- [ ] **T1.9.3** `shell` command (subshell + one-shot `-- <cmd>` form) — [04 §3.11](04-cli-specification.md)

### M1.10 · FVM/Puro migration reading

- [ ] **T1.10.1** Evidence extractors for `.fvmrc` / `.fvm/fvm_config.json` / `.puro.json` (pin-level only) — [03 §2.1](03-sdk-intelligence.md)
- [ ] **T1.10.2** `use`/`current` honor migrated pins + conflict warning when multiple pins disagree — [03 §2.3](03-sdk-intelligence.md)

### M1.11 · Windows parity pass

- [ ] **T1.11.1** Junction-based linking + hardlink files + link-mode probing recorded in `state.json` — [05 §8](05-storage-design.md)
- [ ] **T1.11.2** `.bat`/`.exe` shims: argv quoting, ctrl-C forwarding — [05 §8](05-storage-design.md)
- [ ] **T1.11.3** Long-path (`\\?\`) handling in storage paths — [05 §8](05-storage-design.md)
- [ ] **T1.11.4** Windows CI becomes a merge gate — [07 Cross-Phase](07-development-roadmap.md)

**Phase 1 exit check:** 3+ versions × 3+ projects managed end-to-end; disk ≤ 40% of full copies; provisioning ≤ 15 s warm — [07 Phase 1](07-development-roadmap.md), [05 §9](05-storage-design.md)

---

## Phase 2 — Beta (v0.9) · SDK Intelligence

### M2.1 · Full Project Scanner

- [ ] **T2.1.1** Extractor pipeline (`EvidenceExtractor` interface, ordered, pluggable, never-throws) — [03 §2.3](03-sdk-intelligence.md)
- [ ] **T2.1.2** Extractors: `flutterx.yaml`, `resolution.lock`, `pubspec.yaml` (env.sdk + env.flutter), `pubspec.lock`, `.metadata`, CI files (GitHub Actions, Codemagic) — [03 §2.1](03-sdk-intelligence.md)
- [ ] **T2.1.3** `ProjectEvidence` merge + `ScanWarning`s (malformed YAML w/ line info, conflicting pins) + project-kind classification — [03 §2.2–2.3](03-sdk-intelligence.md)
- [ ] **T2.1.4** Unit tests with real-world fixture files per extractor — [08 §2](08-contributing-guide.md)

### M2.2 · Version Solver

- [ ] **T2.2.1** Pin path: registry validation, `FX-SOLVE-001` fallback — [03 §3.1](03-sdk-intelligence.md)
- [ ] **T2.2.2** Constraint-intersection solve with Dart↔Flutter translation + provenance trace (|C| after each step) — [03 §3.1](03-sdk-intelligence.md)
- [ ] **T2.2.3** Conflict explanation: minimal conflicting pair + remediation suggestions — [03 §3.2](03-sdk-intelligence.md)
- [ ] **T2.2.4** Edge cases: pre-release constraints, `any`, registry gaps → beta candidates — [03 §3.2](03-sdk-intelligence.md)

### M2.3 · Rule Engine

- [ ] **T2.3.1** `RuleEngine` aggregator: deny > penalize/prefer, order-independent evaluation — [03 §4.1](03-sdk-intelligence.md)
- [ ] **T2.3.2** Built-in rules: `deny-retracted`, `channel-policy`, `min-version-floor`, `deny-list`/`allow-list`, `freshness-window`, `prefer-lts-like` — [03 §4.2](03-sdk-intelligence.md)
- [ ] **T2.3.3** Policy precedence chain + tighten-only + `lockdown` + unknown-rule-id forward compat — [03 §4.3](03-sdk-intelligence.md)
- [ ] **T2.3.4** All-denied denial table + single-relaxation unblock computation — [03 §4.3](03-sdk-intelligence.md)

### M2.4 · Recommendation Engine

- [ ] **T2.4.1** Scoring signals per the weight table, each contribution recorded as `Reason(text, delta)` — [03 §5.1](03-sdk-intelligence.md)
- [ ] **T2.4.2** Confidence computation + behavior gates (high/medium/low, TTY vs CI) — [03 §5.2](03-sdk-intelligence.md)
- [ ] **T2.4.3** `--explain` rendering (golden-tested) + deterministic tiebreak — [03 §5.3](03-sdk-intelligence.md)
- [ ] **T2.4.4** Config validation for weight overrides at load time — [03 §5](03-sdk-intelligence.md)

### M2.5 · `resolve` / `recommend` commands

- [ ] **T2.5.1** Resolver orchestrator (pipeline conductor, no domain logic) per the flowchart incl. exits 11/12/13 — [03 §7](03-sdk-intelligence.md)
- [ ] **T2.5.2** `resolution.lock` v1 format + `evidenceHash` staleness detection — [03 §7](03-sdk-intelligence.md)
- [ ] **T2.5.3** `resolve` command (`--explain/--deep/--accept-low/--refresh`) + `recommend` (`--matrix/--candidates`) — [04 §3.4](04-cli-specification.md)
- [ ] **T2.5.4** Shim cold path upgraded to auto-resolve (configurable) — [02 §8.3](02-system-architecture.md)

### M2.6 · Dependency Intelligence (fast mode)

- [ ] **T2.6.1** `PubMetaClient` + pub metadata cache under `cache/registry/pub/` — [03 §6.1](03-sdk-intelligence.md), [05 §3](05-storage-design.md)
- [ ] **T2.6.2** Fast-mode compatibility checker (lockfile × candidate SDK; `?` for git/path deps) — [03 §6.1–6.2](03-sdk-intelligence.md)
- [ ] **T2.6.3** Compatibility matrix rendering for `recommend --matrix` — [03 §6.2](03-sdk-intelligence.md)
- [ ] **T2.6.4** Wire compatibility score into Recommendation signals — [03 §5.1](03-sdk-intelligence.md)

### M2.7 · Repair Engine (first half)

- [ ] **T2.7.1** `RepairPlanner` catalogue + probes for FX-R01…FX-R05 — [03 §9.1](03-sdk-intelligence.md)
- [ ] **T2.7.2** Fix executors (infra): idempotent, journaled, severity-ordered — [03 §9.2](03-sdk-intelligence.md)
- [ ] **T2.7.3** `repair` command (`--yes/--force/--only/--dry-run`; destructive-fix confirmation rules) — [04 §3.8](04-cli-specification.md)
- [ ] **T2.7.4** `doctor` reuses identical probes (doctor = repair minus executor) — [03 §9.2](03-sdk-intelligence.md)

### M2.8 · GC + reference counting

- [ ] **T2.8.1** Reference graph: project-registry validation, orphan + unreferenced-artifact detection, grace periods — [05 §6.1–6.2](05-storage-design.md)
- [ ] **T2.8.2** `cache gc` (`--dry-run/--aggressive/--keep`) incl. precache-adoption pass — [05 §6.2](05-storage-design.md), [04 §3.10](04-cli-specification.md)
- [ ] **T2.8.3** `cache verify` (hash audit + git fsck, read-only) — [04 §3.10](04-cli-specification.md)
- [ ] **T2.8.4** Opt-in auto-hygiene suggestion (`gc.auto`) — [05 §6.3](05-storage-design.md)

### M2.9 · Quality infrastructure

- [ ] **T2.9.1** Corpus CI: ~50 real OSS Flutter app fixtures + expected resolutions; accuracy gate ≥ 90% — [07 Phase 2](07-development-roadmap.md)
- [ ] **T2.9.2** Perf benchmarks vs targets table; nightly run, auto-filed regressions — [05 §9](05-storage-design.md), [08 §4](08-contributing-guide.md)

---

## Phase 3 — Stable (v1.0)

### M3.1 · Upgrade Advisor

- [ ] **T3.1.1** Deep-mode dependency simulation (`dart pub get --dry-run` in temp context, offline-first) in the application layer — [03 §6.1](03-sdk-intelligence.md), [06 §3](06-package-design.md)
- [ ] **T3.1.2** `advise()` algorithm: sdk/dart delta, blocking/needsBump/unaffected, verdicts SAFE / SAFE_WITH_CHANGES / BLOCKED — [03 §8.1](03-sdk-intelligence.md)
- [ ] **T3.1.3** Breaking-change knowledge-base format + lookup (`entriesBetween`) — [03 §8.1](03-sdk-intelligence.md)
- [ ] **T3.1.4** `upgrade` command: `--advise/--to/--bump-deps/--yes/--dry-run`, journaled apply, exit 16, downgrade warnings — [04 §3.9](04-cli-specification.md), [03 §8.2](03-sdk-intelligence.md)

### M3.2 · Repair completion

- [ ] **T3.2.1** Diagnoses FX-R06…FX-R09 + executors — [03 §9.1](03-sdk-intelligence.md)
- [ ] **T3.2.2** Journal recovery policy table: roll-forward (install/gc) vs roll-back (remove) — [05 §7](05-storage-design.md)
- [ ] **T3.2.3** Crash-recovery E2E suite (kill at each journal step → repair → healthy) — [08 §4](08-contributing-guide.md)

### M3.3 · Workspace support

- [ ] **T3.3.1** Root `flutterx.yaml` `workspace:` globs + member policy inheritance (tighten-only) — [04 §3.12](04-cli-specification.md), [03 §4.3](03-sdk-intelligence.md)
- [ ] **T3.3.2** Intersection solve across members + per-member force report; empty intersection → exit 11 with conflicting pair — [04 §3.12](04-cli-specification.md)
- [ ] **T3.3.3** `workspace init/status/resolve [--parallel]/exec` commands — [04 §3.12](04-cli-specification.md)

### M3.4 – M3.8 · Hardening

- [ ] **T3.4.1** Windows first-class: full CI matrix as release gate, shim edge cases — [07 Phase 3](07-development-roadmap.md)
- [ ] **T3.5.1** Store schema migration framework (journaled, one-way, half-migrated detection) — [05 §10](05-storage-design.md)
- [ ] **T3.6.1** Docs site + man pages generated from command definitions (single source of truth) — [07 M3.6](07-development-roadmap.md)
- [ ] **T3.7.1** Security pass: artifact hash enforcement audit, journal audit, threat notes, release checksums/SBOM — [07 M3.7](07-development-roadmap.md), [08 §7](08-contributing-guide.md)
- [ ] **T3.8.1** Seed breaking-change knowledge base (Flutter 3.16 → latest) — [03 §8.1](03-sdk-intelligence.md)
- [ ] **T3.9.1** Freeze public contracts: exit codes, `--json` schema, lockfile v1, store schema — semver commitment begins — [07 Phase 3](07-development-roadmap.md)
- [ ] **T3.9.2** Release pipeline: melos version → tag → AOT binaries (5 targets) → GitHub Release / Homebrew / pub global / Chocolatey / install script — [08 §7](08-contributing-guide.md)

---

## Phase 4 — v2 (post-1.0)

- [ ] **T4.1** FlutterX Daemon: JSON-RPC host over `FlutterXApi` — [02 §7.1](02-system-architecture.md), [07 M4.1](07-development-roadmap.md)
- [ ] **T4.2** VS Code extension + IntelliJ plugin (daemon clients) — [07 M4.2](07-development-roadmap.md)
- [ ] **T4.3** Org policy distribution: signed policy files via git URL + lockdown enforcement — [03 §4.3](03-sdk-intelligence.md)
- [ ] **T4.4** Official GitHub Action / GitLab template with store caching — [07 M4.4](07-development-roadmap.md)
- [ ] **T4.5** Plugin API v1: third-party rules, extractors, repair strategies + stability contract — [02 §10](02-system-architecture.md)
- [ ] **T4.6** Artifact mirror support (org-hosted CAS remote) — [07 M4.6](07-development-roadmap.md)

---

## Cross-Cutting Definition of Done (applies to every task)

Per [08-contributing-guide.md](08-contributing-guide.md):

- [ ] Tests land in the same PR (unit for pure code; integration for I/O; golden for output)
- [ ] New failures get stable `FX-*` codes; new user-visible behavior gets `--explain`/reason coverage where applicable
- [ ] Store mutations go through the journal and are idempotent
- [ ] Docs section that specifies the behavior is updated if the implementation deviates (or an ADR is filed)
- [ ] Conventional Commit message; dependency-rule lint passes; 3-OS CI green
