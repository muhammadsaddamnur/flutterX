# FlutterX — Product Vision

> **Document status:** Draft v1.0 · Design phase — no implementation yet
> **Audience:** Contributors, maintainers, adopters
> **Related docs:** [02-system-architecture.md](02-system-architecture.md) · [07-development-roadmap.md](07-development-roadmap.md)

---

## 1. Vision

**FlutterX is a Flutter Development Platform, not a version manager.**

Every existing tool in this space (FVM, Puro, asdf plugins) answers the same narrow question: *"how do I switch between Flutter SDKs?"* FlutterX answers a bigger one:

> *"Which SDK should this project use, why, and how do I keep it healthy over time — automatically?"*

The long-term vision is that a Flutter developer never has to think about SDK management at all. They clone a repository, run one command (or none — via shims), and FlutterX:

1. **Understands** the project (constraints, dependencies, CI config, team policy).
2. **Decides** the correct SDK (resolution + recommendation).
3. **Provisions** it in seconds using shared git objects and shared artifacts.
4. **Maintains** it (repair, upgrade advice, storage hygiene) without being asked.

We call the sum of capabilities 2–4 **SDK Intelligence** — the core innovation and the reason FlutterX exists.

## 2. Mission

Build an open-source, cross-platform, extensible Flutter development platform that:

- Makes SDK selection a **solved problem** instead of a manual chore.
- Reduces disk usage and install time by an order of magnitude versus naive per-project SDK copies.
- Gives teams **deterministic, reproducible** Flutter environments across machines and CI.
- Stays **friendly to contributors**: clean architecture, small packages, strong docs, no magic.

## 3. Product Goals

| # | Goal | Success metric (target) |
|---|------|------------------------|
| G1 | Best-in-class DX | New machine → running `flutter run` in ≤ 2 commands |
| G2 | Intelligent SDK resolution | ≥ 95% of projects resolve to a working SDK with zero flags |
| G3 | Automatic version recommendation | Recommendation accepted without override in ≥ 80% of cases |
| G4 | Storage optimization | ≥ 70% disk saving vs. N independent Flutter clones |
| G5 | Fast provisioning | Second-and-later SDK install ≤ 15s on SSD (git worktree + shared artifacts) |
| G6 | Self-healing | ≥ 90% of common breakages fixed by `flutterx repair` without reinstall |
| G7 | Reproducibility | Same lockfile → byte-identical SDK selection on any machine |
| G8 | Cross-platform parity | macOS, Linux, Windows are all first-class (CI-gated) |
| G9 | Contributor-friendly | A new contributor lands a first PR guided only by docs |

## 4. Problems Solved

### P1 — "Which Flutter version does this project need?"
Today the answer lives in tribal knowledge, README footnotes, or trial-and-error. FlutterX derives it from evidence the project already contains: `pubspec.yaml` SDK constraints, `pubspec.lock`, `.metadata`, existing FVM/Puro config, and CI workflows. See [03-sdk-intelligence.md](03-sdk-intelligence.md).

### P2 — Disk bloat
A single Flutter SDK with engine artifacts commonly exceeds 2–4 GB. Five projects × five pinned versions = tens of GB of near-duplicate data. FlutterX shares git objects across all versions (one bare repo, many worktrees) and content-addresses engine artifacts so identical binaries exist once. See [05-storage-design.md](05-storage-design.md).

### P3 — Slow, fragile installs
Full clones and repeated artifact downloads are slow and break on flaky networks. Git-based provisioning from a local bare repo is mostly a local operation; artifact downloads are resumable and cached.

### P4 — Broken environments
Corrupt caches, dangling symlinks, half-finished upgrades, and mismatched Dart/Flutter pairs cost hours. The Repair Engine detects and fixes known failure classes deterministically.

### P5 — Risky upgrades
"Just bump to the latest stable" regularly breaks builds via transitive package incompatibilities. The Upgrade Advisor simulates the upgrade against dependency intelligence before anything is touched.

### P6 — Team drift
Different developers on different SDK versions produce "works on my machine" bugs. Project pinning (`flutterx.yaml`) plus workspace policies make the environment part of the repository.

## 5. Comparison with FVM

FVM is a solid, popular version manager. FlutterX respects it and can even read its config for migration. The difference is scope.

