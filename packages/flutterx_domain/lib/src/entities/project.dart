/// What kind of Dart/Flutter project a directory is (docs/03 §2.2).
enum ProjectKind { app, package, plugin, workspaceMember, unknown }

/// A project directory FlutterX operates on (docs/06 §2.1).
final class Project {
  const Project({required this.rootPath, this.kind = ProjectKind.unknown});

  /// Absolute path of the project root (the directory holding pubspec.yaml
  /// or flutterx.yaml).
  final String rootPath;

  final ProjectKind kind;

  @override
  bool operator ==(Object other) =>
      other is Project && rootPath == other.rootPath;

  @override
  int get hashCode => rootPath.hashCode;

  @override
  String toString() => 'Project($rootPath, $kind)';
}
