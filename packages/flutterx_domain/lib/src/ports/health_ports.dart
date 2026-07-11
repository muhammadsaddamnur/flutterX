import 'package:flutterx_domain/src/entities/diagnosis.dart';
import 'package:flutterx_domain/src/entities/project.dart';

/// Read-only health probes over the store and a project (docs/03 §9.2,
/// docs/04 §3.7) — implemented in `flutterx_storage`. Probes observe;
/// they never fix. `doctor` renders them; `repair` (M2.7) feeds them to
/// the RepairPlanner.
abstract interface class StoreHealthPort {
  Future<List<Probe>> probeStore();
  Future<List<Probe>> probeProject(Project project);
}

/// Host-environment probes (git version, shims, PATH) — implemented in
/// `flutterx_platform`.
abstract interface class PlatformHealthPort {
  Future<List<Probe>> probePlatform();
}
