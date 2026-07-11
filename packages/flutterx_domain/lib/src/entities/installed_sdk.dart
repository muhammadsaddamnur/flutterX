import 'package:flutterx_domain/src/entities/flutter_release.dart';

/// A release that is provisioned in the store and ready to use
/// (docs/06 §2.1): a worktree under `versions/<v>` with artifacts linked.
final class InstalledSdk {
  const InstalledSdk({required this.release, required this.path});

  final FlutterRelease release;

  /// Absolute path of the worktree (e.g. `~/.flutterx/versions/3.22.2`).
  final String path;

  @override
  bool operator ==(Object other) =>
      other is InstalledSdk && release == other.release && path == other.path;

  @override
  int get hashCode => Object.hash(release, path);

  @override
  String toString() => 'InstalledSdk(${release.version} at $path)';
}
