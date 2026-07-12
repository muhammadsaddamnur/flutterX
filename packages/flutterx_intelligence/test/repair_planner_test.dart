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
    expect(diagnoses.map((d) => d.plan.steps.single.id), [
      'refetch-objects',
      'recreate-worktree',
      'redownload-artifacts',
      'relink-project',
      're-resolve',
    ]);
    expect(diagnoses.first.severity, Severity.error);
    expect(diagnoses.first.subject, '/store/flutter.git');
  });

  test('healthy probes and advisory kinds produce no diagnoses', () {
    final diagnoses = planner.diagnose(
      HealthProbes(
        probes: [
          const Probe(kind: 'worktree', subject: '3.22.2', ok: true),
          bad('orphan-version', '3.24.1'), // advisory → cache gc, not repair
          bad('path', '/store/bin'), //        advisory → doctor guidance
          bad('journal', '/store/journal'), // FX-R08 lands with M3.2
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
