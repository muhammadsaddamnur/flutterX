import 'package:flutterx_domain/flutterx_domain.dart';

/// [RepairPlanner] over the FX-R catalogue (docs/03 §9.1, M2.7 scope:
/// FX-R01…FX-R05). Pure: matches probe observations to diagnoses with
/// ordered, idempotent fix plans. Probing and fixing are the application
/// layer's job — doctor renders these diagnoses, repair executes them.
///
/// Plans are ordered by dependency then severity (docs/03 §9.2): the bare
/// repo is fixed before worktrees, worktrees before artifacts and links.
final class StandardRepairPlanner implements RepairPlanner {
  /// Dependency-then-severity order of the catalogue.
  static const _order = ['FX-R04', 'FX-R03', 'FX-R05', 'FX-R01', 'FX-R02'];

  @override
  List<Diagnosis> diagnose(HealthProbes probes) {
    final diagnoses = <Diagnosis>[
      for (final probe in probes.probes.where((probe) => !probe.ok))
        ?_match(probe),
    ]..sort((a, b) => _order.indexOf(a.id).compareTo(_order.indexOf(b.id)));
    return diagnoses;
  }

  Diagnosis? _match(Probe probe) => switch (probe.kind) {
    'project-link' => Diagnosis(
      id: 'FX-R01',
      severity: Severity.warning,
      subject: probe.subject,
      summary: 'broken project link at ${probe.subject}',
      plan: FixPlan(
        steps: [
          FixStep(
            id: 'relink-project',
            description:
                're-link ${probe.subject} from the lock '
                '(provision if the version is missing)',
          ),
        ],
      ),
    ),
    'stale-lock' => Diagnosis(
      id: 'FX-R02',
      severity: Severity.warning,
      subject: probe.subject,
      summary: 'lock is stale for ${probe.subject} (evidence changed)',
      plan: FixPlan(
        steps: const [
          FixStep(id: 're-resolve', description: 're-run resolution'),
        ],
      ),
    ),
    'worktree' || 'version-manifest' => Diagnosis(
      id: 'FX-R03',
      severity: Severity.warning,
      subject: probe.subject,
      summary:
          'corrupt worktree ${probe.subject}'
          '${probe.detail == null ? '' : ' (${probe.detail})'}',
      plan: FixPlan(
        steps: [
          FixStep(
            id: 'recreate-worktree',
            description:
                'remove and recreate ${probe.subject} from the shared repo',
          ),
        ],
      ),
    ),
    'bare-repo' => Diagnosis(
      id: 'FX-R04',
      severity: Severity.error,
      subject: probe.subject,
      summary: 'bare repository unhealthy: ${probe.detail}',
      plan: FixPlan(
        steps: const [
          FixStep(
            id: 'refetch-objects',
            description: 're-fetch objects from origin',
          ),
          // The destructive re-clone escalation lands with M3.2's journal
          // roll-forward/back machinery (docs/09).
        ],
      ),
    ),
    'artifacts' => Diagnosis(
      id: 'FX-R05',
      severity: Severity.warning,
      subject: probe.subject,
      summary: 'artifacts missing for ${probe.subject}',
      plan: FixPlan(
        steps: [
          FixStep(
            id: 'redownload-artifacts',
            description:
                're-download ${probe.subject} artifacts into the CAS '
                '(resumable)',
          ),
        ],
      ),
    ),
    // Advisory probes (orphans, journal, PATH…) are doctor territory —
    // their remedies are other commands, not repair steps.
    _ => null,
  };
}
