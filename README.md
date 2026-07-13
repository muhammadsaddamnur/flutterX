# FlutterX

**A Flutter Development Platform — not just a version manager.**

FlutterX understands your project, decides the right Flutter SDK for it,
provisions it in seconds using shared git objects, and keeps it healthy —
automatically. Its core innovation is **SDK Intelligence**: an explainable
pipeline that resolves the correct SDK from evidence your project already
contains (pubspec constraints, lockfile, `.metadata`, CI config, FVM/Puro
pins).

> **Status: pre-release (0.1.0-dev).** Built from the design docs in
> [docs/](docs/). Verified by CI on macOS and Linux; Windows support is in
> progress (unit-tested; integration landing with M1.11). Use on real
> projects at your own risk — the store lives entirely in `~/.flutterx`
> and never touches your existing Flutter/FVM/Puro installations.

## Why FlutterX?

| | FVM / Puro | FlutterX |
|---|---|---|
| Pin & switch SDK versions | ✅ | ✅ |
| Shared git storage (~70% disk saving) | Puro only | ✅ |
| **Decides the right version for you** | ❌ | ✅ `flutterx resolve` |
| **Explains every decision** | ❌ | ✅ `--explain` score breakdown |
| Dependency compatibility check | ❌ | ✅ `recommend --matrix` |
| Team policies (channels, floors, allow-lists) | ❌ | ✅ rule engine |
| Self-healing store | ❌ | ✅ `doctor` + `repair` |
| Reads FVM/Puro config (zero-migration) | — | ✅ bare `flutterx use` |

## Requirements

- **Dart SDK ≥ 3.9** (comes with any recent Flutter install)
- **git ≥ 2.30**
- macOS or Linux (Windows: in progress)

## Install (from source)

```sh
git clone https://github.com/muhammadsaddamnur/flutterX.git
cd flutterX
dart pub get

# Compile the CLI into the FlutterX store's bin dir:
mkdir -p ~/.flutterx/bin
dart compile exe packages/flutterx_cli/bin/flutterx.dart -o ~/.flutterx/bin/flutterx

# Put the store's bin dir FIRST on PATH (also activates the
# transparent `flutter`/`dart` shims):
echo 'export PATH="$HOME/.flutterx/bin:$PATH"' >> ~/.zshrc   # or ~/.bashrc
exec $SHELL

flutterx --version
flutterx doctor        # verifies git, store, shims, PATH order
```

> Prefer not to compile? Run any command as
> `dart run packages/flutterx_cli/bin/flutterx.dart <command>` from the
> repo root.

## Quick start

### The two-command experience (existing project)

```sh
cd your-flutter-project
flutterx resolve       # scans evidence → picks the right SDK → installs
                       #   → pins → links. Done.
flutter run            # the shim runs it with the resolved SDK
```

`resolve` reads your `pubspec.yaml` constraints, `pubspec.lock`,
`.metadata`, CI workflows, and any FVM/Puro pins — then explains itself:

```sh
flutterx resolve --explain
```
```
✓ Resolved Flutter 3.22.2 (Dart 3.4.3) — confidence: high

  +30  .github/workflows/build.yml points at 3.22.2
  +20  3.22.2 is the latest patch of its minor
  +15  stable channel
  ─────
   65  total
```

### Manual pinning

```sh
flutterx install 3.22.2      # provision into the shared store
flutterx use 3.22.2          # pin this project (writes flutterx.yaml + lock)
flutterx use                 # no argument: adopt an existing FVM/Puro pin
flutterx current             # what's active here, and is the lock fresh?
flutterx list                # installed SDKs + which projects use them
flutterx list --remote 3.22  # what's available upstream
```

> ⚠️ The first `install` of a version downloads Flutter's git objects and
> an engine artifact (hundreds of MB). Subsequent versions share objects
> and artifacts, so they are drastically cheaper. The first `flutter`
> invocation inside a fresh SDK also triggers Flutter's own bootstrap.

### Try before you decide

```sh
flutterx recommend             # report only — changes nothing
flutterx recommend --matrix    # package × SDK compatibility grid
flutterx shell 3.24.1 -- flutter test   # one-shot with another SDK
```

### Keep it healthy

```sh
flutterx doctor                # read-only diagnosis (store/project/platform)
flutterx repair                # fix what doctor found (asks first)
flutterx cache status          # where the disk went
flutterx cache gc --dry-run    # what's reclaimable (orphans, artifacts)
flutterx config set gc.auto true   # opt-in hygiene suggestions
```

### Working without shims

Every project command also exists as an explicit proxy — argv passes
through verbatim:

```sh
flutterx run --release -d chrome
flutterx build apk
flutterx test
flutterx pub get
```

## How it decides (30 seconds)

```
evidence files ──► Scanner ──► Solver ──► Rule Engine ──► Recommendation
(pubspec, lock,    (what do    (which     (team policy:   (score + explain
 .metadata, CI,     we know?)   versions   channels,        → the decision)
 FVM/Puro pins)                 CAN work?) floors, lists)
```

Every stage is pure, deterministic, and explainable. The decision is
written to `.flutterx/resolution.lock` — **commit that file**; teammates
and CI then reproduce the exact same SDK. (`flutterx.yaml` is your intent;
the lock is the outcome. `.flutterx/sdk` is a local link — gitignore it.)

## Configuration

Flat dot-notation keys in `~/.flutterx/config.yaml` via `flutterx config`:

```sh
flutterx config set rules.channel-policy.allow beta   # allow beta channel
flutterx config set rules.min-version-floor.version 3.16.0
flutterx config set resolve.auto true    # shims auto-resolve cold projects
flutterx config list
```

## Uninstall

```sh
rm -rf ~/.flutterx        # the store is fully self-contained
# then remove the PATH line from your shell rc
```

Your projects keep working with whatever Flutter install you had before —
FlutterX never modifies global state outside its store.

## Development

Design docs (the source of truth): [docs/](docs/) · Task list:
[docs/09-task-list.md](docs/09-task-list.md) · Contributing:
[docs/08-contributing-guide.md](docs/08-contributing-guide.md)

```sh
dart pub global activate melos
melos run analyze          # format + analyze + dependency-rule check
melos run test             # unit tests
melos run test:integration # real git/filesystem suites
```

## License

MIT
