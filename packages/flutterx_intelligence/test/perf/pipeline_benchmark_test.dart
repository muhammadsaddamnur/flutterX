@Tags(['perf'])
library;

import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

/// Nightly pipeline benchmark (T2.9.2, docs/05 §9 instrumentation): the
/// pure decision pipeline must stay effectively free — the perceptible
/// costs live in I/O (store, network), never in deciding.
///
/// Run: dart test --tags=perf test/perf  (nightly workflow)
void main() {
  test('scan→solve→rules→rank stays under 5ms per resolve (500-release '
      'registry, averaged)', () {
    // A registry an order of magnitude beyond reality (~500 releases vs
    // ~400 historic incl. per-arch duplicates already deduped).
    final releases = [
      for (var minor = 0; minor < 50; minor++)
        for (var patch = 0; patch < 10; patch++)
          FlutterRelease(
            version: SemVer.parse('3.$minor.$patch'),
            channel: Channel.stable,
            gitTag: '3.$minor.$patch',
            frameworkSha: 'sha',
            dartVersion: SemVer.parse('3.${minor ~/ 2}.$patch'),
            releasedAt: DateTime.utc(
              2024,
              1,
              1,
            ).add(Duration(days: minor * 14 + patch)),
            artifacts: const {},
          ),
    ];
    final snapshot = RegistrySnapshot(
      releases: releases,
      fetchedAt: DateTime.utc(2026, 7, 13),
      source: 'benchmark',
    );
    final files = EvidenceFiles(
      files: const {
        'pubspec.yaml': 'name: bench\nenvironment:\n  sdk: ">=3.10.0 <4.0.0"\n',
        '.github/workflows/ci.yml': "flutter-version: '3.30.5'",
      },
    );

    const iterations = 200;
    final scanner = StandardProjectScanner();
    final solver = StandardVersionSolver();
    final engine = RuleEngine(buildRules(const {}));
    final recommender = StandardRecommendationEngine();
    final now = DateTime.utc(2026, 7, 13);

    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      final evidence = scanner.scan(files);
      final solved = solver.solve(evidence, snapshot);
      final ruled = engine.apply(
        solved.candidates,
        RuleContext(
          evidence: evidence,
          newestKnown: releases.last,
          now: now,
          candidates: solved.candidates,
        ),
      );
      recommender.rank(
        CandidateSet.solved(ruled.allowed, solved.trace),
        Signals(evidence: evidence, ruleModifiers: ruled.modifiers, now: now),
      );
    }
    stopwatch.stop();

    final perResolveMicros = stopwatch.elapsedMicroseconds / iterations;
    stdout.writeln(
      'pipeline: ${perResolveMicros.toStringAsFixed(0)} µs/resolve '
      '(${releases.length} releases, $iterations iterations)',
    );
    expect(
      perResolveMicros,
      lessThan(5000),
      reason: 'the pure pipeline must stay effectively free',
    );
  });
}
