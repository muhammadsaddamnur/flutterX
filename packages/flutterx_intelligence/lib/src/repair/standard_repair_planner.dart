import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/src/repair/journal_recovery.dart';

/// [RepairPlanner] over the full FX-R catalogue (docs/03 §9.1,
/// FX-R01…FX-R09). Pure: matches probe observations to diagnoses with
/// ordered, idempotent fix plans. Probing and fixing are the application
/// layer's job — doctor renders these diagnoses, repair executes them.
///
/// Plans are ordered by dependency then severity (docs/03 §9.2): the bare
/// repo is fixed before worktrees, interrupted journals before their
/// artifacts, worktrees before links.
final class StandardRepairPlanner implements RepairPlanner {
  /// Dependency-then-severity order of the catalogue.
  static const _order = [
    'FX-R04', // bare repo first — everything else builds on it
    'FX-R08', // interrupted operations next — they explain other damage
    'FX-R03',
    'FX-R09',
    'FX-R05',
    'FX-R01',
    'FX-R02',
    'FX-R07',
    'FX-R06', // hygiene last
  ];

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
          FixStep(
            id: 'reclone-bare-repo',
            description:
                'last resort if still unhealthy: delete and re-clone the '
                'shared repository (worktrees are recreated by a second '
                'repair run)',
            destructive: true,
          ),
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
    'orphan-version' => Diagnosis(
      id: 'FX-R06',
      severity: Severity.info,
      subject: probe.subject,
      summary: 'orphaned version ${probe.subject} — no project references it',
      plan: FixPlan(
        steps: const [
          FixStep(
            id: 'gc-orphans',
            description:
                'reclaim via the reference-counted collector '
                '(grace periods apply — recent installs are kept)',
          ),
        ],
      ),
    ),
    'shims' => Diagnosis(
      id: 'FX-R07',
      severity: Severity.warning,
      subject: probe.subject,
      summary: 'shim drift at ${probe.subject}: ${probe.detail}',
      plan: FixPlan(
        steps: const [
          FixStep(id: 'reinstall-shims', description: 'reinstall the shims'),
        ],
      ),
    ),
    'path' => Diagnosis(
      id: 'FX-R07',
      severity: Severity.warning,
      subject: probe.subject,
      summary:
          'shims are not on PATH${probe.detail == null ? '' : ' — '
                    '${probe.detail}'}',
      plan: FixPlan(
        steps: const [
          FixStep(
            id: 'path-guidance',
            description:
                'PATH is user configuration — apply the printed export '
                'line (repair never edits shell profiles)',
          ),
        ],
      ),
    ),
    // One probe per uncommitted journal entry, subject "<op> <target>".
    'journal-entry' => _journalEntry(probe),
    'version-mismatch' => Diagnosis(
      id: 'FX-R09',
      severity: Severity.warning,
      subject: probe.subject,
      summary:
          'dart/flutter version mismatch for ${probe.subject}'
          '${probe.detail == null ? '' : ' (${probe.detail})'}',
      plan: FixPlan(
        steps: [
          FixStep(
            id: 'recheckout-worktree',
            description:
                'recheckout ${probe.subject} at the correct tag from the '
                'shared repo',
          ),
        ],
      ),
    ),
    // Remaining advisory probes are doctor territory.
    _ => null,
  };

  Diagnosis _journalEntry(Probe probe) {
    final operation = probe.subject.split(' ').first;
    final direction = recoveryDirectionFor(operation);
    return Diagnosis(
      id: 'FX-R08',
      severity: Severity.warning,
      subject: probe.subject,
      summary: 'interrupted operation: ${probe.subject}',
      plan: FixPlan(
        steps: [
          FixStep(
            id: direction == RecoveryDirection.rollForward
                ? 'roll-forward'
                : 'roll-back',
            description: direction == RecoveryDirection.rollForward
                ? 'finish the remaining steps (each step is idempotent), '
                      'then commit the journal'
                : 'restore what the interrupted removal was deleting, '
                      'then commit the journal',
          ),
        ],
      ),
    );
  }
}
