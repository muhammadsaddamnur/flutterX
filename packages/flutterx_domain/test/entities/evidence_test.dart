import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

void main() {
  PinEvidence pin(EvidenceSource source, String version, String origin) =>
      PinEvidence(
        source: source,
        version: SemVer.parse(version),
        origin: origin,
      );

  group('ProjectEvidence.effectivePin', () {
    test('null when unpinned', () {
      expect(ProjectEvidence().effectivePin, isNull);
    });

    test('highest-priority source wins (docs/03 §2.3)', () {
      final evidence = ProjectEvidence(
        pins: [
          pin(EvidenceSource.fvmConfig, '3.19.0', '.fvmrc'),
          pin(EvidenceSource.flutterxYaml, '3.22.2', 'flutterx.yaml'),
          pin(EvidenceSource.puroConfig, '3.16.0', '.puro.json'),
        ],
      );
      expect(evidence.effectivePin?.version, SemVer.parse('3.22.2'));
      expect(evidence.effectivePin?.origin, 'flutterx.yaml');
    });
  });

  group('ProjectEvidence.hasConflictingPins', () {
    test('true when pins disagree', () {
      final evidence = ProjectEvidence(
        pins: [
          pin(EvidenceSource.fvmConfig, '3.19.0', '.fvmrc'),
          pin(EvidenceSource.flutterxYaml, '3.22.2', 'flutterx.yaml'),
        ],
      );
      expect(evidence.hasConflictingPins, isTrue);
    });

    test('false when pins agree or there is at most one', () {
      expect(ProjectEvidence().hasConflictingPins, isFalse);
      final agreeing = ProjectEvidence(
        pins: [
          pin(EvidenceSource.fvmConfig, '3.22.2', '.fvmrc'),
          pin(EvidenceSource.flutterxYaml, '3.22.2', 'flutterx.yaml'),
        ],
      );
      expect(agreeing.hasConflictingPins, isFalse);
    });
  });

  test('EvidenceFiles lookup', () {
    final files = EvidenceFiles(files: {'pubspec.yaml': 'name: app'});
    expect(files['pubspec.yaml'], 'name: app');
    expect(files['.fvmrc'], isNull);
    expect(files.contains('pubspec.yaml'), isTrue);
  });

  test(
    'EvidenceSource priorities follow the strength table (docs/03 §2.1)',
    () {
      final ordered = [...EvidenceSource.values]
        ..sort((a, b) => a.priority.compareTo(b.priority));
      expect(ordered.first, EvidenceSource.resolutionLock);
      expect(ordered.last, EvidenceSource.globalDefault);
    },
  );
}
