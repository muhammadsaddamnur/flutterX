/// Severity of a diagnosed problem — orders fixes (docs/03 §9.2).
enum Severity { error, warning, info }

/// One idempotent step of a fix plan (docs/03 §9.2). Destructive steps
/// require explicit confirmation even under `--yes` (unless `--force`).
final class FixStep {
  const FixStep({
    required this.id,
    required this.description,
    this.destructive = false,
  });

  final String id;
  final String description;
  final bool destructive;
}

/// An ordered, idempotent plan that fixes one diagnosis.
final class FixPlan {
  FixPlan({required List<FixStep> steps}) : steps = List.unmodifiable(steps);

  final List<FixStep> steps;

  bool get hasDestructiveStep => steps.any((s) => s.destructive);
}

/// A detected problem plus its fix plan (docs/03 §9.1 failure catalogue).
final class Diagnosis {
  const Diagnosis({
    required this.id,
    required this.severity,
    required this.summary,
    required this.plan,
  });

  /// Stable catalogue id, e.g. `FX-R03`.
  final String id;

  final Severity severity;

  /// One-line description shown by `doctor` and `repair`.
  final String summary;

  final FixPlan plan;

  @override
  String toString() => '[$id] $summary';
}

/// Read-only health-probe results the application layer gathers for the
/// Repair planner (docs/03 §9.2). Probes are observations, not judgments —
/// the planner matches them against the catalogue.
final class HealthProbes {
  HealthProbes({List<Probe> probes = const []})
    : probes = List.unmodifiable(probes);

  final List<Probe> probes;

  Iterable<Probe> ofKind(String kind) => probes.where((p) => p.kind == kind);
}

/// A single observation, e.g. kind `project-link`, subject
/// `~/work/app/.flutterx/sdk`, ok `false`, detail `target missing`.
final class Probe {
  const Probe({
    required this.kind,
    required this.subject,
    required this.ok,
    this.detail,
  });

  final String kind;
  final String subject;
  final bool ok;
  final String? detail;
}
