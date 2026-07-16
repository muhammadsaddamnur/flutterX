import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// Bump when the shim template changes — the installer rewrites any shim
/// whose embedded version differs.
const shimVersion = 4;

/// Windows batch shim (docs/05 §8): same contract as [posixShim] — walk up
/// to `.flutterx\sdk`, intercept store-mutating commands, exec passthrough
/// with argv intact (`%*`); Ctrl-C reaches console children natively.
String batchShim(String tool) =>
    '''
@echo off\r
rem FlutterX shim v$shimVersion for '$tool' — generated; do not edit.\r
setlocal\r
\r
if not "$tool"=="flutter" goto walkstart\r
if defined FLUTTERX_UNMANAGED goto walkstart\r
if /I "%~1"=="upgrade" goto intercept\r
if /I "%~1"=="downgrade" goto intercept\r
if /I "%~1"=="channel" goto intercept\r
goto walkstart\r
\r
:intercept\r
echo flutterx: 'flutter %~1' would mutate the managed SDK store. 1>&2\r
echo   use 'flutterx upgrade' instead, or set FLUTTERX_UNMANAGED=1 1>&2\r
exit /b 1\r
\r
:walkstart\r
set "DIR=%CD%"\r
:walk\r
if exist "%DIR%\\.flutterx\\sdk\\bin\\$tool.bat" (\r
  call "%DIR%\\.flutterx\\sdk\\bin\\$tool.bat" %*\r
  exit /b %ERRORLEVEL%\r
)\r
for %%I in ("%DIR%\\..") do set "PARENT=%%~fI"\r
if /I "%PARENT%"=="%DIR%" goto cold\r
set "DIR=%PARENT%"\r
goto walk\r
\r
:cold\r
rem Unresolved project: fall through to the next real '$tool' on PATH so\r
rem non-FlutterX projects keep working; hint only when nothing is found.\r
set "SELF_DIR=%~dp0"\r
if "%SELF_DIR:~-1%"=="\\" set "SELF_DIR=%SELF_DIR:~0,-1%"\r
for %%D in ("%PATH:;=" "%") do (\r
  if /I not "%%~D"=="%SELF_DIR%" (\r
    if exist "%%~D\\$tool.bat" (\r
      call "%%~D\\$tool.bat" %*\r
      exit /b %ERRORLEVEL%\r
    )\r
    if exist "%%~D\\$tool.exe" (\r
      "%%~D\\$tool.exe" %*\r
      exit /b %ERRORLEVEL%\r
    )\r
  )\r
)\r
echo flutterx: no resolved SDK for this directory (and no other '$tool' on PATH). 1>&2\r
echo   run 'flutterx resolve' or 'flutterx use ^<version^>' 1>&2\r
exit /b 1\r
''';

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

# Unresolved project: FlutterX has no opinion here — fall through to the
# next real '$tool' on PATH so non-FlutterX projects (and plain Dart
# repos) keep working. Only hint when there is nothing to fall back to.
self_dir="\$(cd "\$(dirname "\$0")" && pwd)"
old_ifs="\$IFS"; IFS=:
for path_dir in \$PATH; do
  [ "\$path_dir" = "\$self_dir" ] && continue
  if [ -x "\$path_dir/$tool" ] && [ ! -d "\$path_dir/$tool" ]; then
    IFS="\$old_ifs"
    exec "\$path_dir/$tool" "\$@"
  fi
done
IFS="\$old_ifs"

echo "flutterx: no resolved SDK for this directory (and no other '$tool' on PATH)." >&2
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
    final written = <String>[];
    try {
      await Directory(binDir).create(recursive: true);
      for (final tool in tools) {
        final shimName = Platform.isWindows ? '$tool.bat' : tool;
        final file = File(p.join(binDir, shimName));
        final content = Platform.isWindows ? batchShim(tool) : posixShim(tool);
        if (file.existsSync() && await file.readAsString() == content) {
          continue;
        }
        await file.writeAsString(content);
        if (!Platform.isWindows) {
          final chmod = await Process.run('chmod', ['755', file.path]);
          if (chmod.exitCode != 0) {
            return Result.err(
              StorageFailure(
                code: 'FX-STORE-007',
                message: 'cannot mark shim executable: ${chmod.stderr}',
              ),
            );
          }
        }
        written.add(shimName);
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
  String pathGuidance() => Platform.isWindows
      ? 'setx PATH "$binDir;%PATH%"'
      : 'export PATH="$binDir:\$PATH"';
}
