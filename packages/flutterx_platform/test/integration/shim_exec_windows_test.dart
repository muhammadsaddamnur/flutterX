@TestOn('windows')
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutterx_platform/flutterx_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Windows twin of the POSIX shim E2E suite (T1.11.2): batch shims walk
/// up to the junction-linked SDK, pass argv through, intercept
/// store-mutating commands, and hint on the cold path.
void main() {
  late Directory tmp;
  late String binDir;
  late String projectDir;

  Future<ProcessResult> shim(
    String tool,
    List<String> args, {
    String? cwd,
    Map<String, String>? env,
  }) => Process.run(
    p.join(binDir, '$tool.bat'),
    args,
    workingDirectory: cwd ?? projectDir,
    environment: env,
    runInShell: true,
  );

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_shim_win_');
    binDir = p.join(tmp.path, 'store', 'bin');
    await ShimInstaller(binDir: binDir).ensure();

    // Fake SDK: bin\flutter.bat + bin\dart.bat printing their identity.
    final sdkDir = p.join(tmp.path, 'store', 'versions', '3.22.2');
    for (final tool in ['flutter', 'dart']) {
      final file = File(p.join(sdkDir, 'bin', '$tool.bat'));
      await file.create(recursive: true);
      await file.writeAsString(
        '@echo off\r\necho fake-$tool 3.22.2 args:%*\r\n',
      );
    }

    // Junction-linked project (what linkSdk produces on Windows).
    projectDir = p.join(tmp.path, 'work', 'app');
    await Directory(p.join(projectDir, '.flutterx')).create(recursive: true);
    final mklink = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      p.join(projectDir, '.flutterx', 'sdk'),
      sdkDir,
    ]);
    expect(mklink.exitCode, 0, reason: '${mklink.stderr}');
  });

  tearDownAll(() => tmp.delete(recursive: true));

  test('flutter shim execs the project SDK with argv passthrough', () async {
    final result = await shim('flutter', ['run', '--flavor', 'dev']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('fake-flutter 3.22.2'));
    expect(result.stdout, contains('run --flavor dev'));
  });

  test('works from a nested directory (walk-up)', () async {
    final nested = Directory(p.join(projectDir, 'lib', 'src'))
      ..createSync(recursive: true);
    final result = await shim('flutter', ['--version'], cwd: nested.path);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('fake-flutter'));
  });

  test('unresolved directory → hint, non-zero exit (cold path)', () async {
    final outside = Directory(p.join(tmp.path, 'elsewhere'))..createSync();
    final result = await shim(
      'flutter',
      ['run'],
      cwd: outside.path,
      // Controlled PATH (shim dir + system dirs for cmd itself) so no real
      // flutter is found and the hint path is deterministic (shim v4 falls
      // through to the next tool on PATH otherwise).
      env: {
        'PATH':
            '$binDir;${Platform.environment['SystemRoot']}\\System32;'
            '${Platform.environment['SystemRoot']}',
        'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
      },
    );
    expect(result.exitCode, 1);
    expect(result.stderr, contains('no resolved SDK'));
  });

  test('unresolved dir falls through to the next real tool on PATH '
      '(shim v4)', () async {
    final systemDir = Directory(p.join(tmp.path, 'systembin'))
      ..createSync(recursive: true);
    await File(
      p.join(systemDir.path, 'flutter.bat'),
    ).writeAsString('@echo off\r\necho system-flutter args:%*\r\n');
    final outside = Directory(p.join(tmp.path, 'elsewhere2'))..createSync();
    final result = await shim(
      'flutter',
      ['--version'],
      cwd: outside.path,
      env: {
        'PATH':
            '$binDir;${systemDir.path};'
            '${Platform.environment['SystemRoot']}\\System32',
        'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('system-flutter args:--version'));
  });

  test('flutter upgrade is intercepted (docs/05 §4.3)', () async {
    final result = await shim('flutter', ['upgrade']);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('flutterx upgrade'));
  });

  test('FLUTTERX_UNMANAGED=1 bypasses the interception', () async {
    final result = await shim(
      'flutter',
      ['upgrade'],
      env: {'FLUTTERX_UNMANAGED': '1'},
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('upgrade'));
  });
}
