import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

FlutterRelease release(String version, {required String dart}) =>
    FlutterRelease(
      version: SemVer.parse(version),
      channel: Channel.stable,
      gitTag: version,
      frameworkSha: 'sha',
      dartVersion: SemVer.parse(dart),
      releasedAt: DateTime.utc(2026, 1, 1),
      artifacts: const {},
    );

PackageMeta meta(
  String name,
  String version, {
  String sdk = '>=3.0.0 <4.0.0',
  String? flutter,
}) => PackageMeta(
  name: name,
  version: SemVer.parse(version),
  dartConstraint: VersionConstraintX.parse(sdk),
  flutterConstraint: flutter == null ? null : VersionConstraintX.parse(flutter),
);

void main() {
  group('parseLockedPackages', () {
    test('reads the real fixture: hosted kept, sdk-source skipped', () {
      final packages = parseLockedPackages(
        File('test/fixtures/app_pubspec.lock').readAsStringSync(),
      );
      expect(packages.map((p) => p.name), ['cupertino_icons', 'riverpod']);
      expect(packages.every((p) => p.hosted), isTrue);
    });

    test('git and path dependencies are unhosted', () {
      final packages = parseLockedPackages('''
packages:
  my_fork:
    dependency: "direct main"
    description:
      path: "."
      ref: main
      url: "https://github.com/x/my_fork"
    source: git
    version: "1.2.3"
''');
      expect(packages.single.hosted, isFalse);
    });

    test('garbage input yields an empty list (fail-soft)', () {
      expect(parseLockedPackages('{{{{'), isEmpty);
      expect(parseLockedPackages(''), isEmpty);
    });
  });

  group('checkCompatibility (docs/03 §6.1)', () {
    final sdk = release('3.22.2', dart: '3.4.3');
    LockedPackage locked(String name, {bool hosted = true}) => LockedPackage(
      name: name,
      version: SemVer.parse('1.0.0'),
      hosted: hosted,
    );

    test('dart and flutter constraints both gate compatibility', () {
      final result = checkCompatibility(
        sdk,
        [locked('ok'), locked('needs-new-dart'), locked('needs-new-flutter')],
        (p) => switch (p.name) {
          'ok' => meta('ok', '1.0.0'),
          'needs-new-dart' => meta('needs-new-dart', '1.0.0', sdk: '>=3.5.0'),
          _ => meta(p.name, '1.0.0', flutter: '>=3.24.0'),
        },
      );
      expect(result.verified, 1);
      expect(result.incompatible, ['needs-new-dart', 'needs-new-flutter']);
      expect(result.hasIncompatible, isTrue);
    });

    test('git/path deps and cache misses are unverified, never blocking', () {
      final result = checkCompatibility(sdk, [
        locked('git-dep', hosted: false),
        locked('cache-miss'),
      ], (_) => null);
      expect(result.unverified, ['git-dep', 'cache-miss']);
      expect(result.incompatible, isEmpty);
      expect(result.total, 2);
    });
  });

  group('compatibility matrix (docs/03 §6.2)', () {
    test('builds the package × candidate grid', () {
      final candidates = [
        release('3.19.6', dart: '3.3.4'),
        release('3.24.1', dart: '3.5.1'),
      ];
      final matrix = buildCompatibilityMatrix(
        candidates,
        [
          LockedPackage(
            name: 'freezed',
            version: SemVer.parse('2.4.7'),
            hosted: true,
          ),
          LockedPackage(
            name: 'my_fork',
            version: SemVer.parse('1.0.0'),
            hosted: false,
          ),
        ],
        (p) => p.name == 'freezed'
            ? meta('freezed', '2.4.7', sdk: '>=3.0.0 <3.5.0')
            : null,
      );
      expect(matrix.candidates.map((v) => '$v'), ['3.19.6', '3.24.1']);
      expect(matrix.rows['freezed'], [
        PackageCompatibility.compatible,
        PackageCompatibility.incompatible,
      ]);
      expect(matrix.rows['my_fork'], [
        PackageCompatibility.unknown,
        PackageCompatibility.unknown,
      ]);
    });
  });
}
