@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterx_application/flutterx_application.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Crash-recovery E2E (T3.2.3, docs/08 §4): a real store with real git +
/// journal, damaged the way a crash at each install journal step leaves it
/// (fabricated deterministically — literally killing processes is flaky),
/// then `repair` must bring it back to fully healthy probes.
void main() {
  late Directory tmp;
  late StoreLayout layout;
  late FileJournal journal;
  late StoreSdkRepository repo;
  late StoreHealth storeHealth;
  late StoreCacheOps cacheOps;
  late FileProjectStore projectStore;
  late RepairEnvironment repair;
  late HttpServer server;
  late String remotePath;

  final engineBytes = utf8.encode('pretend engine blob ' * 200);
  final engineSha = sha256.convert(engineBytes).toString();

  Future<void> sh(List<String> args, {String? cwd}) async {
    final result = await Process.run('git', args, workingDirectory: cwd);
    if (result.exitCode != 0) fail('git ${args.join(' ')}: ${result.stderr}');
  }

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

  FlutterRelease release() => FlutterRelease(
    version: SemVer.parse('3.22.2'),
    channel: Channel.stable,
    gitTag: '3.22.2',
    frameworkSha: 'fixture-sha',
    dartVersion: SemVer.parse('3.4.3'),
    releasedAt: DateTime.utc(2026, 1, 1),
    artifacts: {
      TargetOs.macos: ArtifactRef(
        url: Uri.parse(
          'http://${server.address.host}:${server.port}/engine.zip',
        ),
        sha256: engineSha,
      ),
    },
  );

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_crash_');

    remotePath = p.join(tmp.path, 'remote');
    Directory(remotePath).createSync(recursive: true);
    await sh(['init', '-b', 'master', remotePath]);
    await sh(['-C', remotePath, 'config', 'user.email', 't@t.t']);
    await sh(['-C', remotePath, 'config', 'user.name', 'test']);
    await sh(['-C', remotePath, 'config', 'uploadpack.allowFilter', 'true']);
    File(p.join(remotePath, 'README.md')).writeAsStringSync('flutter fixture');
    await sh(['-C', remotePath, 'add', '.']);
    await sh(['-C', remotePath, 'commit', '-m', 'release 3.22.2']);
    await sh(['-C', remotePath, 'tag', '3.22.2']);

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final response = request.response;
      if (request.uri.path != '/engine.zip') {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.add(engineBytes);
      }
      response.close();
    });

    layout = StoreLayout(p.join(tmp.path, 'store'));
    await layout.init();
    journal = FileJournal(journalDir: layout.journalDir);
    final git = SystemGitEngine(
      bareRepoPath: layout.bareRepoDir,
      retryDelays: const [Duration.zero],
    );
    final artifacts = ArtifactStore(
      layout: layout,
      downloads: DownloadManager(downloadsDir: layout.downloadsDir),
      createLink: symlinkCreate,
    );
    final lock = StoreLock(layout.storeLockFile);
    repo = StoreSdkRepository(
      layout: layout,
      git: git,
      artifacts: artifacts,
      journal: journal,
      lock: lock,
      os: TargetOs.macos,
      originUrl: Uri.directory(remotePath).toString(),
    );
    storeHealth = StoreHealth(layout: layout, git: git, journal: journal);
    cacheOps = StoreCacheOps(
      layout: layout,
      git: git,
      journal: journal,
      artifacts: artifacts,
      lock: lock,
      originUrl: Uri.directory(remotePath).toString(),
    );
    projectStore = FileProjectStore(
      layout: layout,
      lock: lock,
      createLink: symlinkCreate,
    );

    repair = RepairEnvironment(
      storeHealth: storeHealth,
      platformHealth: _HealthyPlatform(),
      projects: projectStore,
      sdks: repo,
      registry: _FixtureRegistry(release),
      cacheOps: cacheOps,
      journal: journal,
      config: FileConfigStore(configFilePath: layout.configFile),
      clock: DateTime.now,
    );

    // Baseline: a healthy install referenced by a live project (so the
    // orphan probe stays quiet and gc never collects it).
    final installed = await repo.ensureInstalled(release());
    expect(installed.isOk, isTrue, reason: '${installed.failureOrNull}');
    final projectDir = Directory(p.join(tmp.path, 'app'))..createSync();
    final linked = await projectStore.linkSdk(
      Project(rootPath: projectDir.path),
      installed.valueOrNull!,
    );
    expect(linked.isOk, isTrue);
  });

  tearDownAll(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  /// Runs repair (as `repair --yes` would) and asserts the store is fully
  /// healthy afterwards: every probe ok, no uncommitted journals.
  Future<void> repairToHealthy(String scenario) async {
    final diagnoses = await repair.plan(tmp.path);
    expect(diagnoses, isNotEmpty, reason: '$scenario: damage not detected');
    final report = await repair.execute(diagnoses, allowReResolve: true);
    expect(report.failed, isEmpty, reason: '$scenario: ${report.failed}');

    final probes = await storeHealth.probeStore();
    expect(
      probes.where((probe) => !probe.ok),
      isEmpty,
      reason:
          '$scenario left unhealthy probes: '
          '${probes.where((p) => !p.ok).map((p) => '${p.kind} ${p.detail}')}',
    );
    expect(
      await journal.uncommitted(),
      isEmpty,
      reason: '$scenario: crash evidence must be resolved',
    );
    expect(
      File(layout.versionManifest('3.22.2')).existsSync(),
      isTrue,
      reason: '$scenario: the version must be installed again',
    );
  }

  /// Fabricates the on-disk state a crash at [afterStep] leaves behind:
  /// an uncommitted install journal plus the matching missing pieces.
  Future<void> crashInstallAt(
    String afterStep, {
    required Future<void> Function() damage,
  }) async {
    final begun = await journal.begin(
      operation: 'install',
      target: '3.22.2',
      stepIds: const [
        'fetch-tag',
        'worktree-add',
        'version-stamp',
        'artifacts',
        'manifest',
      ],
    );
    final entry = begun.valueOrNull! as FileJournalEntry;
    const order = [
      'fetch-tag',
      'worktree-add',
      'version-stamp',
      'artifacts',
      'manifest',
    ];
    for (final step in order) {
      if (step == afterStep) {
        await entry.stepStarted(step);
        break;
      }
      await entry.stepDone(step);
    }
    await damage();
  }

  group('interrupted install rolls forward to healthy (docs/05 §7)', () {
    test('crash during manifest write', () async {
      await crashInstallAt(
        'manifest',
        damage: () async => File(layout.versionManifest('3.22.2')).deleteSync(),
      );
      await repairToHealthy('manifest crash');
    });

    test('crash during version stamping', () async {
      await crashInstallAt(
        'version-stamp',
        damage: () async {
          File(p.join(layout.versionDir('3.22.2'), 'version')).deleteSync();
          File(layout.versionManifest('3.22.2')).deleteSync();
        },
      );
      await repairToHealthy('version-stamp crash');
    });

    test('crash during artifact download', () async {
      await crashInstallAt(
        'artifacts',
        damage: () async {
          File(
            p.join(
              layout.versionDir('3.22.2'),
              'bin',
              'cache',
              'artifacts',
              'engine.zip',
            ),
          ).deleteSync();
          Directory(layout.casEntryDir(engineSha)).deleteSync(recursive: true);
          File(layout.versionManifest('3.22.2')).deleteSync();
        },
      );
      await repairToHealthy('artifacts crash');
    });

    test('crash during checkout (nothing materialized yet)', () async {
      await crashInstallAt(
        'worktree-add',
        damage: () async {
          // A porcelain removal models the pre-checkout state exactly.
          final removed = await repo.remove(
            SemVer.parse('3.22.2'),
            force: true,
          );
          expect(removed.isOk, isTrue);
        },
      );
      await repairToHealthy('checkout crash');
    });
  });

  test('interrupted remove rolls BACK: the version is restored', () async {
    final begun = await journal.begin(
      operation: 'remove',
      target: '3.22.2',
      stepIds: const ['worktree-remove'],
    );
    await (begun.valueOrNull! as FileJournalEntry).stepStarted(
      'worktree-remove',
    );
    // Half-deleted worktree: the stamp is gone, the dir remains.
    File(p.join(layout.versionDir('3.22.2'), 'version')).deleteSync();

    await repairToHealthy('interrupted remove');
  });

  test('interrupted gc rolls forward by re-running the collector', () async {
    final begun = await journal.begin(
      operation: 'gc',
      target: 'store',
      stepIds: const ['worktrees', 'artifacts', 'downloads', 'repack'],
    );
    await (begun.valueOrNull! as FileJournalEntry).stepStarted('worktrees');

    await repairToHealthy('interrupted gc');
  });

  test('FX-R09: wrong version stamp is re-checked out', () async {
    File(
      p.join(layout.versionDir('3.22.2'), 'version'),
    ).writeAsStringSync('3.19.6');

    await repairToHealthy('version mismatch');
    expect(
      File(p.join(layout.versionDir('3.22.2'), 'version')).readAsStringSync(),
      '3.22.2',
    );
  });
}

final class _FixtureRegistry implements RegistryPort {
  _FixtureRegistry(this._release);
  final FlutterRelease Function() _release;

  @override
  Future<Result<RegistrySnapshot>> snapshot({bool refresh = false}) async =>
      Result.ok(
        RegistrySnapshot(
          releases: [_release()],
          fetchedAt: DateTime.utc(2026, 7, 11),
          source: 'fixture',
        ),
      );

  @override
  Future<Result<PackageMeta>> packageMeta(String name, SemVer version) async =>
      const Result.err(NetworkFailure(code: 'FX-REG-002', message: 'no meta'));
}

final class _HealthyPlatform implements PlatformHealthPort {
  @override
  Future<List<Probe>> probePlatform() async => const [
    Probe(kind: 'git', subject: '2.51', ok: true),
  ];
}
