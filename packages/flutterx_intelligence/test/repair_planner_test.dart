import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

void main() {
  final planner = StandardRepairPlanner();

  Probe bad(String kind, String subject, {String? detail}) =>
      Probe(kind: kind, subject: subject, ok: false, detail: detail);

  test('maps the FX-R01…R05 catalogue (docs/03 §9.1)', () {
    final diagnoses = planner.diagnose(
      HealthProbes(
        probes: [
          bad('project-link', '/work/app/.flutterx/sdk'),
          bad('stale-lock', '/work/app'),
          bad('worktree', '3.19.6', detail: 'files missing'),
          bad('bare-repo', '/store/flutter.git', detail: 'fsck errors'),
          bad('artifacts', '3.22.2'),
        ],
      ),
    );
    expect(diagnoses.map((d) => d.id), [
      'FX-R04', // bare repo first — everything depends on it
      'FX-R03',
      'FX-R05',
      'FX-R01',
      'FX-R02',
    ]);
    expect(diagnoses.map((d) => d.plan.steps.first.id), [
      'refetch-objects',
      'recreate-worktree',
      'redownload-artifacts',
      'relink-project',
      're-resolve',
    ]);
    expect(diagnoses.first.severity, Severity.error);
    expect(diagnoses.first.subject, '/store/flutter.git');
  });

  test('maps the M3.2 catalogue FX-R06…R09 (docs/03 §9.1)', () {
    final diagnoses = planner.diagnose(
      HealthProbes(
        probes: [
          bad('orphan-version', '3.24.1'),
          bad('shims', '/store/bin', detail: 'write failed'),
          bad('journal-entry', 'install 3.22.2'),
          bad('version-mismatch', '3.22.2', detail: 'version file says 3.19'),
        ],
      ),
    );
    expect(diagnoses.map((d) => d.id), [
      'FX-R08', // interrupted operations explain other damage — early
      'FX-R09',
      'FX-R07',
      'FX-R06', // hygiene last
    ]);
    expect(
      diagnoses.firstWhere((d) => d.id == 'FX-R06').plan.steps.single.id,
      'gc-orphans',
    );
    expect(
      diagnoses.firstWhere((d) => d.id == 'FX-R07').plan.steps.single.id,
      'reinstall-shims',
    );
    expect(
      diagnoses.firstWhere((d) => d.id == 'FX-R09').plan.steps.single.id,
      'recheckout-worktree',
    );
  });

  group('FX-R08 follows the docs/05 §7 recovery policy table', () {
    test('install and gc roll forward', () {
      for (final subject in ['install 3.22.2', 'gc store']) {
        final diagnosis = planner
            .diagnose(HealthProbes(probes: [bad('journal-entry', subject)]))
            .single;
        expect(diagnosis.id, 'FX-R08');
        expect(diagnosis.plan.steps.single.id, 'roll-forward');
      }
    });

    test('remove rolls back (restore what was being deleted)', () {
      final diagnosis = planner
          .diagnose(
            HealthProbes(probes: [bad('journal-entry', 'remove 3.19.6')]),
          )
          .single;
      expect(diagnosis.plan.steps.single.id, 'roll-back');
    });

    test('unknown operations default to roll-forward (idempotent steps)', () {
      expect(recoveryDirectionFor('migrate'), RecoveryDirection.rollForward);
      expect(recoveryDirectionFor('remove'), RecoveryDirection.rollBack);
    });
  });

  test('FX-R04 carries the destructive re-clone escalation, gated', () {
    final diagnosis = planner
        .diagnose(HealthProbes(probes: [bad('bare-repo', '/store/git')]))
        .single;
    expect(diagnosis.plan.steps.map((s) => s.id), [
      'refetch-objects',
      'reclone-bare-repo',
    ]);
    expect(diagnosis.plan.steps.first.destructive, isFalse);
    expect(diagnosis.plan.steps.last.destructive, isTrue);
    expect(diagnosis.plan.hasDestructiveStep, isTrue);
  });

  test('FX-R07 path drift is guidance-only (repair never edits profiles)', () {
    final diagnosis = planner
        .diagnose(
          HealthProbes(
            probes: [bad('path', '/store/bin', detail: 'export PATH=…')],
          ),
        )
        .single;
    expect(diagnosis.id, 'FX-R07');
    expect(diagnosis.plan.steps.single.id, 'path-guidance');
    expect(diagnosis.summary, contains('export PATH=…'));
  });

  test('healthy probes and advisory kinds produce no diagnoses', () {
    final diagnoses = planner.diagnose(
      HealthProbes(
        probes: [
          const Probe(kind: 'worktree', subject: '3.22.2', ok: true),
          const Probe(kind: 'journal', subject: '/store/journal', ok: true),
          bad('store-state', '/store/state.json'), // fatal → not repairable
        ],
      ),
    );
    expect(diagnoses, isEmpty);
  });

  test('half-installed worktrees map to FX-R03 as well', () {
    final diagnoses = planner.diagnose(
      HealthProbes(probes: [bad('version-manifest', '3.24.1')]),
    );
    expect(diagnoses.single.id, 'FX-R03');
    expect(diagnoses.single.subject, '3.24.1');
  });
}
