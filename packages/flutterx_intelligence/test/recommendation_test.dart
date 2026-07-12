import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 7, 11);

FlutterRelease release(
  String version, {
  String dart = '3.4.3',
  Channel channel = Channel.stable,
  DateTime? releasedAt,
}) => FlutterRelease(
  version: SemVer.parse(version),
  channel: channel,
  gitTag: version,
  frameworkSha: 'sha',
  dartVersion: SemVer.parse(dart),
  releasedAt: releasedAt ?? DateTime.utc(2026, 6, 1),
  artifacts: const {},
);

ConstraintEvidence hardConstraint() => ConstraintEvidence(
  source: EvidenceSource.pubspecSdkConstraint,
  kind: ConstraintKind.dart,
  constraint: VersionConstraintX.parse('>=3.3.0 <4.0.0'),
  origin: 'pubspec.yaml',
);

HintEvidence hint(String version, {bool exactPatch = false}) => HintEvidence(
  source: EvidenceSource.ciWorkflow,
  version: SemVer.parse(version),
  origin: '.github/workflows/build.yml',
  exactPatch: exactPatch,
);

CandidateSet solved(List<FlutterRelease> candidates) =>
    CandidateSet.solved(candidates, ProvenanceTrace());

void main() {
  final engine = StandardRecommendationEngine();

  group('scoring signals (T2.4.1, docs/03 §5.1 weight table)', () {
    test('every contribution is a Reason with its delta', () {
      final candidates = [release('3.22.2')];
      final recommendation = engine.rank(
        solved(candidates),
        Signals(
          evidence: ProjectEvidence(
            hard: [hardConstraint()],
            hints: [hint('3.22.2', exactPatch: true)],
          ),
          installed: {SemVer.parse('3.22.2')},
          compatibility: {
            SemVer.parse('3.22.2'): const DependencyCompatibility(
              verified: 41,
              total: 41,
            ),
          },
          ruleModifiers: {SemVer.parse('3.22.2'): 5},
          now: now,
        ),
      );
      final chosen = recommendation.chosen;
      final texts = chosen.contributions.map((r) => '${r.delta}:${r.text}');
      expect(
        texts,
        contains('30:.github/workflows/build.yml points at 3.22.2'),
      );
      expect(texts, contains('20:3.22.2 is the latest patch of its minor'));
      expect(texts, contains('40:41/41 packages verified compatible'));
      expect(texts, contains('15:stable channel'));
      expect(texts, contains('8:already installed'));
      expect(texts, contains('5:rule adjustments'));
      // recency: 40 days old, half-life 180 → 10 * 2^(-40/180) ≈ 9.
      expect(texts, contains('9:released 40 days ago'));
      expect(chosen.score, 30 + 20 + 40 + 15 + 8 + 5 + 9);
    });

    test('familiarity beats recency by design (docs/03 §10 scenario)', () {
      final old = release('3.19.6', releasedAt: DateTime.utc(2024, 5, 1));
      final fresh = release('3.22.2', releasedAt: DateTime.utc(2026, 7, 1));
      final recommendation = engine.rank(
        solved([fresh, old]),
        Signals(
          evidence: ProjectEvidence(
            hard: [hardConstraint()],
            hints: [
              hint('3.19.6', exactPatch: true), // CI pin
              hint('3.19.0'), // .metadata minor hint
            ],
          ),
          compatibility: {
            for (final v in ['3.19.6', '3.22.2'])
              SemVer.parse(v): const DependencyCompatibility(
                verified: 41,
                total: 41,
              ),
          },
          now: now,
        ),
      );
      expect(
        recommendation.chosen.release.version,
        SemVer.parse('3.19.6'),
        reason: 'two hint matches (+60) outweigh recency (+10 max)',
      );
      expect(
        recommendation.alternatives.single.release.version,
        SemVer.parse('3.22.2'),
      );
    });

    test('incompatible packages zero the compatibility contribution', () {
      final recommendation = engine.rank(
        solved([release('3.24.1')]),
        Signals(
          evidence: ProjectEvidence(hard: [hardConstraint()]),
          compatibility: {
            SemVer.parse('3.24.1'): const DependencyCompatibility(
              verified: 39,
              total: 41,
              incompatible: ['freezed'],
            ),
          },
          now: now,
        ),
      );
      final reason = recommendation.chosen.contributions.singleWhere(
        (r) => r.text.contains('incompatible'),
      );
      expect(reason.delta, 0);
      expect(reason.text, contains('freezed'));
    });
  });

  group('confidence (T2.4.2, docs/03 §5.2)', () {
    final a = release('3.22.2');
    final b = release('3.19.6', releasedAt: DateTime.utc(2024, 5, 1));

    Signals withEvidence(ProjectEvidence evidence) =>
        Signals(evidence: evidence, now: now);

    test('a pin is always high confidence', () {
      final pinned = CandidateSet.pinned(
        a,
        PinEvidence(
          source: EvidenceSource.flutterxYaml,
          version: a.version,
          origin: 'flutterx.yaml',
        ),
      );
      final recommendation = engine.rank(
        pinned,
        withEvidence(ProjectEvidence()),
      );
      expect(recommendation.confidence, Confidence.high);
      expect(
        recommendation.chosen.contributions.single.text,
        contains('pinned to 3.22.2 via flutterx.yaml'),
      );
    });

    test('single candidate with hard evidence → high', () {
      final recommendation = engine.rank(
        solved([a]),
        withEvidence(ProjectEvidence(hard: [hardConstraint()])),
      );
      expect(recommendation.confidence, Confidence.high);
    });

    test('only soft evidence → low, however clear the score gap', () {
      final recommendation = engine.rank(
        solved([a, b]),
        withEvidence(
          ProjectEvidence(hints: [hint('3.22.2', exactPatch: true)]),
        ),
      );
      expect(recommendation.confidence, Confidence.low);
    });

    test('hard evidence: gap ≥ 25 → high, otherwise medium', () {
      final wide = engine.rank(
        solved([a, b]),
        withEvidence(
          ProjectEvidence(
            hard: [hardConstraint()],
            hints: [hint('3.22.2', exactPatch: true)],
          ),
        ),
      );
      expect(wide.confidence, Confidence.high);

      final narrow = engine.rank(
        solved([release('3.24.1'), release('3.24.0')]),
        withEvidence(ProjectEvidence(hard: [hardConstraint()])),
      );
      expect(narrow.confidence, Confidence.medium);
    });
  });

  group('determinism + explain (T2.4.3)', () {
    test('equal scores tiebreak on higher version', () {
      final recommendation = engine.rank(
        solved([release('3.22.1'), release('3.22.2')]),
        Signals(
          evidence: ProjectEvidence(hard: [hardConstraint()]),
          now: now,
        ),
      );
      // 3.22.2 gets latest-patch (+20); force a tie by comparing two
      // separate minors' latest patches instead:
      final tie = engine.rank(
        solved([release('3.24.0'), release('3.22.2')]),
        Signals(
          evidence: ProjectEvidence(hard: [hardConstraint()]),
          now: now,
        ),
      );
      expect(tie.chosen.release.version, SemVer.parse('3.24.0'));
      expect(recommendation.chosen.release.version, SemVer.parse('3.22.2'));
    });

    test('explainRecommendation renders the documented breakdown (golden)', () {
      final recommendation = engine.rank(
        solved([release('3.22.2'), release('3.19.6')]),
        Signals(
          evidence: ProjectEvidence(
            hard: [hardConstraint()],
            hints: [hint('3.22.2', exactPatch: true)],
          ),
          installed: {SemVer.parse('3.22.2')},
          now: now,
        ),
      );
      final text = explainRecommendation(recommendation);
      expect(
        text,
        stringContainsInOrder([
          'Resolved: Flutter 3.22.2 (Dart 3.4.3) — confidence: high',
          '+30  .github/workflows/build.yml points at 3.22.2',
          '+20  3.22.2 is the latest patch of its minor',
          '+15  stable channel',
          '─────',
          'total',
          'vs. 3.19.6 (score',
        ]),
      );
    });
  });

  group('weight config validation (T2.4.4)', () {
    test('valid overrides load', () {
      final result = RecommendationWeights.fromSettings(const {
        'recommend.weights.hintMatch': '50',
      });
      expect(result.valueOrNull!.hintMatch, 50);
      expect(result.valueOrNull!.latestPatch, 20, reason: 'default kept');
    });

    test('invalid values are rejected at load time (FX-CONF-002)', () {
      for (final bad in ['-5', 'ten', '']) {
        final result = RecommendationWeights.fromSettings({
          'recommend.weights.recencyMax': bad,
        });
        expect(result.failureOrNull?.code, 'FX-CONF-002', reason: '"$bad"');
      }
    });
  });
}
