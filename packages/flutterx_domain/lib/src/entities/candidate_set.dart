import 'package:flutterx_domain/src/entities/evidence.dart';
import 'package:flutterx_domain/src/entities/flutter_release.dart';

/// One narrowing step in the solve, recorded for explanations
/// (docs/03 §3.1: "record |C| after each step").
final class TraceStep {
  const TraceStep({required this.description, required this.remaining});

  /// What was applied, e.g. `Dart >=3.3.0 <4.0.0 (pubspec.yaml)`.
  final String description;

  /// Candidate count after this step.
  final int remaining;

  @override
  String toString() => '$description → $remaining candidate(s)';
}

/// The ordered narrowing history behind a candidate set.
final class ProvenanceTrace {
  ProvenanceTrace({List<TraceStep> steps = const []})
    : steps = List.unmodifiable(steps);

  final List<TraceStep> steps;
}

/// The Version Solver's output: releases that *can* work (docs/03 §3).
final class CandidateSet {
  CandidateSet({
    required List<FlutterRelease> candidates,
    required this.trace,
    this.pinProvenance,
  }) : candidates = List.unmodifiable(candidates);

  /// A set narrowed from the full registry by constraint intersection.
  factory CandidateSet.solved(
    List<FlutterRelease> candidates,
    ProvenanceTrace trace,
  ) => CandidateSet(candidates: candidates, trace: trace);

  /// A single-release set produced by an explicit pin (docs/03 §3.1).
  factory CandidateSet.pinned(FlutterRelease release, PinEvidence pin) =>
      CandidateSet(
        candidates: [release],
        trace: ProvenanceTrace(
          steps: [
            TraceStep(
              description: 'pin ${pin.version} (${pin.origin})',
              remaining: 1,
            ),
          ],
        ),
        pinProvenance: pin,
      );

  /// An empty set — the trace shows which constraint zeroed it
  /// (docs/03 §3.2).
  factory CandidateSet.empty(ProvenanceTrace conflictTrace) =>
      CandidateSet(candidates: const [], trace: conflictTrace);

  /// Candidates, newest first (inherits registry ordering).
  final List<FlutterRelease> candidates;

  final ProvenanceTrace trace;

  /// Set when this came from a pin rather than solving.
  final PinEvidence? pinProvenance;

  bool get isEmpty => candidates.isEmpty;
  bool get isPinned => pinProvenance != null;
}
