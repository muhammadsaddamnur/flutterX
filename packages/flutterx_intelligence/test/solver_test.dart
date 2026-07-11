import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

FlutterRelease release(
  String version, {
  required String dart,
  Channel channel = Channel.stable,
}) => FlutterRelease(
  version: SemVer.parse(version),
  channel: channel,
  gitTag: version,
  frameworkSha: 'sha',
  dartVersion: SemVer.parse(dart),
  releasedAt: DateTime.utc(2026, 1, 1),
  artifacts: const {},
);

/// A miniature but realistic registry: the Dart↔Flutter mapping is what
/// solving pivots on (docs/03 §1.2).
final snapshot = RegistrySnapshot(
  releases: [
    release('3.24.1', dart: '3.5.1'),
    release('3.24.0', dart: '3.5.0'),
    release('3.22.2', dart: '3.4.3'),
    release('3.19.6', dart: '3.3.4'),
    release('3.16.9', dart: '3.2.6'),
    release('3.27.0-0.1.pre', dart: '3.7.0-1.0.beta', channel: Channel.beta),
  ],
  fetchedAt: DateTime.utc(2026, 7, 11),
  source: 'test',
);

ConstraintEvidence dartConstraint(
  String range, {
  String origin = 'pubspec.yaml',
}) => ConstraintEvidence(
  source: EvidenceSource.pubspecSdkConstraint,
  kind: ConstraintKind.dart,
  constraint: VersionConstraintX.parse(range),
  origin: origin,
);

ConstraintEvidence flutterConstraint(String range, {String origin = 'ci'}) =>
    ConstraintEvidence(
      source: EvidenceSource.pubspecFlutterConstraint,
      kind: ConstraintKind.flutter,
      constraint: VersionConstraintX.parse(range),
      origin: origin,
    );

PinEvidence pin(String version, {String origin = 'flutterx.yaml'}) =>
    PinEvidence(
      source: EvidenceSource.flutterxYaml,
      version: SemVer.parse(version),
      origin: origin,
    );

void main() {
  final solver = StandardVersionSolver();

  group('pin path (T2.2.1)', () {
    test('a registry-valid pin decides outright', () {
      final set = solver.solve(
        ProjectEvidence(pins: [pin('3.22.2')]),
        snapshot,
      );
      expect(set.isPinned, isTrue);
      expect(set.candidates.single.version, SemVer.parse('3.22.2'));
      expect(set.trace.steps.single.description, contains('pin 3.22.2'));
    });

    test('an unknown pin records FX-SOLVE-001 and solving continues', () {
      final set = solver.solve(
        ProjectEvidence(
          pins: [pin('3.21.9')],
          hard: [dartConstraint('>=3.4.0 <4.0.0')],
        ),
        snapshot,
      );
      expect(set.isPinned, isFalse);
      expect(set.trace.steps.first.description, contains('FX-SOLVE-001'));
      expect(set.candidates, isNotEmpty);
    });
  });

  group('constraint intersection (T2.2.2)', () {
    test('Dart constraints translate through the registry mapping', () {
      final set = solver.solve(
        ProjectEvidence(hard: [dartConstraint('>=3.4.0 <3.5.0')]),
        snapshot,
      );
      expect(
        set.candidates.map((r) => '${r.version}'),
        ['3.22.2'],
        reason: 'only 3.22.2 bundles a Dart in [3.4.0, 3.5.0)',
      );
    });

    test('multiple constraints narrow in order, |C| recorded per step', () {
      final set = solver.solve(
        ProjectEvidence(
          hard: [
            dartConstraint('>=3.3.0 <4.0.0'),
            flutterConstraint('<3.24.0'),
          ],
        ),
        snapshot,
      );
      expect(set.candidates.map((r) => '${r.version}'), ['3.22.2', '3.19.6']);
      expect(set.trace.steps, hasLength(3)); // start + 2 constraints
      expect(set.trace.steps[0].remaining, 6);
      expect(set.trace.steps[1].remaining, 5, reason: 'Dart >=3.3 keeps 5');
      expect(set.trace.steps[2].remaining, 2);
    });

    test('no constraints → the whole registry is the candidate set', () {
      final set = solver.solve(ProjectEvidence(), snapshot);
      expect(set.candidates, hasLength(6));
      expect(set.isEmpty, isFalse);
    });
  });

  group('edge cases (T2.2.4, docs/03 §3.2)', () {
    test('`any` contributes nothing but is noted in the trace', () {
      final set = solver.solve(
        ProjectEvidence(
          hard: [
            ConstraintEvidence(
              source: EvidenceSource.pubspecSdkConstraint,
              kind: ConstraintKind.dart,
              constraint: VersionConstraintX.any,
              origin: 'pubspec.yaml',
            ),
          ],
        ),
        snapshot,
      );
      expect(set.candidates, hasLength(6));
      expect(set.trace.steps.last.description, contains('contributes nothing'));
    });

    test('pre-release lower bound admits beta-channel Dart versions', () {
      final set = solver.solve(
        ProjectEvidence(hard: [dartConstraint('>=3.6.0-0')]),
        snapshot,
      );
      expect(set.candidates.single.channel, Channel.beta);
    });

    test('registry gap: only beta satisfies → beta candidates surface '
        '(rules decide later)', () {
      final set = solver.solve(
        ProjectEvidence(hard: [dartConstraint('>=3.7.0-0 <3.8.0')]),
        snapshot,
      );
      expect(set.candidates.single.version, SemVer.parse('3.27.0-0.1.pre'));
    });
  });

  group('conflict explanation (T2.2.3)', () {
    test('minimal conflicting pair with Dart→Flutter translation', () {
      final evidence = ProjectEvidence(
        hard: [
          dartConstraint('>=3.5.0', origin: 'pubspec.yaml'),
          flutterConstraint('<3.22.0', origin: '.github/workflows/build.yml'),
          // A third, innocent constraint must not be blamed.
          dartConstraint('<4.0.0', origin: 'pubspec.lock sdks.dart'),
        ],
      );
      final set = solver.solve(evidence, snapshot);
      expect(set.isEmpty, isTrue);

      final conflict = solver.explainEmpty(evidence, snapshot);
      expect(conflict.conflictingSourceA, 'pubspec.yaml');
      expect(conflict.conflictingSourceB, '.github/workflows/build.yml');
      // Dart >=3.5.0 admits stable 3.24.x and the 3.27 beta.
      expect(
        conflict.message,
        contains('→ Flutter 3.24.0…3.27.0-0.1.pre'),
        reason: 'Dart constraints are translated for humans',
      );
      expect(conflict.nextActions.single, contains('pubspec.yaml'));
    });

    test('a single unsatisfiable constraint conflicts with the registry', () {
      final evidence = ProjectEvidence(
        hard: [dartConstraint('>=9.0.0', origin: 'pubspec.yaml')],
      );
      final conflict = solver.explainEmpty(evidence, snapshot);
      expect(conflict.conflictingSourceB, 'registry');
      expect(conflict.nextActions.first, contains('cache refresh'));
    });
  });
}
