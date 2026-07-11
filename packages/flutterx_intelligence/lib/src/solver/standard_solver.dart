import 'package:flutterx_domain/flutterx_domain.dart';

/// [VersionSolver] per docs/03 §3: honors the effective pin, otherwise
/// intersects the hard constraints over the registry — Dart constraints
/// translate through each release's bundled Dart version — recording |C|
/// after every step for explanations. No SAT machinery: constraints are
/// intersections over one variable (docs/03 §3.1).
final class StandardVersionSolver implements VersionSolver {
  @override
  CandidateSet solve(ProjectEvidence evidence, RegistrySnapshot snapshot) {
    final steps = <TraceStep>[];

    // Pin path (docs/03 §3.1): a registry-valid pin decides outright; an
    // unknown pinned version is recorded (FX-SOLVE-001) and solving
    // continues without it.
    final pin = evidence.effectivePin;
    if (pin != null) {
      final release = snapshot.find(pin.version);
      if (release != null) return CandidateSet.pinned(release, pin);
      steps.add(
        TraceStep(
          description:
              'pin ${pin.version} (${pin.origin}) not found in registry — '
              'ignored (FX-SOLVE-001)',
          remaining: snapshot.releases.length,
        ),
      );
    }

    var candidates = snapshot.releases;
    steps.add(
      TraceStep(
        description: 'start: all known releases',
        remaining: candidates.length,
      ),
    );

    for (final constraint in evidence.hard) {
      if (constraint.constraint.isAny) {
        steps.add(
          TraceStep(
            description:
                '${describeConstraint(constraint)} — contributes nothing',
            remaining: candidates.length,
          ),
        );
        continue;
      }
      candidates = _apply(constraint, candidates);
      steps.add(
        TraceStep(
          description: describeConstraint(constraint),
          remaining: candidates.length,
        ),
      );
    }

    final trace = ProvenanceTrace(steps: steps);
    return candidates.isEmpty
        ? CandidateSet.empty(trace)
        : CandidateSet.solved(candidates, trace);
  }

  /// Builds the exit-11 explanation for an empty solve (docs/03 §3.2):
  /// the *minimal* conflicting pair — or the single constraint no release
  /// satisfies at all.
  ResolutionConflict explainEmpty(
    ProjectEvidence evidence,
    RegistrySnapshot snapshot,
  ) {
    final constraints = evidence.hard
        .where((c) => !c.constraint.isAny)
        .toList();
    final all = snapshot.releases;

    // A single constraint that eliminates everything conflicts with the
    // registry itself, not with other evidence.
    for (final constraint in constraints) {
      if (_apply(constraint, all).isEmpty) {
        return ResolutionConflict(
          message:
              'no known Flutter release satisfies '
              '${describeConstraint(constraint, snapshot: snapshot)}',
          conflictingSourceA: constraint.origin,
          conflictingSourceB: 'registry',
          nextActions: const [
            'flutterx cache refresh  # a newer release may satisfy it',
            'relax the constraint',
          ],
        );
      }
    }

    // Minimal pair: two individually-satisfiable constraints whose
    // combination zeroes the set.
    for (var i = 0; i < constraints.length; i++) {
      for (var j = i + 1; j < constraints.length; j++) {
        if (_apply(constraints[j], _apply(constraints[i], all)).isEmpty) {
          final a = constraints[i];
          final b = constraints[j];
          return ResolutionConflict(
            message:
                'no Flutter release satisfies both '
                '${describeConstraint(a, snapshot: snapshot)} and '
                '${describeConstraint(b, snapshot: snapshot)}',
            conflictingSourceA: a.origin,
            conflictingSourceB: b.origin,
            nextActions: [
              'update ${a.origin} or ${b.origin} so their ranges overlap',
            ],
          );
        }
      }
    }

    // More than two constraints interact — name them all.
    return ResolutionConflict(
      message:
          'no Flutter release satisfies the combination of '
          '${constraints.length} constraints: '
          '${constraints.map(describeConstraint).join(', ')}',
      conflictingSourceA: constraints.first.origin,
      conflictingSourceB: constraints.last.origin,
      nextActions: const ['relax one of the listed constraints'],
    );
  }

  /// Human description, optionally with the implied Flutter range a Dart
  /// constraint translates to (docs/03 §3.2 example output).
  String describeConstraint(
    ConstraintEvidence constraint, {
    RegistrySnapshot? snapshot,
  }) {
    final base =
        '${constraint.kind == ConstraintKind.dart ? 'Dart' : 'Flutter'} '
        '${constraint.constraint} (${constraint.origin})';
    if (snapshot == null || constraint.kind != ConstraintKind.dart) {
      return base;
    }
    final allowed = _apply(constraint, snapshot.releases);
    if (allowed.isEmpty) return base;
    // Releases are newest-first; show the implied Flutter span.
    return '$base → Flutter '
        '${allowed.last.version}…${allowed.first.version}';
  }

  static List<FlutterRelease> _apply(
    ConstraintEvidence constraint,
    List<FlutterRelease> candidates,
  ) => switch (constraint.kind) {
    ConstraintKind.dart => [
      for (final release in candidates)
        if (constraint.constraint.allows(release.dartVersion)) release,
    ],
    ConstraintKind.flutter => [
      for (final release in candidates)
        if (constraint.constraint.allows(release.version)) release,
    ],
  };
}
