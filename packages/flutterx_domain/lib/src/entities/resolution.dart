import 'package:flutterx_domain/src/entities/flutter_release.dart';
import 'package:flutterx_domain/src/values/confidence.dart';

/// One explainable contribution to a decision (docs/03 §5.1): shown by
/// `--explain` and serialized into the lockfile.
final class Reason {
  const Reason({required this.text, this.delta = 0});

  /// Human-readable explanation, e.g. `.metadata says project created with
  /// 3.22.x`.
  final String text;

  /// Score contribution; 0 for non-scored reasons (pins, notes).
  final int delta;

  @override
  String toString() =>
      delta == 0 ? text : '${delta > 0 ? '+' : ''}$delta  $text';
}

/// How a resolution came to be — recorded in the lockfile (docs/03 §7).
enum ResolvedBy { resolve, use, migrate }

/// The final SDK decision for a project (docs/06 §2.1), serialized into
/// `.flutterx/resolution.lock` (docs/03 §7).
final class Resolution {
  Resolution({
    required this.chosen,
    required this.confidence,
    required List<Reason> reasons,
    required this.evidenceHash,
    required this.resolvedBy,
    required this.resolvedAt,
  }) : reasons = List.unmodifiable(reasons);

  final FlutterRelease chosen;
  final Confidence confidence;
  final List<Reason> reasons;

  /// sha256 over the evidence inputs; a mismatch later means the lock is
  /// stale (docs/03 §7, diagnosis FX-R02).
  final String evidenceHash;

  final ResolvedBy resolvedBy;
  final DateTime resolvedAt;
}
