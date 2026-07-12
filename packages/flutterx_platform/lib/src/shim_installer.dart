import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// Bump when the shim template changes — the installer rewrites any shim
/// whose embedded version differs.
const shimVersion = 2;

/// POSIX shim (docs/02 §8.3, ADR-6): pure fast path — walk up to the
/// project's `.flutterx/sdk` link and exec the real tool. No intelligence,
/// no network, no Dart VM startup.
///
/// Also the interception point for store-mutating Flutter commands
/// (docs/05 §4.3): a managed worktree must not be changed behind
/// FlutterX's back; `FLUTTERX_UNMANAGED=1` is the escape hatch.
String posixShim(String tool) =>
    '''
#!/bin/sh
# FlutterX shim v$shimVersion for '$tool' — generated; do not edit.
# Reinstalled by any flutterx run (and by flutterx repair, FX-R07).

if [ "$tool" = "flutter" ] && [ -z "\${FLUTTERX_UNMANAGED:-}" ]; then
  case "\${1:-}" in
    upgrade|downgrade|channel)
      echo "flutterx: 'flutter \$1' would mutate the managed SDK store." >&2
      echo "  → use 'flutterx upgrade' instead" >&2
      echo "  → or set FLUTTERX_UNMANAGED=1 to bypass (docs/05 §4.3)" >&2
      exit 1
      ;;
  esac
fi

dir="\$PWD"
while :; do
  link="\$dir/.flutterx/sdk"
  if [ -e "\$link" ]; then
    exec "\$link/bin/$tool" "\$@"
  fi
  if [ -L "\$link" ]; then
    echo "flutterx: \$link is broken (target missing) — run 'flutterx repair'." >&2
    exit 1
  fi
  [ "\$dir" = "/" ] && break
  dir=\$(dirname "\$dir")
done

flutterx_bin="\$(dirname "\$0")/flutterx"
config="\${FLUTTERX_HOME:-\$HOME/.flutterx}/config.yaml"
if [ -z "\${FLUTTERX_SHIM_RETRY:-}" ] && [ -x "\$flutterx_bin" ] && \\
   { [ "\${FLUTTERX_AUTO_RESOLVE:-}" = "1" ] || grep -qs 'resolve.auto: true' "\$config"; }; then
  # Cold path auto-resolve (docs/02 §8.3, opt-in): resolve once, retry.
  "\$flutterx_bin" resolve >&2 && FLUTTERX_SHIM_RETRY=1 exec "\$0" "\$@"
fi

echo "flutterx: no resolved SDK for this directory." >&2
echo "  → run 'flutterx resolve' (automatic) or 'flutterx use <version>'" >&2
exit 1
''';

/// What [ShimInstaller.ensure] did and found.
final class ShimStatus {
  const ShimStatus({required this.written, required this.binDirOnPath});

  /// Shim names (re)written this run — empty when everything was current.
  final List<String> written;

  /// Whether the shim directory appears in `PATH` (the guidance signal for
  /// doctor, docs/04 §3.7).
  final bool binDirOnPath;
}

/// Installs/refreshes the `flutter` and `dart` shims in the store's bin
/// dir (docs/06 §8). Idempotent: current shims are left untouched, so
/// calling this on every CLI start is free.
final class ShimInstaller {
  ShimInstaller({required this.binDir, Map<String, String>? environment})
    : _env = environment ?? Platform.environment;

  final String binDir;
  final Map<String, String> _env;

  static const tools = ['flutter', 'dart'];

  Future<Result<ShimStatus>> ensure() async {
    if (Platform.isWindows) {
      // Windows shims (.bat/.exe with junctions) land with M1.11.
      return const Result.ok(ShimStatus(written: [], binDirOnPath: false));
    }
    final written = <String>[];
    try {
      await Directory(binDir).create(recursive: true);
      for (final tool in tools) {
        final file = File(p.join(binDir, tool));
        final content = posixShim(tool);
        if (file.existsSync() && await file.readAsString() == content) {
          continue;
        }
        await file.writeAsString(content);
        final chmod = await Process.run('chmod', ['755', file.path]);
        if (chmod.exitCode != 0) {
          return Result.err(
            StorageFailure(
              code: 'FX-STORE-007',
              message: 'cannot mark shim executable: ${chmod.stderr}',
            ),
          );
        }
        written.add(tool);
      }
    } on FileSystemException catch (e) {
      return Result.err(
        StorageFailure(
          code: 'FX-STORE-007',
          message: 'cannot install shims into $binDir: ${e.message}',
        ),
      );
    }
    return Result.ok(
      ShimStatus(written: written, binDirOnPath: _binDirOnPath()),
    );
  }

  bool _binDirOnPath() {
    final path = _env['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    return path.split(separator).contains(binDir);
  }

  /// The copy-pasteable PATH snippet doctor prints (docs/04 §3.7).
  String pathGuidance() => 'export PATH="$binDir:\$PATH"';
}
