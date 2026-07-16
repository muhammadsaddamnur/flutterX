import 'package:flutterx_domain/src/entities/project.dart';

/// One member project of a workspace (docs/04 §3.12): a directory matched
/// by the root `workspace:` globs that contains a `pubspec.yaml`.
final class WorkspaceMember {
  WorkspaceMember({
    required this.project,
    Map<String, String> policySettings = const {},
  }) : policySettings = Map.unmodifiable(policySettings);

  final Project project;

  /// Flattened `rules.<id>.<key>` entries from the member's own
  /// `flutterx.yaml` — merged *after* the workspace layer, so a member may
  /// pin tighter, never looser (docs/03 §4.3).
  final Map<String, String> policySettings;

  String get path => project.rootPath;
}

/// A monorepo workspace: one policy, many packages (docs/04 §3.12).
/// Declared by a root `flutterx.yaml` with `workspace:` globs.
final class Workspace {
  Workspace({
    required this.rootPath,
    List<String> memberGlobs = const [],
    List<WorkspaceMember> members = const [],
    Map<String, String> policySettings = const {},
  }) : memberGlobs = List.unmodifiable(memberGlobs),
       members = List.unmodifiable(members),
       policySettings = Map.unmodifiable(policySettings);

  final String rootPath;
  final List<String> memberGlobs;

  /// Expanded members, in glob order then alphabetical.
  final List<WorkspaceMember> members;

  /// Flattened `rules.<id>.<key>` entries from the root `flutterx.yaml` —
  /// the workspace policy layer every member inherits.
  final Map<String, String> policySettings;
}
