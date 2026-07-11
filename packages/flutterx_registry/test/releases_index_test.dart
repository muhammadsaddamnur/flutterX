import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_registry/flutterx_registry.dart';
// Same-package src import — only cross-package src imports are forbidden.
import 'package:flutterx_registry/src/seed_snapshot.g.dart' as seed;
import 'package:test/test.dart';

/// Contract tests over a recorded copy of the real index (docs/07 risk:
/// tolerant parsers). The fixture deliberately contains: arch duplicates,
/// a beta and a dev entry, a `v`-prefixed hotfix version, and entries
/// without a Dart mapping.
void main() {
  final fixture = File('test/fixtures/releases_macos.json').readAsStringSync();

  RegistrySnapshot parse({String arch = 'arm64'}) => parseReleasesIndex(
    fixture,
    os: TargetOs.macos,
    preferredArch: arch,
    fetchedAt: DateTime.utc(2026, 7, 11),
    source: 'fixture',
  );

  test('parses real entries with the Flutter↔Dart mapping', () {
    final snapshot = parse();
    final release = snapshot.find(SemVer.parse('3.22.2'))!;
    expect(release.dartVersion, SemVer.parse('3.4.3'));
    expect(release.channel, Channel.stable);
    expect(release.frameworkSha, isNotEmpty);
    expect(release.artifacts[TargetOs.macos]!.sha256, hasLength(64));
    expect(
      release.artifacts[TargetOs.macos]!.url.toString(),
      startsWith('https://storage.googleapis.com/'),
    );
  });

  test('dedupes arch variants preferring the host arch', () {
    final arm = parse().find(SemVer.parse('3.44.6'))!;
    expect(arm.artifacts[TargetOs.macos]!.url.toString(), contains('arm64'));
    final x64 = parse(arch: 'x64').find(SemVer.parse('3.44.6'))!;
    expect(
      x64.artifacts[TargetOs.macos]!.url.toString(),
      isNot(contains('arm64')),
    );
  });

  test('skips entries without a Dart mapping (unsolvable)', () {
    final versions = parse().releases.map((r) => r.version.toString());
    expect(versions, isNot(contains('1.12.13+hotfix.9')));
    expect(versions, isNot(contains('2.9.0-0.1.pre')));
  });

  test('keeps beta and archived dev channels when mapped', () {
    final channels = parse().releases.map((r) => r.channel).toSet();
    expect(channels, containsAll([Channel.beta, Channel.dev]));
  });

  test('the bundled seed parses and contains recent stable releases', () {
    final snapshot = parseReleasesIndex(
      seed.seedReleaseIndexes['macos']!,
      os: TargetOs.macos,
      preferredArch: 'arm64',
      fetchedAt: DateTime.utc(2026, 7, 11),
      source: 'seed',
    );
    expect(snapshot.releases.length, greaterThan(30));
    expect(snapshot.releases.any((r) => r.channel == Channel.stable), isTrue);
    expect(snapshot.resolveSpecifier('stable'), isNotNull);
  });
}
