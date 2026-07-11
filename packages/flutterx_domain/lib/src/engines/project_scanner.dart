import 'package:flutterx_domain/src/entities/evidence.dart';

/// Extracts evidence from injected file contents (docs/03 §2).
///
/// Pure: parses strings, never reads disk. Extraction never throws —
/// malformed input becomes a [ScanWarning] (fail-soft).
abstract interface class ProjectScanner {
  ProjectEvidence scan(EvidenceFiles files);
}

/// One pluggable step of the scanner pipeline (docs/02 §10.2): each
/// extractor understands one evidence source (pubspec, `.fvmrc`, a CI
/// system, …).
abstract interface class EvidenceExtractor {
  /// Stable id, e.g. `pubspec`, `fvm`, `github-actions`.
  String get id;

  bool appliesTo(EvidenceFiles files);

  /// Extracted evidence; parse problems surface as warnings inside the
  /// returned [ProjectEvidence], never as exceptions.
  ProjectEvidence extract(EvidenceFiles files);
}
