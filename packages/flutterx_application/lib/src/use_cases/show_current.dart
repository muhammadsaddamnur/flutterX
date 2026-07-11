import 'package:flutterx_application/src/use_cases/use_sdk.dart'
    show evidenceHash;
import 'package:flutterx_domain/flutterx_domain.dart';

/// What `flutterx current` reports (docs/04 §3.5).
final class CurrentInfo {
  const CurrentInfo({this.project, this.resolution, this.lockFresh});

  final Project? project;
  final Resolution? resolution;

  /// Whether the evidence still matches the lock's hash; `null` when
  /// unresolved.
  final bool? lockFresh;

  bool get insideProject => project != null;
  bool get resolved => resolution != null;
}

/// `flutterx current`: read-only view of the active context — never
/// mutates, never touches the network.
final class ShowCurrent {
  ShowCurrent(this._projects);

  final ProjectStore _projects;

  Future<CurrentInfo> execute(String cwd) async {
    final project = await _projects.findProject(cwd);
    if (project == null) return const CurrentInfo();
    final resolution = await _projects.readLock(project);
    if (resolution == null) return CurrentInfo(project: project);
    final currentHash = await evidenceHash(_projects, project);
    return CurrentInfo(
      project: project,
      resolution: resolution,
      lockFresh: currentHash == resolution.evidenceHash,
    );
  }
}
