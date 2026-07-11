@Tags(['live'])
library;

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_registry/flutterx_registry.dart';
import 'package:test/test.dart';

/// Nightly contract test against the real Flutter infrastructure
/// (docs/07 risks: "contract tests hitting real endpoints nightly").
/// Excluded from normal runs; executed by the nightly workflow via
/// `dart test --tags=live`.
void main() {
  test(
    'the live releases index still matches our parsing contract',
    () async {
      for (final os in TargetOs.values) {
        final fetched = await ReleasesClient().fetch(os);
        expect(fetched.isOk, isTrue, reason: '${fetched.failureOrNull}');
        final body = (fetched.valueOrNull! as FetchedBody).body;
        final snapshot = parseReleasesIndex(
          body,
          os: os,
          preferredArch: 'arm64',
          fetchedAt: DateTime.now().toUtc(),
          source: 'live',
        );
        expect(
          snapshot.releases.length,
          greaterThan(100),
          reason: '$os index parsed suspiciously small',
        );
        final stable = snapshot.resolveSpecifier('stable')!;
        expect(
          stable.artifacts[os],
          isNotNull,
          reason: 'newest stable must carry a downloadable artifact',
        );
        expect(stable.dartVersion.major, greaterThanOrEqualTo(3));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
