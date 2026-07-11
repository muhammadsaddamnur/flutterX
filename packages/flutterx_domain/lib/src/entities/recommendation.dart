import 'package:flutterx_domain/src/entities/evidence.dart';
import 'package:flutterx_domain/src/entities/flutter_release.dart';
import 'package:flutterx_domain/src/entities/resolution.dart';
import 'package:flutterx_domain/src/values/confidence.dart';
import 'package:flutterx_domain/src/values/sem_ver.dart';

/// Per-candidate external signals the Recommendation Engine scores
/// (docs/03 §5.1). Computed by the application layer (some, like deep
/// dependency checks, need I/O) and injected — the engine stays pure.
final class Signals {
  Signals({
    required this.evidence,
    Map<SemVer, DependencyCompatibility> compatibility = const {},
    Set<SemVer> installed = const {},
    Map<SemVer, int> ruleModifiers = const {},
    DateTime? now,
  }) : compatibility = Map.unmodifiable(compatibility),
       installed = Set.unmodifiable(installed),
       ruleModifiers = Map.unmodifiable(ruleModifiers),
       now = now ?? DateTime.fromMillisecondsSinceEpoch(0);

  final ProjectEvidence evidence;

  /// Dependency Intelligence result per candidate version (docs/03 §6).
  final Map<SemVer, DependencyCompatibility> compatibility;

  /// Versions already provisioned locally (+8 tiebreaker).
  final Set<SemVer> installed;

  /// Net prefer/penalize score per version from the Rule Engine
  /// (docs/03 §4.1).
  final Map<SemVer, int> ruleModifiers;

  /// Injected clock for the recency signal — engines never read wall time
  /// themselves (docs/03 shared principles).
  final DateTime now;
}

/// Fast-mode compatibility summary for one candidate (docs/03 §6.1).
final class DependencyCompatibility {
  const DependencyCompatibility({
    required this.verified,
    required this.total,
    this.incompatible = const [],
    this.unverified = const [],
  });

  /// Packages proven compatible.
  final int verified;

  /// Total packages checked.
  final int total;

  /// Package names proven incompatible (any entry disqualifies in practice).
  final List<String> incompatible;

  /// Package names with unknown constraints (git/path deps, cache misses) —
  /// reduce the score, never block (docs/03 §6.2).
  final List<String> unverified;

  bool get hasIncompatible => incompatible.isNotEmpty;
}

/// A ranked candidate with its score trail.
final class ScoredCandidate {
  ScoredCandidate({
    required this.release,
    required this.score,
    required List<Reason> contributions,
  }) : contributions = List.unmodifiable(contributions);

  final FlutterRelease release;
  final int score;
  final List<Reason> contributions;
}

/// The Recommendation Engine's output (docs/03 §5.1).
final class Recommendation {
  Recommendation({
    required this.chosen,
    List<ScoredCandidate> alternatives = const [],
    required this.confidence,
  }) : alternatives = List.unmodifiable(alternatives);

  final ScoredCandidate chosen;

  /// Up to the next 2 ranked candidates, for "alternatives" output.
  final List<ScoredCandidate> alternatives;

  final Confidence confidence;
}
