import 'package:flutterx_application/src/use_cases/use_sdk.dart'
    show evidenceHash;
import 'package:flutterx_domain/flutterx_domain.dart';

/// What `flutterx current` reports (docs/04 §3.5).
final class CurrentInfo {
  const CurrentInfo({
    this.project,
    this.resolution,
    this.lockFresh,
    this.migratedPin,
    this.warnings = const [],
  });

  final Project? project;
  final Resolution? resolution;

  /// Whether the evidence still matches the lock's hash; `null` when
  /// unresolved.
  final bool? lockFresh;

  /// An adoptable pin found while unresolved (own `flutterx.yaml` or
  /// FVM/Puro migration, T1.10.2).
  final PinEvidence? migratedPin;

  /// Scanner warnings (conflicting pins, unreadable configs) — always
  /// shown (docs/03 §2.3).
  final List<ScanWarning> warnings;

  bool get insideProject => project != null;
  bool get resolved => resolution != null;
}

/// `flutterx current`: read-only view of the active context — never
/// mutates, never touches the network.
final class ShowCurrent {
  ShowCurrent(this._projects, this._scanner);

  final ProjectStore _projects;
  final ProjectScanner _scanner;

  Future<CurrentInfo> execute(String cwd) async {
    final project = await _projects.findProject(cwd);
    if (project == null) return const CurrentInfo();

    final resolution = await _projects.readLock(project);
    if (resolution == null) {
      // Unresolved: surface any adoptable pin (migration UX).
      final evidence = _scanner.scan(await _projects.readEvidence(project));
      return CurrentInfo(
        project: project,
        migratedPin: evidence.effectivePin,
        warnings: evidence.warnings,
      );
    }

    final currentHash = await evidenceHash(_projects, project);
    return CurrentInfo(
      project: project,
      resolution: resolution,
      lockFresh: currentHash == resolution.evidenceHash,
    );
  }
}
