import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_storage/src/artifact_store.dart' show CreateLink;
import 'package:flutterx_storage/src/store_layout.dart';
import 'package:flutterx_storage/src/store_lock.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The evidence files collected for the Scanner, by project-root-relative
/// path (docs/03 §2.1 sources 1–9).
const _evidenceFileNames = [
  '.flutterx/resolution.lock',
  'flutterx.yaml',
  '.fvmrc',
  '.fvm/fvm_config.json',
  '.puro.json',
  'pubspec.yaml',
  'pubspec.lock',
  '.metadata',
  'codemagic.yaml',
];

/// [ProjectStore] over the filesystem (docs/06 §6): evidence collection,
/// the resolution lockfile, and the project SDK link + registry.
final class FileProjectStore implements ProjectStore {
  FileProjectStore({
    required this.layout,
    required this.lock,
    required this.createLink,
  });

  final StoreLayout layout;
  final StoreLock lock;
  final CreateLink createLink;

  @override
  Future<Project?> findProject(String startDir) async {
    var dir = Directory(startDir).absolute;
    while (true) {
      if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() ||
          File(p.join(dir.path, 'flutterx.yaml')).existsSync()) {
        return Project(rootPath: dir.path);
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  @override
  Future<Workspace?> findWorkspace(String startDir) async {
    var dir = Directory(startDir).absolute;
    while (true) {
      final file = File(p.join(dir.path, 'flutterx.yaml'));
      if (file.existsSync()) {
        final workspace = _parseWorkspace(dir.path, file);
        if (workspace != null) return workspace;
        // A plain project flutterx.yaml — keep walking up: the project
        // may itself be a member of an enclosing workspace.
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  Workspace? _parseWorkspace(String rootPath, File file) {
    final Object? yaml;
    try {
      yaml = loadYaml(file.readAsStringSync());
    } on YamlException {
      return null; // malformed → scanner warnings handle it elsewhere
    }
    if (yaml is! YamlMap) return null;
    final globsNode = yaml['workspace'];
    if (globsNode is! YamlList) return null;
    final globs = [for (final g in globsNode) g.toString()];

    final members = <WorkspaceMember>[
      for (final memberDir in _expandGlobs(rootPath, globs))
        WorkspaceMember(
          project: Project(rootPath: memberDir),
          policySettings: _memberRules(memberDir),
        ),
    ];
    return Workspace(
      rootPath: rootPath,
      memberGlobs: globs,
      members: members,
      policySettings: _flattenRules(yaml['rules']),
    );
  }

  /// Expands `workspace:` globs (single-`*` path segments, docs/04 §3.12:
  /// `apps/*`) to directories containing a `pubspec.yaml`, sorted for
  /// determinism.
  static List<String> _expandGlobs(String rootPath, List<String> globs) {
    final matched = <String>{};
    for (final glob in globs) {
      var dirs = [rootPath];
      for (final segment in glob.replaceAll(r'\', '/').split('/')) {
        if (segment.isEmpty || segment == '.') continue;
        final next = <String>[];
        for (final dir in dirs) {
          if (segment == '*') {
            final entries = Directory(dir).existsSync()
                ? Directory(dir).listSync()
                : const <FileSystemEntity>[];
            next.addAll([
              for (final entry in entries)
                if (entry is Directory &&
                    !p.basename(entry.path).startsWith('.'))
                  entry.path,
            ]);
          } else {
            final candidate = p.join(dir, segment);
            if (Directory(candidate).existsSync()) next.add(candidate);
          }
        }
        dirs = next;
      }
      matched.addAll(
        dirs.where((d) => File(p.join(d, 'pubspec.yaml')).existsSync()),
      );
    }
    return matched.toList()..sort();
  }

  static Map<String, String> _memberRules(String memberDir) {
    final file = File(p.join(memberDir, 'flutterx.yaml'));
    if (!file.existsSync()) return const {};
    try {
      final yaml = loadYaml(file.readAsStringSync());
      return yaml is YamlMap ? _flattenRules(yaml['rules']) : const {};
    } on YamlException {
      return const {};
    }
  }

  /// Flattens a `rules:` YAML map to the `rules.<id>.<key>` dot notation
  /// the policy merger consumes (docs/03 §4.3).
  static Map<String, String> _flattenRules(Object? rules) {
    if (rules is! YamlMap) return const {};
    final flat = <String, String>{};
    for (final rule in rules.entries) {
      final settings = rule.value;
      if (settings is! YamlMap) continue;
      for (final setting in settings.entries) {
        flat['rules.${rule.key}.${setting.key}'] = setting.value.toString();
      }
    }
    return flat;
  }

  @override
  Future<Result<Workspace>> initWorkspace(String rootPath) async {
    final existing = await findWorkspace(rootPath);
    if (existing != null &&
        p.equals(existing.rootPath, Directory(rootPath).absolute.path)) {
      return Result.ok(existing); // idempotent
    }

    // Discover member dirs: pubspec.yaml at depth 1–2, generalized to
    // `parent/*` globs where siblings share a parent.
    final globs = <String>{};
    final root = Directory(rootPath).absolute;
    for (final entry in root.listSync()) {
      if (entry is! Directory || p.basename(entry.path).startsWith('.')) {
        continue;
      }
      if (File(p.join(entry.path, 'pubspec.yaml')).existsSync()) {
        globs.add(p.basename(entry.path));
        continue;
      }
      for (final nested in entry.listSync()) {
        if (nested is Directory &&
            File(p.join(nested.path, 'pubspec.yaml')).existsSync()) {
          globs.add('${p.basename(entry.path)}/*');
        }
      }
    }
    final memberGlobs = globs.isEmpty
        ? ['apps/*', 'packages/*'] // starter template (docs/04 §3.12)
        : (globs.toList()..sort());

    final file = File(p.join(root.path, 'flutterx.yaml'));
    final buffer = StringBuffer();
    if (file.existsSync()) {
      buffer.write(await file.readAsString());
      if (!buffer.toString().endsWith('\n')) buffer.writeln();
    } else {
      buffer.writeln('# FlutterX workspace — hand-editable (docs/04 §3.12).');
    }
    buffer.writeln('workspace:');
    for (final glob in memberGlobs) {
      buffer.writeln('  - $glob');
    }
    await file.writeAsString(buffer.toString());

    final workspace = await findWorkspace(root.path);
    return workspace == null
        ? const Result.err(
            StorageFailure(
              code: 'FX-STORE-011',
              message:
                  'workspace init wrote flutterx.yaml but it does not '
                  'parse back — is an existing flutterx.yaml malformed?',
            ),
          )
        : Result.ok(workspace);
  }

  @override
  Future<Result<void>> writePin(
    Project project, {
    String? pinVersion,
    String? policyChannel,
  }) async {
    assert(
      (pinVersion == null) != (policyChannel == null),
      'exactly one of pin or policy',
    );
    final file = File(p.join(project.rootPath, 'flutterx.yaml'));
    final buffer = StringBuffer()
      ..writeln('# FlutterX project intent — hand-editable (docs/04 §4).')
      ..writeln(
        pinVersion != null ? 'flutter: $pinVersion' : 'policy: $policyChannel',
      );
    await file.writeAsString(buffer.toString());
    return const Result.ok(null);
  }

  @override
  Future<EvidenceFiles> readEvidence(Project project) async {
    final files = <String, String>{};
    for (final name in _evidenceFileNames) {
      final file = File(p.join(project.rootPath, name));
      if (file.existsSync()) {
        files[name] = await file.readAsString();
      }
    }
    // lib/main.dart presence marker for kind classification (docs/03
    // §2.3) — the scanner needs existence, not content.
    if (File(p.join(project.rootPath, 'lib', 'main.dart')).existsSync()) {
      files['lib/main.dart'] = '';
    }

    // CI workflows: every YAML under .github/workflows (docs/03 §2.1 #9).
    final workflows = Directory(
      p.join(project.rootPath, '.github', 'workflows'),
    );
    if (workflows.existsSync()) {
      await for (final entry in workflows.list()) {
        if (entry is File &&
            (entry.path.endsWith('.yml') || entry.path.endsWith('.yaml'))) {
          final relative = p
              .relative(entry.path, from: project.rootPath)
              .replaceAll(r'\', '/');
          files[relative] = await entry.readAsString();
        }
      }
    }
    return EvidenceFiles(files: files);
  }

  @override
  Future<Resolution?> readLock(Project project) async {
    final file = File(p.join(project.rootPath, '.flutterx/resolution.lock'));
    if (!file.existsSync()) return null;
    try {
      final yaml = loadYaml(await file.readAsString()) as YamlMap;
      final flutter = yaml['flutter'].toString();
      return Resolution(
        // Reconstructed from the lock alone: enough for the fast path
        // (shims, current); full release data comes from the registry.
        chosen: FlutterRelease(
          version: SemVer.parse(flutter),
          channel:
              Channel.tryParse(yaml['channel'].toString()) ?? Channel.stable,
          gitTag: flutter,
          frameworkSha: '',
          dartVersion: SemVer.parse(yaml['dart'].toString()),
          releasedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          artifacts: const {},
        ),
        confidence: Confidence.high,
        reasons: [
          for (final reason in (yaml['reasons'] as YamlList? ?? YamlList()))
            Reason(text: reason.toString()),
        ],
        evidenceHash: yaml['evidenceHash']?.toString() ?? '',
        resolvedBy: ResolvedBy.values.firstWhere(
          (v) => v.name == yaml['resolvedBy'].toString(),
          orElse: () => ResolvedBy.use,
        ),
        resolvedAt: DateTime.parse(yaml['resolvedAt'].toString()),
      );
    } on Exception {
      return null; // corrupt lock → treated as unresolved; doctor flags it
    }
  }

  @override
  Future<Result<void>> writeLock(Project project, Resolution resolution) async {
    final file = File(p.join(project.rootPath, '.flutterx/resolution.lock'));
    await file.parent.create(recursive: true);
    // Exactly the documented format (docs/03 §7) — this file is a public
    // contract and is committed to the project's repository.
    final buffer = StringBuffer()
      ..writeln(
        '# .flutterx/resolution.lock — generated by flutterx; '
        'commit this file.',
      )
      ..writeln('flutterx: 1')
      ..writeln('flutter: ${resolution.chosen.version}')
      ..writeln('dart: ${resolution.chosen.dartVersion}')
      ..writeln('channel: ${resolution.chosen.channel.name}')
      ..writeln(
        'resolvedAt: ${resolution.resolvedAt.toUtc().toIso8601String()}',
      )
      ..writeln('resolvedBy: ${resolution.resolvedBy.name}')
      ..writeln('evidenceHash: ${resolution.evidenceHash}')
      ..writeln('reasons:');
    for (final reason in resolution.reasons) {
      buffer.writeln('  - "${reason.text.replaceAll('"', r'\"')}"');
    }
    await file.writeAsString(buffer.toString());
    return const Result.ok(null);
  }

  @override
  Future<String?> resolvedSdkPath(Project project) async {
    final linkPath = p.join(project.rootPath, '.flutterx', 'sdk');
    // Mechanism-independent (symlink/junction/whatever): if the path
    // traverses to a directory, resolveSymbolicLinksSync follows the
    // reparse point to the real target on every platform (unlike
    // p.canonicalize, which is lexical-only). Dangling links type as
    // notFound.
    if (FileSystemEntity.typeSync(linkPath) != FileSystemEntityType.directory) {
      return null;
    }
    return Directory(linkPath).resolveSymbolicLinksSync();
  }

  @override
  Future<Result<List<String>>> bumpDependencies(
    Project project,
    Map<String, SemVer> bumps,
  ) async {
    final file = File(p.join(project.rootPath, 'pubspec.yaml'));
    if (!file.existsSync()) {
      return const Result.err(
        StorageFailure(code: 'FX-STORE-005', message: 'no pubspec.yaml'),
      );
    }
    // Line-based rewrite preserves the user's formatting and comments —
    // only `  name: <constraint>` dependency lines are touched. A bare
    // `  name:` (git/path dep with a nested map) is left alone.
    final lines = (await file.readAsString()).split('\n');
    final changed = <String>[];
    for (var i = 0; i < lines.length; i++) {
      for (final bump in bumps.entries) {
        final match = RegExp(
          '^(\\s{2}${RegExp.escape(bump.key)}:\\s*)'
          r'\S[^#]*?(\s*#.*)?$',
        ).firstMatch(lines[i]);
        if (match != null) {
          lines[i] = '${match.group(1)}^${bump.value}${match.group(2) ?? ''}';
          changed.add(bump.key);
        }
      }
    }
    if (changed.isNotEmpty) {
      await file.writeAsString(lines.join('\n'));
    }
    return Result.ok(changed);
  }

  @override
  Future<Result<void>> linkSdk(Project project, InstalledSdk sdk) {
    return lock.withExclusive(() async {
      final linkPath = p.join(project.rootPath, '.flutterx', 'sdk');
      await Directory(p.dirname(linkPath)).create(recursive: true);
      // Remove whatever is there — symlink, junction, or stale dir.
      switch (FileSystemEntity.typeSync(linkPath, followLinks: false)) {
        case FileSystemEntityType.link:
          await Link(linkPath).delete();
        case FileSystemEntityType.directory:
          await Directory(linkPath).delete(); // junction reads as dir on
        //                                       some platforms — not recursive:
        //                                       a real dir here is a bug we
        //                                       must not silently vaporize
        case FileSystemEntityType.notFound:
          break;
        default:
          await File(linkPath).delete();
      }
      final linked = await createLink(targetPath: sdk.path, linkPath: linkPath);
      if (linked case Err(:final failure)) return Result.err(failure);

      // Register for GC reference counting (docs/05 §6.1).
      final state = await layout.loadState();
      if (state case Err(:final failure)) return Result.err(failure);
      await layout.saveState(
        state.valueOrNull!.withProject(
          ProjectRef(
            path: project.rootPath,
            version: sdk.release.version.toString(),
          ),
        ),
      );
      return const Result.ok(null);
    });
  }
}
