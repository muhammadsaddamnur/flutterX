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
      final link = Link(p.join(projectDir.path, '.flutterx', 'sdk'));
      expect(link.existsSync(), isTrue);
      expect(link.targetSync(), sdkDir.path);

      final state = (await layout.loadState()).valueOrNull!;
      expect(state.projects.single.path, projectDir.path);
      expect(state.projects.single.version, '3.22.2');

      // Re-linking (version switch) upserts, never duplicates.
      expect((await store.linkSdk(project(), sdk)).isOk, isTrue);
      expect((await layout.loadState()).valueOrNull!.projects, hasLength(1));
    },
  );
}
