import 'package:flutterx_application/src/use_cases/use_sdk.dart'
    show evidenceHash;
import 'package:flutterx_domain/flutterx_domain.dart';

/// One rendered doctor section (docs/04 §3.7): Store / Project / Platform.
final class DoctorSection {
  DoctorSection({required this.name, required List<Probe> probes})
    : probes = List.unmodifiable(probes);

  final String name;
  final List<Probe> probes;
}

final class DoctorReport {
  DoctorReport({required List<DoctorSection> sections})
    : sections = List.unmodifiable(sections);

  final List<DoctorSection> sections;

  Iterable<Probe> get _failed =>
      sections.expand((s) => s.probes).where((p) => !p.ok);

  int get warnings => _failed.where((p) => p.severity != Severity.error).length;
  int get errors => _failed.where((p) => p.severity == Severity.error).length;

  /// Exit 0 with warnings; 15 only on errors (docs/04 §3.7).
  bool get healthy => errors == 0;
}

/// `flutterx doctor`: gather read-only probes, section by section
/// (docs/03 §9.2 — doctor is repair minus the executor).
final class RunDoctor {
  RunDoctor(this._storeHealth, this._platformHealth, this._projects);

  final StoreHealthPort _storeHealth;
  final PlatformHealthPort _platformHealth;
  final ProjectStore _projects;

  Future<DoctorReport> execute(
    String cwd, {
    bool store = true,
    bool project = true,
    bool platform = true,
  }) async {
    final sections = <DoctorSection>[];
    if (store) {
      sections.add(
        DoctorSection(name: 'Store', probes: await _storeHealth.probeStore()),
      );
    }
    if (project) {
      final found = await _projects.findProject(cwd);
      final probes = found == null
          ? const [
              Probe(
                kind: 'project',
                subject: 'cwd',
                ok: true,
                detail: 'not inside a project',
              ),
            ]
          : [
              ...await _storeHealth.probeProject(found),
              // Stale-lock (FX-R02) — identical to repair's probe
              // (docs/03 §9.2: doctor = repair minus the executor).
              if (await _projects.readLock(found) case final lock?)
                if (lock.evidenceHash == await evidenceHash(_projects, found))
                  Probe(
                    kind: 'stale-lock',
                    subject: found.rootPath,
                    ok: true,
                    detail: 'lock fresh',
                  )
                else
                  Probe(
                    kind: 'stale-lock',
                    subject: found.rootPath,
                    ok: false,
                    detail: 'evidence changed → run `flutterx resolve`',
                  ),
            ];
      sections.add(DoctorSection(name: 'Project', probes: probes));
    }
    if (platform) {
      sections.add(
        DoctorSection(
          name: 'Platform',
          probes: await _platformHealth.probePlatform(),
        ),
      );
    }
    return DoctorReport(sections: sections);
  }
}
