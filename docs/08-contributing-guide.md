# FlutterX — Contributing Guide

> **Document status:** Draft v1.0 · Design phase
> **Audience:** All contributors
> **Related docs:** [02-system-architecture.md](02-system-architecture.md) · [06-package-design.md](06-package-design.md)

---

## 1. Architecture Principles (the non-negotiables)

Every PR is reviewed against these five rules:

1. **The dependency rule points inward.** `domain` imports nothing; `intelligence` imports only `domain`; `application` imports `domain` + `intelligence`; infrastructure packages implement domain ports; the CLI wires everything in one composition root. A CI lint fails builds that violate this ([06-package-design.md](06-package-design.md) §1).
2. **Engines are pure.** No `dart:io`, no network, no clock reads inside `flutterx_intelligence`. If your engine change needs a file, the application layer reads it and passes content in.
3. **Every decision is explainable.** Engine outputs carry reasons/evidence. A PR that adds behavior without adding its explanation is incomplete.
4. **Every mutation is journaled and idempotent.** If your code changes `~/.flutterx`, it goes through the journal and must survive being re-run ([05-storage-design.md](05-storage-design.md) §7).
5. **Public contracts are sacred** (post-1.0): exit codes, `--json` schemas, lockfile and store schema versions change only with a major version + migration.

When in doubt, ask in the issue before writing code — design discussion is cheaper than review rejection.

## 2. Repository & Folder Conventions

```
flutterx/
├── docs/                  # these design docs — updated in the same PR as behavior changes
├── packages/<pkg>/
│   ├── lib/<pkg>.dart     # only public entry point (export barrel)
│   ├── lib/src/…          # private implementation
│   └── test/              # mirrors lib/src structure 1:1
├── tool/                  # repo automation (lint rules, corpus runner, release scripts)
├── .github/workflows/
└── melos.yaml
```

- **File naming:** `snake_case.dart`; one primary type per file; test file = `<source>_test.dart` in the mirrored path.
- **No cross-package `src/` imports.** Importing `package:flutterx_x/src/…` from another package fails CI.
- **Fixtures** live in `test/fixtures/` as real-world files (actual pubspecs, lockfiles, releases JSON) — prefer realistic fixtures over synthetic minimal ones.

## 3. Coding Standards

- **Style:** `dart format` (enforced) + `package:lints/recommended.yaml` plus the repo's `analysis_options.yaml` extras: `prefer_final_locals`, `unawaited_futures`, `directives_ordering`, custom `flutterx_lints` (dependency rule, no-`dart:io`-in-engines, no-`print`).
- **Errors:** expected failures return `Result<T>`/sealed `FxFailure` — never thrown. Exceptions mean bugs. New failure = new stable `FX-*` code, documented in the failure catalogue.
- **Nullability:** avoid nullable returns where a sealed type states the cases.
- **Comments:** public API gets dartdoc with one example. Inside implementations, comment only non-obvious constraints ("git worktree prune must run before removing the dir, else…"), not narration.
- **Dependencies:** adding a package dependency to `pubspec.yaml` requires maintainer sign-off in the PR; `domain` and `intelligence` effectively never gain new deps.

## 4. Testing Strategy

Test pyramid, from broad to narrow (details per package in [06-package-design.md](06-package-design.md) §10):

| Level | What | Runs |
|---|---|---|
| Unit (majority) | pure engines, value objects; golden files for explanations/renderings | every PR, all OS |
| Use case | application layer against in-memory fakes of all ports | every PR |
| Integration (`@Tags(['integration'])`) | real git in tmp dirs, recorded HTTP (no live network in CI), real filesystem links per OS | every PR, OS matrix |
| End-to-end | tmp `FLUTTERX_HOME`: install → use → shim exec `flutter --version`; crash-recovery tests (kill mid-install → repair) | every PR on Linux; nightly full matrix |
| Corpus accuracy | resolution pipeline vs ~50 real project fixtures with expected outcomes | every PR touching `intelligence` |
| Performance | phase timings vs targets in [05-storage-design.md](05-storage-design.md) §9 | nightly, regression = issue auto-filed |