| Capability | FVM | FlutterX |
|---|---|---|
| Pin SDK per project | ✅ | ✅ |
| Install/list/remove SDKs | ✅ | ✅ |
| Storage model | Full SDK copy per version | One bare git repo + worktrees + content-addressed artifacts |
| Disk usage for N versions | ~N × full SDK | ~1 × repo + small per-version delta |
| Automatic version detection | Reads its own config | Infers from pubspec, lockfile, `.metadata`, CI, FVM/Puro config |
| Version recommendation | ❌ | ✅ Recommendation Engine with explainable scoring |
| Dependency-aware resolution | ❌ | ✅ Dependency Intelligence checks package compatibility |
| Upgrade planning | ❌ | ✅ Upgrade Advisor with dry-run impact report |
| Self-repair | Limited (`fvm doctor` diagnoses) | ✅ Repair Engine diagnoses **and fixes** |
| Shims (`flutter` just works) | Via IDE config / `fvm flutter` prefix | ✅ Global shims with per-project resolution |
| Monorepo/workspace support | Basic | ✅ First-class `workspace` command and policies |
| Migration path | — | ✅ Reads `.fvmrc` / `fvm_config.json` |

**Positioning:** FVM manages versions you choose. FlutterX chooses, provisions, and maintains versions for you — and still lets you override everything.

## 6. Comparison with Puro

Puro pioneered the git/worktree storage trick and is the performance benchmark to beat or match.

| Capability | Puro | FlutterX |
|---|---|---|
| Shared git objects (bare repo + worktrees) | ✅ | ✅ Same proven strategy |
| Shared engine artifacts | ✅ (global pub + engine sharing) | ✅ Content-addressed artifact store |
| Fast switching | ✅ | ✅ |
| Intelligent resolution from project evidence | ❌ (manual `puro use`) | ✅ Resolver Engine |
| Recommendation with reasons | ❌ | ✅ |
| Dependency intelligence / upgrade advisor | ❌ | ✅ |
| Repair engine | Partial | ✅ Structured detect→plan→fix pipeline |
| Rule/policy engine for teams | ❌ | ✅ Rule Engine (channel policy, allow/deny lists, org constraints) |
| Extensibility as a design goal | Internal-first | ✅ Public package APIs, plugin points designed in from day one |

**Positioning:** FlutterX adopts Puro's best idea (storage) and builds the intelligence layer Puro never aimed for.

## 7. Competitive Advantages

1. **SDK Intelligence as a moat.** Resolution, recommendation, dependency analysis, upgrade simulation, and repair form a pipeline no competitor has. Each stage is independently useful; together they compound.
2. **Explainability.** Every automatic decision prints its evidence and score ("chose 3.22.2 because: lockfile pins Dart 3.4.x, package `xyz` requires Flutter ≥3.19, team policy = stable channel"). Trust is a feature.
3. **Zero-migration adoption.** FlutterX reads FVM and Puro configuration, so switching costs one command.
4. **Architecture as a feature.** Clean Architecture, small focused packages, and documented seams ([06-package-design.md](06-package-design.md)) make contribution and embedding (IDE plugins, CI actions) cheap.
5. **Determinism.** A resolution lockfile makes CI and teammates bit-for-bit consistent.

## 8. Non-Goals (v1)

Explicit non-goals keep scope honest:

- **Not** a Dart-only version manager (Flutter-bundled Dart is managed; standalone Dart SDKs are future work).
- **Not** an IDE. IDE *integrations* are v2+ ([07-development-roadmap.md](07-development-roadmap.md)).
- **Not** a package registry or pub.dev replacement.
- **Not** a build system; `run`/`build`/`test` are context-aware proxies to the resolved SDK.
- **No telemetry by default.** Any future metrics are opt-in and documented.

## 9. Future Vision

- **FlutterX Daemon:** long-lived local service powering IDE plugins and instant resolution.
- **Team/Org policies as code:** signed policy files distributed via git, enforced by the Rule Engine.
- **Cloud artifact mirror:** optional org-hosted cache for air-gapped or bandwidth-constrained CI.
- **Predictive upgrades:** advise *when* to upgrade based on ecosystem readiness of your dependency graph, not just release dates.
- **Plugin ecosystem:** third-party rules, scanners, and repair strategies via a stable plugin API.

---

*Next: [02-system-architecture.md](02-system-architecture.md) — how the platform is structured to deliver this vision.*
