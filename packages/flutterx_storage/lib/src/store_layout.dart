import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// The current store schema version (docs/05 §10). Bump only with a
/// migration.
const storeSchemaVersion = 1;

/// One project → version reference in the store's project registry
/// (docs/05 §6.1). Advisory: GC re-validates before trusting it.
final class ProjectRef {
  const ProjectRef({required this.path, required this.version});

  final String path;
  final String version;

  Map<String, Object?> toJson() => {'path': path, 'version': version};

  static ProjectRef fromJson(Map<String, Object?> json) => ProjectRef(
    path: json['path']! as String,
    version: json['version']! as String,
  );
}

/// Contents of `state.json` (docs/05 §3): schema version, probed link
/// mode, and the project registry.
final class StoreState {
  StoreState({
    this.schemaVersion = storeSchemaVersion,
    this.linkMode,
    List<ProjectRef> projects = const [],
  }) : projects = List.unmodifiable(projects);

  final int schemaVersion;
  final String? linkMode;
  final List<ProjectRef> projects;

  StoreState withProject(ProjectRef ref) {
    final rest = projects.where((existing) => existing.path != ref.path);
    return StoreState(
      schemaVersion: schemaVersion,
      linkMode: linkMode,
      projects: [...rest, ref],
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    if (linkMode != null) 'linkMode': linkMode,
    'projects': [for (final ref in projects) ref.toJson()],
  };

  static StoreState fromJson(Map<String, Object?> json) => StoreState(
    schemaVersion: json['schemaVersion']! as int,
    linkMode: json['linkMode'] as String?,
    projects: [
      for (final entry in (json['projects'] as List<Object?>? ?? const []))
        ProjectRef.fromJson(entry! as Map<String, Object?>),
    ],
  );
}

/// Authoritative path layout of `~/.flutterx` (docs/05 §3) plus state.json
/// lifecycle: init, schema guard, load/save.
final class StoreLayout {
  StoreLayout(this.root);

  /// Store root (`~/.flutterx` or `FLUTTERX_HOME`).
  final String root;

  String get stateFile => p.join(root, 'state.json');
  String get configFile => p.join(root, 'config.yaml');
  String get binDir => p.join(root, 'bin');
  String get bareRepoDir => p.join(root, 'cache', 'git', 'flutter.git');
  String get registryCacheDir => p.join(root, 'cache', 'registry');
  String get downloadsDir => p.join(root, 'cache', 'downloads');
  String get versionsDir => p.join(root, 'versions');
  String get artifactsDir => p.join(root, 'artifacts', 'sha256');
  String get locksDir => p.join(root, 'locks');
  String get storeLockFile => p.join(locksDir, 'store.lock');
  String get journalDir => p.join(root, 'journal');
  String get logsDir => p.join(root, 'logs');

  String versionDir(String version) => p.join(versionsDir, version);

  String versionManifest(String version) =>
      p.join(versionDir(version), '.flutterx-manifest.json');

  /// CAS entry directory, sharded by hash prefix with lowercase hex only
  /// (case-insensitive filesystems, docs/05 §8).
  String casEntryDir(String sha256) {
    final lower = sha256.toLowerCase();
    return p.join(artifactsDir, lower.substring(0, 2), lower);
  }

  String casPayload(String sha256) => p.join(casEntryDir(sha256), 'payload');

  /// Creates the directory skeleton and state.json when missing; refuses a
  /// store written by a newer FlutterX (docs/05 §10).
  Future<Result<StoreState>> init() async {
    for (final dir in [
      binDir,
      p.dirname(bareRepoDir),
      registryCacheDir,
      downloadsDir,
      versionsDir,
      artifactsDir,
      locksDir,
      journalDir,
      logsDir,
    ]) {
      await Directory(dir).create(recursive: true);
    }
    final file = File(stateFile);
    if (!file.existsSync()) {
      final state = StoreState();
      await saveState(state);
      return Result.ok(state);
    }
    return loadState();
  }

  Future<Result<StoreState>> loadState() async {
    final file = File(stateFile);
    final StoreState state;
    try {
      state = StoreState.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, Object?>,
      );
    } on Exception catch (e) {
      return Result.err(
        StorageFailure(
          code: 'FX-STORE-002',
          message: 'state.json is unreadable: $e',
        ),
      );
    }
    if (state.schemaVersion > storeSchemaVersion) {
      return Result.err(
        StorageFailure(
          code: 'FX-STORE-003',
          message:
              'store schema ${state.schemaVersion} is newer than this '
              'FlutterX understands ($storeSchemaVersion)',
          nextActions: const ['upgrade FlutterX'],
        ),
      );
    }
    return Result.ok(state);
  }

  Future<void> saveState(StoreState state) async {
    // Write-temp + rename so a crash never leaves a torn state.json.
    final tmp = File('$stateFile.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
    await tmp.rename(stateFile);
  }
}