**Rules:** new behavior lands with tests in the same PR; bug fixes land with a regression test that fails before the fix; coverage is tracked but gates are per-package (domain/intelligence ≥ 90%, infra ≥ 70% — I/O code is validated by integration tests, not line coverage).

## 5. Commit Convention

**Conventional Commits**, enforced by commit-lint in CI:

```
<type>(<scope>): <imperative summary ≤ 72 chars>

[body: what & why, not how]
[footer: BREAKING CHANGE:, Fixes #123]
```

- **Types:** `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `build`, `chore`, `revert`.
- **Scopes** = package short names (`domain`, `intel`, `app`, `git`, `storage`, `registry`, `platform`, `cli`) or `docs`, `repo`.
- Examples:
  - `feat(intel): add freshness-window rule`
  - `fix(storage): make CAS commit atomic on Windows (Fixes #412)`
  - `feat(cli)!: rename --matrix to --compat-matrix` (+ `BREAKING CHANGE:` footer)

Commit types drive automated changelog + semver bumps (§7).

## 6. Branching Strategy

**Trunk-based with release branches:**

- `main` — always releasable; protected; PRs only; required checks: format, analyze, dependency-rule lint, unit+integration on 3-OS matrix, corpus (when applicable).
- `feat/<scope>-<slug>`, `fix/<issue>-<slug>` — short-lived branches off `main`; rebase-merge (linear history).
- `release/1.x` — cut at each minor; only `fix:` cherry-picks; patch releases tag here.
- No long-lived develop branch — incomplete features hide behind config flags (`experimental.*`) rather than branches.

**PR expectations:** small (< ~400 lines diff preferred), one concern, description links the design-doc section it implements, docs updated in-PR, at least one maintainer review; `intelligence` changes need a second reviewer.

## 7. Release Strategy

- **Versioning:** SemVer on the CLI as the product version; internal packages version-locked to it via melos (single version line — simpler for a monorepo whose packages ship together).
- **Cadence:** `0.x` — release when milestones complete; post-1.0 — minor every ~8 weeks, patches as needed from `release/*`.
- **Pipeline (automated, tag-triggered):**
  1. `melos version` computes bump from conventional commits → changelog PR.
  2. Merging the changelog PR tags `vX.Y.Z`.
  3. CI builds AOT binaries (macOS arm64/x64, Linux x64/arm64, Windows x64), runs the full e2e matrix against the artifacts.
  4. Publishes: GitHub Release (binaries + checksums + SBOM), Homebrew tap, `dart pub global` package, Chocolatey/Scoop (from M3.4), install script (`curl | sh` with checksum verification).
  5. Seed registry snapshot regenerated and embedded ([03-sdk-intelligence.md](03-sdk-intelligence.md) §1.2).
- **Release channels:** `stable` (default) and `dev` (pre-releases from `main` weekly) — FlutterX dogfoods its own channel concept.
- **Yanking:** a bad release is marked retracted in the update manifest; `flutterx doctor` warns users on a retracted FlutterX build.

## 8. Contributor Workflow (quick start)

```bash
git clone https://github.com/<org>/flutterx && cd flutterx
dart pub global activate melos
melos bootstrap          # link packages
melos run analyze        # format + analyze + dependency-rule lint
melos run test           # unit + use-case tests
melos run test:integration
dart run packages/flutterx_cli/bin/flutterx.dart --help   # run from source
```

Good first issues are labeled `good-first-issue` and always reference the design-doc section they implement — read that section first; it is the source of truth. If code and docs disagree, that is itself a bug: file it.

## 9. Governance & Conduct

- **Decision records:** significant design changes require an ADR in `docs/adr/` (template provided) and update the affected design doc in the same PR.
- **Code of Conduct:** Contributor Covenant v2.1.
- **License:** MIT (maximally embedding-friendly, matching the "platform others build on" vision).
- **Security reports:** private disclosure via GitHub security advisories; artifact-integrity issues are always treated as high severity.

---

*This guide, like all docs 01–08, is versioned with the code. Improving it is a welcome first contribution.*
