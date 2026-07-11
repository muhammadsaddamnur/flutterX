# Request for Claude: Implement FlutterX from the Task List

## Objective

I want you to act as a **Senior Software Engineer** implementing FlutterX.

The design phase is complete. Do NOT redesign the architecture.

Your job is to **implement the tasks in [docs/09-task-list.md](docs/09-task-list.md)**, exactly as specified by the design documents.

---

# Source of Truth

The design documents in `docs/` are the single source of truth:

| Doc | Use it for |
|---|---|
| [docs/01-product-vision.md](docs/01-product-vision.md) | Scope decisions — check non-goals before adding anything |
| [docs/02-system-architecture.md](docs/02-system-architecture.md) | Layering, dependency rule, runtime model, ADRs |
| [docs/03-sdk-intelligence.md](docs/03-sdk-intelligence.md) | Engine algorithms, pseudocode, edge cases |
| [docs/04-cli-specification.md](docs/04-cli-specification.md) | Command syntax, flags, output, errors, exit codes |
| [docs/05-storage-design.md](docs/05-storage-design.md) | Store layout, git strategy, CAS, journal, GC |
| [docs/06-package-design.md](docs/06-package-design.md) | Package boundaries, public APIs, interfaces |
| [docs/07-development-roadmap.md](docs/07-development-roadmap.md) | Phase ordering and what is explicitly out of scope per phase |
| [docs/08-contributing-guide.md](docs/08-contributing-guide.md) | Coding standards, testing, commits, branching |
| [docs/09-task-list.md](docs/09-task-list.md) | **The work queue — execute it top to bottom** |

Rules of engagement with the docs:

- Every task in 09 cites the doc section that specifies it. **Read that section before writing code.**
- If the docs are ambiguous, choose the smallest interpretation consistent with the architecture and note the decision in the PR/commit description.
- If the docs are wrong or contradictory, **stop and say so** — propose a doc fix first, then implement. Never silently deviate.
- Do not implement anything not covered by a task. If you believe a task is missing, add it to 09 in the correct phase and flag it.

---

# Working Method

## Order

1. Start at **T0.1** and work strictly top to bottom within each phase.
2. Do not start a Phase 2 task while a Phase 1 P0 task it depends on is unfinished.
3. One task (or one tightly related group, e.g. T1.2.1–T1.2.3) per working session/commit series — keep changes small and reviewable.

## Per task

For every task:

1. Read the cited design-doc section(s).
2. Implement in the correct package — respect the dependency rule (inward only; enforced by lint).
3. Write the tests required by the Definition of Done in 09 (unit for pure code, integration for I/O, golden for CLI output).
4. Run `melos run analyze` and the relevant tests; everything green before moving on.
5. Mark the task's checkbox `[x]` in `docs/09-task-list.md` in the same commit.
6. Commit with a Conventional Commit message per [docs/08-contributing-guide.md](docs/08-contributing-guide.md) §5.

## Progress reporting

At the end of each session, report:

- Tasks completed (IDs) and tasks in progress.
- Any doc deviations or ambiguities found (with your resolution).
- The next task ID you would start.

---

# Hard Constraints (from the design — do not violate)

1. **Dependency rule:** `domain` imports nothing; `intelligence` imports only `domain`; `application` imports `domain` + `intelligence`; infrastructure implements domain ports; CLI wires everything in one composition root.
2. **Engines are pure:** no `dart:io`, network, or clock reads inside `flutterx_intelligence`. I/O happens in the application layer and is injected.
3. **Typed failures:** expected failures return `Result<T>` with sealed `FxFailure` and a stable `FX-*` code — never thrown.
4. **Every store mutation** goes through the journal and is idempotent.
5. **Exit codes, `--json` envelope, and lockfile format** must match [docs/04-cli-specification.md](docs/04-cli-specification.md) exactly — they are public contracts.
6. **Git strategy:** partial clone (`--filter=blob:none`) only; never shallow (`--depth`).
7. **Cross-platform:** no `Platform.isWindows`-style branching outside `flutterx_platform` (and storage/git internals where the docs allow it).

---

# Definition of Done (every task)

- [ ] Implementation matches the cited design-doc section.
- [ ] Tests land in the same change and pass on the CI matrix.
- [ ] `melos run analyze` clean (format, lints, dependency-rule check).
- [ ] Checkbox marked in `docs/09-task-list.md`.
- [ ] Conventional Commit message with correct scope.
- [ ] No public-contract drift; no undocumented behavior.

---

# Requirements

- Implementation language: **Dart** (monorepo managed with melos), per ADR-1.
- Follow the folder conventions in [docs/06-package-design.md](docs/06-package-design.md) and [docs/08-contributing-guide.md](docs/08-contributing-guide.md) §2.
- Prefer boring, readable code over clever code.
- When a task is too large for one session, split it into sub-tasks in 09 (e.g. `T1.4.4a`, `T1.4.4b`) and proceed.
- Ask before doing anything destructive or outside the task list.

---

# Where to Start

Begin with **Phase 0 (T0.1–T0.6)**: repository bootstrap — melos scaffold, the 8 package skeletons, lints, and CI. Then proceed into Phase 1 at **T1.2.1**.
