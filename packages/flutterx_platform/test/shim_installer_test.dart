@TestOn('!windows')
library;

import 'dart:io';

import 'package:flutterx_platform/flutterx_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late ShimInstaller installer;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_shims_');
    installer = ShimInstaller(
      binDir: p.join(tmp.path, 'bin'),
      environment: {'PATH': '/usr/bin:/bin'},
    );
  });

  tearDown(() => tmp.delete(recursive: true));

  test('ensure writes executable flutter and dart shims', () async {
    final result = await installer.ensure();
    expect(result.valueOrNull!.written, ['flutter', 'dart']);
    for (final tool in ShimInstaller.tools) {
      final file = File(p.join(tmp.path, 'bin', tool));
      expect(file.existsSync(), isTrue);
      expect(await file.readAsString(), contains('FlutterX shim'));
      // Portable executable-bit check (BSD and GNU stat flags differ).
      expect(file.statSync().modeString(), 'rwxr-xr-x');
    }
  });

  test('ensure is idempotent — current shims are not rewritten', () async {
    await installer.ensure();
    final again = await installer.ensure();
    expect(again.valueOrNull!.written, isEmpty);
  });

  test('an outdated shim is refreshed', () async {
    await installer.ensure();
    final shim = File(p.join(tmp.path, 'bin', 'flutter'));
    await shim.writeAsString('#!/bin/sh\n# FlutterX shim v0 (old)\n');
    final result = await installer.ensure();
    expect(result.valueOrNull!.written, ['flutter']);
    expect(await shim.readAsString(), contains('shim v$shimVersion'));
  });

  test('reports whether the bin dir is on PATH', () async {
    expect((await installer.ensure()).valueOrNull!.binDirOnPath, isFalse);
    final onPath = ShimInstaller(
      binDir: p.join(tmp.path, 'bin'),
      environment: {'PATH': '${p.join(tmp.path, 'bin')}:/usr/bin'},
    );
    expect((await onPath.ensure()).valueOrNull!.binDirOnPath, isTrue);
    expect(onPath.pathGuidance(), contains('export PATH='));
  });
}
