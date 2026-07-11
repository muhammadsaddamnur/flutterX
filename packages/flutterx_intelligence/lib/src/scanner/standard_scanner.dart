import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/ci_workflow_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/flutterx_yaml_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/fvm_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/metadata_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/pubspec_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/pubspec_lock_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/puro_extractor.dart';
import 'package:flutterx_intelligence/src/scanner/extractors/resolution_lock_extractor.dart';

/// The full evidence pipeline (docs/03 §2.1 sources 1–9). Order matters
/// only for project-kind classification (first non-unknown wins) — pin
/// precedence is by [EvidenceSource.priority], not list position.
/// `.metadata`'s explicit `project_type` outranks the pubspec heuristic.
List<EvidenceExtractor> standardExtractors() => [
  ResolutionLockExtractor(),
  FlutterxYamlExtractor(),
  FvmExtractor(),
  PuroExtractor(),
  MetadataExtractor(),
  PubspecExtractor(),
  PubspecLockExtractor(),
  CiWorkflowExtractor(),
];

/// The pin-level subset that shipped with M1.10 (migration reading).
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
    : _extractors = extractors ?? standardExtractors();

  final List<EvidenceExtractor> _extractors;

  @override
  ProjectEvidence scan(EvidenceFiles files) {
    final pins = <PinEvidence>[];
    final hard = <ConstraintEvidence>[];
    final hints = <HintEvidence>[];
    final warnings = <ScanWarning>[];
    var kind = ProjectKind.unknown;

    for (final extractor in _extractors) {
      if (!extractor.appliesTo(files)) continue;
      final result = extractor.extract(files);
      pins.addAll(result.pins);
      hard.addAll(result.hard);
      hints.addAll(result.hints);
      warnings.addAll(result.warnings);
      if (kind == ProjectKind.unknown) kind = result.kind;
    }

    final merged = ProjectEvidence(
      pins: pins,
      hard: hard,
      hints: hints,
      warnings: warnings,
      kind: kind,
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
      kind: kind,
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
