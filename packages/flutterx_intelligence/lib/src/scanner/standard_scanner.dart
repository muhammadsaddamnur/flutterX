import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/flutterx_yaml_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/fvm_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/puro_extractor.dart';

/// The pin-level extractors available since M1.10 (FlutterX intent +
/// FVM/Puro migration). M2.1 appends pubspec, lockfile, `.metadata`, and
/// CI extractors to the same pipeline.
List<EvidenceExtractor> standardPinExtractors() => [
  FlutterxYamlExtractor(),
  FvmExtractor(),
  PuroExtractor(),
];

/// [ProjectScanner] as an extractor pipeline (docs/03 §2.3): each
/// registered extractor contributes evidence, results are merged, and a
/// cross-extractor conflicting-pins warning is attached. Pure — extraction
/// never throws; problems surface as [ScanWarning]s (fail-soft).
final class StandardProjectScanner implements ProjectScanner {
  StandardProjectScanner({List<EvidenceExtractor>? extractors})
    : _extractors = extractors ?? standardPinExtractors();

  final List<EvidenceExtractor> _extractors;

  @override
  ProjectEvidence scan(EvidenceFiles files) {
    final pins = <PinEvidence>[];
    final hard = <ConstraintEvidence>[];
    final hints = <HintEvidence>[];
    final warnings = <ScanWarning>[];

    for (final extractor in _extractors) {
      if (!extractor.appliesTo(files)) continue;
      final result = extractor.extract(files);
      pins.addAll(result.pins);
      hard.addAll(result.hard);
      hints.addAll(result.hints);
      warnings.addAll(result.warnings);
    }

    final merged = ProjectEvidence(
      pins: pins,
      hard: hard,
      hints: hints,
      warnings: warnings,
    );
    if (!merged.hasConflictingPins) return merged;

    // Conflicting pins: highest-priority source wins, but the disagreement
    // is always surfaced (docs/03 §2.3).
    final effective = merged.effectivePin!;
    final losers = pins
        .where((pin) => pin.version != effective.version)
        .map((pin) => '${pin.origin} says ${pin.version}')
        .join(', ');
    return ProjectEvidence(
      pins: pins,
      hard: hard,
      hints: hints,
      warnings: [
        ...warnings,
        ScanWarning(
          code: 'conflicting-pins',
          message:
              'pins disagree: using ${effective.version} '
              '(${effective.origin}); $losers',
        ),
      ],
    );
  }
}
