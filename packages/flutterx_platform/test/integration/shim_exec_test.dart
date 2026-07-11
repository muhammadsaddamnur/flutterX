@TestOn('!windows')
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutterx_platform/flutterx_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end shim behavior (T1.7.5, docs/02 §8.3): a linked project runs
/// the real tool through the shim; unresolved directories get the hint;
/// store-mutating commands are intercepted.
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
    p.join(binDir, tool),
    args,
    workingDirectory: cwd ?? projectDir,
    environment: env,
  );

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_shim_e2e_');
    binDir = p.join(tmp.path, 'store', 'bin');
    await ShimInstaller(binDir: binDir).ensure();

    // Fake SDK: bin/flutter + bin/dart that print their identity — the
    // shim's job ends at exec'ing them with argv intact.
    final sdkDir = p.join(tmp.path, 'store', 'versions', '3.22.2');
    for (final tool in ['flutter', 'dart']) {
      final file = File(p.join(sdkDir, 'bin', tool));
      await file.create(recursive: true);
      await file.writeAsString(
        '#!/bin/sh\necho "fake-$tool 3.22.2 args:\$*"\n',
      );
      await Process.run('chmod', ['755', file.path]);
    }

    // Linked project (what `flutterx use` produces via linkSdk).
    projectDir = p.join(tmp.path, 'work', 'app');
    await Directory(p.join(projectDir, '.flutterx')).create(recursive: true);
    await Link(p.join(projectDir, '.flutterx', 'sdk')).create(sdkDir);
  });

  tearDownAll(() => tmp.delete(recursive: true));

  test('flutter shim execs the project SDK with argv passthrough', () async {
    final result = await shim('flutter', ['run', '--flavor', 'dev']);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('fake-flutter 3.22.2'));
    expect(result.stdout, contains('args:run --flavor dev'));
  });

  test('dart shim resolves through the same link', () async {
    final result = await shim('dart', ['--version']);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('fake-dart 3.22.2'));
  });

  test('works from a nested directory (walk-up)', () async {
    final nested = Directory(p.join(projectDir, 'lib', 'src'))
      ..createSync(recursive: true);
    final result = await shim('flutter', ['--version'], cwd: nested.path);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('fake-flutter'));
  });

  test(
    'unresolved directory → one-line hint, non-zero exit (cold path)',
    () async {
      final outside = Directory(p.join(tmp.path, 'elsewhere'))..createSync();
      final result = await shim('flutter', ['run'], cwd: outside.path);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('no resolved SDK'));
      expect(result.stderr, contains('flutterx use'));
    },
  );

  test(
    'flutter upgrade is intercepted in managed projects (docs/05 §4.3)',
    () async {
      final result = await shim('flutter', ['upgrade']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('flutterx upgrade'));
      expect(result.stderr, contains('FLUTTERX_UNMANAGED=1'));
    },
  );

  test('FLUTTERX_UNMANAGED=1 bypasses the interception', () async {
    final result = await shim(
      'flutter',
      ['upgrade'],
      env: {'FLUTTERX_UNMANAGED': '1'},
    );
    expect(result.exitCode, 0);
    expect(result.stdout, contains('args:upgrade'));
  });

  test('broken sdk link → repair hint, not a confusing exec error', () async {
    final broken = p.join(tmp.path, 'work', 'broken');
    await Directory(p.join(broken, '.flutterx')).create(recursive: true);
    await Link(
      p.join(broken, '.flutterx', 'sdk'),
    ).create(p.join(tmp.path, 'gone'));
    final result = await shim('flutter', ['run'], cwd: broken);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('flutterx repair'));
  });
}
