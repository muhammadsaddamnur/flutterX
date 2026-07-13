import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_platform/flutterx_platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Cross-platform [HostPlatform] coverage — deliberately runs on Windows
/// too (a package whose whole suite is `@TestOn('!windows')` reports
/// "no tests ran" and fails CI).
void main() {
  final platform = HostPlatform(storeHome: '/store');

  test('exec passes the child exit code through verbatim', () async {
    final ok = await platform.exec(Platform.resolvedExecutable, [
      '--version',
    ], inheritStdio: false);
    expect(ok, 0);
  });

  test('a missing executable is 127, not an exception', () async {
    final code = await platform.exec(
      'definitely-not-a-real-binary-xyz',
      const [],
      inheritStdio: false,
    );
    expect(code, 127);
  });

  test('host os and link mode are coherent', () {
    expect(platform.storeHome, '/store');
    if (Platform.isWindows) {
      expect(platform.os, TargetOs.windows);
      expect(platform.linkMode, LinkMode.junction);
    } else {
      expect(platform.os, isNot(TargetOs.windows));
      expect(platform.linkMode, LinkMode.symlink);
    }
  });

  test(
    'createLink materializes a working link (POSIX mechanism)',
    () async {
      final tmp = await Directory.systemTemp.createTemp('flutterx_hp_');
      addTearDown(() => tmp.delete(recursive: true));
      final target = Directory(p.join(tmp.path, 'target'))..createSync();
      File(p.join(target.path, 'marker')).writeAsStringSync('here');

      final result = await platform.createLink(
        targetPath: target.path,
        linkPath: p.join(tmp.path, 'link'),
      );
      expect(result.isOk, isTrue);
      expect(
        File(p.join(tmp.path, 'link', 'marker')).readAsStringSync(),
        'here',
      );
    },
    onPlatform: const {
      // Windows link creation needs the junction implementation (M1.11) —
      // unprivileged runners cannot create symlinks.
      'windows': Skip('junction-based createLink lands with M1.11'),
    },
  );
}
