import 'package:flutterx_domain/src/entities/project.dart';
import 'package:flutterx_domain/src/values/sem_ver.dart';
import 'package:flutterx_domain/src/values/version_constraint_x.dart';

/// The raw file contents the application layer collects for the Scanner
/// (docs/02 §6: the Scanner parses content, it never reads files).
///
/// [files] maps a project-root-relative path (e.g. `pubspec.yaml`,
/// `.github/workflows/build.yml`) to its text content. Only files that exist
/// are present.
final class EvidenceFiles {
  EvidenceFiles({required Map<String, String> files})
    : files = Map.unmodifiable(files);

  final Map<String, String> files;

  String? operator [](String relativePath) => files[relativePath];

  bool contains(String relativePath) => files.containsKey(relativePath);
}

/// Which project file a piece of evidence came from, ordered by strength
/// (docs/03 §2.1). Lower [priority] wins among pins.
enum EvidenceSource {
  resolutionLock(1),
  flutterxYaml(2),
  fvmConfig(3),
  puroConfig(4),
  pubspecSdkConstraint(5),
  pubspecFlutterConstraint(6),
  pubspecLock(7),
  metadataFile(8),
  ciWorkflow(9),
  globalDefault(10);

  const EvidenceSource(this.priority);
  final int priority;
}

/// An exact prior decision or explicit pin (sources 1–4, docs/03 §2.1).
final class PinEvidence {
  const PinEvidence({
    required this.source,
    required this.version,
    required this.origin,
  });

  final EvidenceSource source;
  final SemVer version;

  /// Human-readable origin for explanations, e.g. `.fvmrc`.
  final String origin;
}

/// Whether a hard constraint is written against the Dart or the Flutter SDK
/// — the solver translates Dart constraints through the registry mapping
/// (docs/03 §3.1).
enum ConstraintKind { dart, flutter }

/// A hard version constraint (sources 5–7, docs/03 §2.1).
final class ConstraintEvidence {
  const ConstraintEvidence({
    required this.source,
    required this.kind,
    required this.constraint,
    required this.origin,
  });

  final EvidenceSource source;
  final ConstraintKind kind;
  final VersionConstraintX constraint;
  final String origin;
}

/// A soft version hint (sources 8–9, docs/03 §2.1). Hints never constrain;
/// they contribute score in the Recommendation Engine (+30 per match,
/// docs/03 §5.1).
final class HintEvidence {
  const HintEvidence({
    required this.source,
    required this.version,
    required this.origin,
    this.exactPatch = false,
  });

  final EvidenceSource source;
  final SemVer version;
  final String origin;

  /// `true` when the hint names an exact release (CI pin) rather than a
  /// minor series (`.metadata`).
  final bool exactPatch;
}

/// A non-fatal problem found while scanning (docs/03 §2.3): malformed YAML,
/// conflicting pins, etc. Warnings are always shown; they never stop the
/// pipeline (fail-soft principle).
final class ScanWarning {
  const ScanWarning({required this.code, required this.message, this.origin});

  /// Stable warning code, e.g. `conflicting-pins`, `malformed-yaml`.
  final String code;
  final String message;
  final String? origin;

  @override
  String toString() =>
      origin == null ? '$code: $message' : '$code ($origin): $message';
}

/// Everything the Scanner extracted from a project (docs/03 §2.2).
final class ProjectEvidence {
  ProjectEvidence({
    List<PinEvidence> pins = const [],
    List<ConstraintEvidence> hard = const [],
    List<HintEvidence> hints = const [],
    this.kind = ProjectKind.unknown,
    List<ScanWarning> warnings = const [],
  }) : pins = List.unmodifiable(pins),
       hard = List.unmodifiable(hard),
       hints = List.unmodifiable(hints),
       warnings = List.unmodifiable(warnings);

  final List<PinEvidence> pins;
  final List<ConstraintEvidence> hard;
  final List<HintEvidence> hints;
  final ProjectKind kind;
  final List<ScanWarning> warnings;

  /// The winning pin (lowest priority number), or `null` when unpinned.
  PinEvidence? get effectivePin {
    PinEvidence? best;
    for (final pin in pins) {
      if (best == null || pin.source.priority < best.source.priority) {
        best = pin;
      }
    }
    return best;
  }

  bool get hasConflictingPins => pins.map((p) => p.version).toSet().length > 1;
}
