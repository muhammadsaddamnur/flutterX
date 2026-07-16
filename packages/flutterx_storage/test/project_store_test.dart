import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StoreLayout layout;
  late FileProjectStore store;
  late Directory projectDir;

  // Portable link helper: symlink on POSIX, junction on Windows —
  // matching production HostPlatform.createLink (M1.11).
  Future<Result<void>> symlinkCreate({
    required String targetPath,
    required String linkPath,
  }) async {
    if (Platform.isWindows) {
      final r = await Process.run('cmd', [
        '/c',
        'mklink',
        Directory(targetPath).existsSync() ? '/J' : '/H',
        linkPath,
        targetPath,
      ]);
      return r.exitCode == 0
          ? const Result.ok(null)
          : Result.err(
              StorageFailure(code: 'FX-STORE-006', message: '${r.stderr}'),
            );
    }
    await Link(linkPath).create(targetPath);
    return const Result.ok(null);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_project_');
    layout = StoreLayout(p.join(tmp.path, 'store'));
    await layout.init();
    store = FileProjectStore(
      layout: layout,
      lock: StoreLock(layout.storeLockFile),
      createLink: symlinkCreate,
    );
    projectDir = Directory(p.join(tmp.path, 'app'))..createSync();
  });

  tearDown(() => tmp.delete(recursive: true));

  Project project() => Project(rootPath: projectDir.path);

  test(
    'readEvidence collects exactly the files that exist (docs/03 §2.1)',
    () async {
      File(
        p.join(projectDir.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: app');
      File(
        p.join(projectDir.path, '.metadata'),
      ).writeAsStringSync('version: x');
      Directory(
        p.join(projectDir.path, '.github', 'workflows'),
      ).createSync(recursive: true);
      File(
        p.join(projectDir.path, '.github', 'workflows', 'build.yml'),
      ).writeAsStringSync('flutter-version: 3.19.6');

      final evidence = await store.readEvidence(project());
      expect(evidence['pubspec.yaml'], 'name: app');
      expect(evidence['.metadata'], isNotNull);
      expect(evidence['.github/workflows/build.yml'], contains('3.19.6'));
      expect(evidence.contains('.fvmrc'), isFalse);
    },
  );

  test('writeLock emits the documented format; readLock round-trips', () async {
    final release = FlutterRelease(
      version: SemVer.parse('3.22.2'),
      channel: Channel.stable,
      gitTag: '3.22.2',
      frameworkSha: 'abc123',
      dartVersion: SemVer.parse('3.4.3'),
      releasedAt: DateTime.utc(2026, 1, 1),
      artifacts: const {},
    );
    final written = Resolution(
      chosen: release,
      confidence: Confidence.high,
      reasons: const [
        Reason(text: 'pin: none; solved from constraints'),
        Reason(text: 'hint: .metadata 3.22.x (+30)', delta: 30),
      ],
      evidenceHash: 'sha256:9f2c',
      resolvedBy: ResolvedBy.resolve,
      resolvedAt: DateTime.utc(2026, 7, 11, 3, 12, 44),
    );
    expect((await store.writeLock(project(), written)).isOk, isTrue);

    final raw = File(
      p.join(projectDir.path, '.flutterx', 'resolution.lock'),
    ).readAsStringSync();
    // Public contract fields (docs/03 §7).
    expect(raw, contains('flutterx: 1'));
    expect(raw, contains('flutter: 3.22.2'));
    expect(raw, contains('dart: 3.4.3'));
    expect(raw, contains('channel: stable'));
    expect(raw, contains('resolvedBy: resolve'));
    expect(raw, contains('evidenceHash: sha256:9f2c'));

    final read = await store.readLock(project());
    expect(read, isNotNull);
    expect(read!.chosen.version, SemVer.parse('3.22.2'));
    expect(read.chosen.dartVersion, SemVer.parse('3.4.3'));
    expect(read.resolvedBy, ResolvedBy.resolve);
    expect(read.evidenceHash, 'sha256:9f2c');
    expect(read.reasons, hasLength(2));
  });

  test('readLock is null for unresolved or corrupt projects', () async {
    expect(await store.readLock(project()), isNull);
    final lockFile = File(
      p.join(projectDir.path, '.flutterx', 'resolution.lock'),
    )..createSync(recursive: true);
    lockFile.writeAsStringSync('{{{{not yaml');
    expect(await store.readLock(project()), isNull);
  });

  test(
    'linkSdk links .flutterx/sdk and registers the project for GC',
    () async {
      final sdkDir = Directory(p.join(tmp.path, 'store', 'versions', '3.22.2'))
        ..createSync(recursive: true);
      final sdk = InstalledSdk(
        release: FlutterRelease(
          version: SemVer.parse('3.22.2'),
          channel: Channel.stable,
          gitTag: '3.22.2',
          frameworkSha: 'abc',
          dartVersion: SemVer.parse('3.4.3'),
          releasedAt: DateTime.utc(2026, 1, 1),
          artifacts: const {},
        ),
        path: sdkDir.path,
      );

      expect((await store.linkSdk(project(), sdk)).isOk, isTrue);
      // Mechanism-independent (symlink on POSIX, junction on Windows):
      // the link resolves to a directory equal to the SDK dir. targetSync()
      // is symlink-only and unreliable for junctions.
      final linkPath = p.join(projectDir.path, '.flutterx', 'sdk');
      expect(
        FileSystemEntity.typeSync(linkPath),
        FileSystemEntityType.directory,
      );
      expect(
        Directory(linkPath).resolveSymbolicLinksSync(),
        sdkDir.resolveSymbolicLinksSync(),
      );

      final state = (await layout.loadState()).valueOrNull!;
      expect(state.projects.single.path, projectDir.path);
      expect(state.projects.single.version, '3.22.2');

      // Re-linking (version switch) upserts, never duplicates.
      expect((await store.linkSdk(project(), sdk)).isOk, isTrue);
      expect((await layout.loadState()).valueOrNull!.projects, hasLength(1));
    },
  );

  group('bumpDependencies (M3.1, upgrade --bump-deps)', () {
    test(
      'rewrites only the named constraints, preserving everything else',
      () async {
        final pubspec = File(p.join(projectDir.path, 'pubspec.yaml'))
          ..writeAsStringSync('''
name: app
environment:
  sdk: ">=3.4.0 <4.0.0"

dependencies:
  freezed: ^2.4.7 # pinned for codegen
  collection: 1.19.0
  my_local:
    path: ../my_local

dev_dependencies:
  build_runner: ">=2.4.0 <2.5.0"
''');

        final result = await store.bumpDependencies(project(), {
          'freezed': SemVer.parse('2.5.2'),
          'build_runner': SemVer.parse('2.4.11'),
          'not_a_dep': SemVer.parse('9.9.9'),
        });
        expect(
          result.valueOrNull,
          unorderedEquals(['freezed', 'build_runner']),
        );

        final body = pubspec.readAsStringSync();
        expect(
          body,
          contains('  freezed: ^2.5.2 # pinned for codegen'),
          reason: 'inline comments survive the rewrite',
        );
        expect(body, contains('  build_runner: ^2.4.11'));
        expect(body, contains('  collection: 1.19.0'), reason: 'untouched');
        expect(body, contains('  sdk: ">=3.4.0 <4.0.0"'), reason: 'env kept');
        expect(
          body,
          contains('  my_local:\n    path: ../my_local'),
          reason: 'bare-map deps (path/git) are never clobbered',
        );
      },
    );

    test(
      'bare-map dependency named in bumps is skipped, not clobbered',
      () async {
        File(p.join(projectDir.path, 'pubspec.yaml')).writeAsStringSync('''
dependencies:
  my_local:
    path: ../my_local
''');
        final result = await store.bumpDependencies(project(), {
          'my_local': SemVer.parse('1.0.0'),
        });
        expect(result.valueOrNull, isEmpty);
      },
    );

    test('missing pubspec.yaml → FX-STORE-005', () async {
      final result = await store.bumpDependencies(project(), {
        'freezed': SemVer.parse('2.5.2'),
      });
      expect(result.failureOrNull?.code, 'FX-STORE-005');
    });
  });

  group('workspace (M3.3, docs/04 §3.12)', () {
    late Directory wsRoot;

    void member(String relative, {String? flutterxYaml}) {
      final dir = Directory(p.join(wsRoot.path, relative))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: m');
      if (flutterxYaml != null) {
        File(p.join(dir.path, 'flutterx.yaml')).writeAsStringSync(flutterxYaml);
      }
    }

    setUp(() {
      wsRoot = Directory(p.join(tmp.path, 'ws'))..createSync();
    });

    test('findWorkspace expands globs, reads root + member policy, '
        'walks up from a member', () async {
      File(p.join(wsRoot.path, 'flutterx.yaml')).writeAsStringSync('''
workspace:
  - apps/*
  - packages/ui_kit
rules:
  channel-policy:
    allow: stable
''');
      member(
        'apps/shop',
        flutterxYaml: '''
rules:
  min-version-floor:
    version: 3.22.0
''',
      );
      member('apps/admin');
      member('packages/ui_kit');
      Directory(
        p.join(wsRoot.path, 'apps', 'not_a_pkg'),
      ).createSync(recursive: true); // no pubspec → not a member

      // From a member directory, not just the root.
      final ws = await store.findWorkspace(p.join(wsRoot.path, 'apps', 'shop'));
      expect(ws, isNotNull);
      expect(p.equals(ws!.rootPath, wsRoot.path), isTrue);
      expect(ws.members.map((m) => p.relative(m.path, from: ws.rootPath)), [
        'apps/admin',
        'apps/shop',
        'packages/ui_kit',
      ]);
      expect(ws.policySettings, {'rules.channel-policy.allow': 'stable'});
      final shop = ws.members.firstWhere((m) => m.path.endsWith('shop'));
      expect(shop.policySettings, {
        'rules.min-version-floor.version': '3.22.0',
      });
    });

    test('a plain project flutterx.yaml is not a workspace', () async {
      member('.', flutterxYaml: 'flutter: 3.22.2\n');
      expect(await store.findWorkspace(wsRoot.path), isNull);
    });

    test('initWorkspace discovers members and generalizes to globs', () async {
      member('apps/shop');
      member('packages/ui_kit');
      member('tool_pkg'); // depth-1 stays literal

      final result = await store.initWorkspace(wsRoot.path);
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      final ws = result.valueOrNull!;
      expect(ws.memberGlobs, ['apps/*', 'packages/*', 'tool_pkg']);
      expect(ws.members, hasLength(3));

      // Idempotent: a second init returns the same workspace, no rewrite.
      final before = File(
        p.join(wsRoot.path, 'flutterx.yaml'),
      ).readAsStringSync();
      expect((await store.initWorkspace(wsRoot.path)).isOk, isTrue);
      expect(
        File(p.join(wsRoot.path, 'flutterx.yaml')).readAsStringSync(),
        before,
      );
    });

    test('initWorkspace with no members writes the starter template', () async {
      final result = await store.initWorkspace(wsRoot.path);
      expect(result.valueOrNull!.memberGlobs, ['apps/*', 'packages/*']);
    });

    test(
      'initWorkspace appends to an existing project flutterx.yaml',
      () async {
        File(
          p.join(wsRoot.path, 'flutterx.yaml'),
        ).writeAsStringSync('flutter: 3.22.2\n');
        member('apps/shop');
        final result = await store.initWorkspace(wsRoot.path);
        expect(result.isOk, isTrue);
        final body = File(
          p.join(wsRoot.path, 'flutterx.yaml'),
        ).readAsStringSync();
        expect(body, contains('flutter: 3.22.2'), reason: 'pin preserved');
        expect(body, contains('workspace:'));
      },
    );
  });
}
