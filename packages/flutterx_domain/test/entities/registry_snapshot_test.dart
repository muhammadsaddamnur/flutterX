import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

FlutterRelease release(
  String version, {
  Channel channel = Channel.stable,
  String? dart,
  bool retracted = false,
}) {
  return FlutterRelease(
    version: SemVer.parse(version),
    channel: channel,
    gitTag: version,
    frameworkSha: 'sha-$version',
    dartVersion: SemVer.parse(dart ?? '3.4.3'),
    releasedAt: DateTime.utc(2026, 1, 1),
    artifacts: const {},
    retracted: retracted,
  );
}

void main() {
  final snapshot = RegistrySnapshot(
    // Deliberately unsorted input — the snapshot must sort descending.
    releases: [
      release('3.19.6', dart: '3.3.4'),
      release('3.24.1', dart: '3.5.1'),
      release('3.22.2'),
      release('3.22.1'),
      release('3.22.3', retracted: true),
      release('3.25.0-1.2.pre', channel: Channel.beta),
    ],
    fetchedAt: DateTime.utc(2026, 7, 11),
    source: 'test',
  );

  test('releases are sorted newest first regardless of input order', () {
    final versions = snapshot.releases.map((r) => r.version.toString());
    expect(versions, [
      '3.25.0-1.2.pre',
      '3.24.1',
      '3.22.3',
      '3.22.2',
      '3.22.1',
      '3.19.6',
    ]);
  });

  group('find', () {
    test('returns the exact release', () {
      expect(snapshot.find(SemVer.parse('3.22.2'))?.gitTag, '3.22.2');
    });

    test('returns null when absent', () {
      expect(snapshot.find(SemVer.parse('9.9.9')), isNull);
    });
  });

  group('resolveSpecifier', () {
    test('exact version resolves even when retracted', () {
      // Exact lookups are explicit user intent; the deny-retracted rule and
      // --force handle the policy side (docs/03 §1.2).
      expect(snapshot.resolveSpecifier('3.22.3')?.retracted, isTrue);
    });

    test('partial version resolves to latest non-retracted patch', () {
      expect(
        snapshot.resolveSpecifier('3.22')?.version,
        SemVer.parse('3.22.2'),
      );
    });

    test('channel name resolves to newest release of that channel', () {
      expect(
        snapshot.resolveSpecifier('stable')?.version,
        SemVer.parse('3.24.1'),
      );
      expect(
        snapshot.resolveSpecifier('beta')?.version,
        SemVer.parse('3.25.0-1.2.pre'),
      );
    });

    test('latest resolves to newest stable', () {
      expect(
        snapshot.resolveSpecifier('latest')?.version,
        SemVer.parse('3.24.1'),
      );
    });

    test('unknown specifiers return null', () {
      expect(snapshot.resolveSpecifier('nope'), isNull);
      expect(snapshot.resolveSpecifier('3'), isNull);
      expect(snapshot.resolveSpecifier('3.99'), isNull);
      expect(snapshot.resolveSpecifier('9.9.9'), isNull);
    });
  });
}
