# FlutterX — Design Documentation

FlutterX is a **Flutter Development Platform** whose core innovation is **SDK Intelligence**: it understands a project, decides the right SDK, provisions it in seconds, and keeps the environment healthy — going far beyond version managers like FVM and Puro.

This documentation set is the pre-implementation design. It is written so that an engineer (or an AI) can implement FlutterX **without redesigning the architecture**. If code and these docs ever disagree, that is a bug — file it.

## Reading Order

| # | Document | Answers |
|---|---|---|
| 01 | [Product Vision](01-product-vision.md) | Why FlutterX exists; goals; FVM/Puro comparison; non-goals |
| 02 | [System Architecture](02-system-architecture.md) | Clean Architecture layout; C4 diagrams; runtime model; request flows; ADRs |
| 03 | [SDK Intelligence](03-sdk-intelligence.md) | The 9 engines: Registry, Scanner, Solver, Rules, Recommendation, Dependency Intelligence, Resolver, Upgrade Advisor, Repair — algorithms, pseudocode, edge cases |
| 04 | [CLI Specification](04-cli-specification.md) | Every command: syntax, flags, example output, errors, exit codes |
| 05 | [Storage Design](05-storage-design.md) | Git bare-repo + worktrees; content-addressed artifacts; GC; crash-safe journal; cross-platform notes |
| 06 | [Package Design](06-package-design.md) | The 8 monorepo packages: responsibilities, public APIs, dependency graph, class diagrams |
| 07 | [Development Roadmap](07-development-roadmap.md) | MVP → Beta → Stable → v2 → Future, with milestones, priorities, risks |
| 08 | [Contributing Guide](08-contributing-guide.md) | Standards, testing strategy, commits, branching, releases |
| 09 | [Implementation Task List](09-task-list.md) | Checkbox-tracked tasks derived from docs 01–08, grouped by roadmap phase |

## The One-Paragraph Summary

A single bare `flutter/flutter` git repository plus git worktrees makes installing a new SDK version an ~O(1)-cost local operation; a content-addressed artifact store deduplicates engine binaries across versions ([05](05-storage-design.md)). On top of that store, a pure, explainable intelligence pipeline — scan project evidence → solve version constraints → apply team policy rules → rank with dependency-compatibility scoring — picks the right SDK automatically and writes a committed lockfile for reproducibility ([03](03-sdk-intelligence.md)). Everything is Clean Architecture in a Dart monorepo, so the same engines power the CLI today and a daemon/IDE integrations tomorrow ([02](02-system-architecture.md), [06](06-package-design.md)).

## Status

All documents: **Draft v1.0 — design phase, pre-implementation.** Diagrams use Mermaid (rendered natively by GitHub).
