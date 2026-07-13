@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end install flow (T1.4.8): real git fixture remote + loopback
/// artifact server → provision → verify the documented layout; interrupted
/// install → journal evidence → roll-forward by re-run (docs/05 §7).
void main() {
  late Directory tmp;
  late StoreLayout layout;
  late StoreSdkRepository repo;
  late FileJournal journal;
  late HttpServer server;
  var serveArtifacts = true;

  final engineBytes = utf8.encode('pretend engine blob ' * 200);
  final engineSha = sha256.convert(engineBytes).toString();

  Future<void> sh(List<String> args, {String? cwd}) async {
    final result = await Process.run('git', args, workingDirectory: cwd);
    if (result.exitCode != 0) fail('git ${args.join(' ')}: ${result.stderr}');
  }

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

  late String remotePath;

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
    tmp = await Directory.systemTemp.createTemp('flutterx_install_');

    // Git fixture remote.
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

    // Artifact server with a togglable outage.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final response = request.response;
      if (!serveArtifacts || request.uri.path != '/engine.zip') {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.add(engineBytes);
      }
      response.close();
    });

    layout = StoreLayout(p.join(tmp.path, 'store'));
    await layout.init();
    journal = FileJournal(journalDir: layout.journalDir);
    final downloads = DownloadManager(downloadsDir: layout.downloadsDir);
    repo = StoreSdkRepository(
      layout: layout,
      git: SystemGitEngine(
        bareRepoPath: layout.bareRepoDir,
        retryDelays: const [Duration.zero],
      ),
      artifacts: ArtifactStore(
        layout: layout,
        downloads: downloads,
        createLink: symlinkCreate,
      ),
      journal: journal,
      lock: StoreLock(layout.storeLockFile),
      os: TargetOs.macos,
      originUrl: Uri.directory(remotePath).toString(),
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  test(
    'interrupted install leaves journal evidence; re-run rolls forward',
    () async {
      serveArtifacts = false; // simulate the crash/outage mid-install
      final failed = await repo.ensureInstalled(release());
      expect(failed.isOk, isFalse);
      expect(
        await journal.uncommitted(),
        hasLength(1),
        reason: 'the aborted install is crash evidence',
      );
      expect(
        File(layout.versionManifest('3.22.2')).existsSync(),
        isFalse,
        reason: 'no manifest → not installed',
      );

      serveArtifacts = true; // outage over — plain re-run completes the work
      final result = await repo.ensureInstalled(release());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');

      // The documented layout (docs/05 §3, §4.1).
      final versionDir = layout.versionDir('3.22.2');
      expect(
        File(p.join(versionDir, 'README.md')).existsSync(),
        isTrue,
        reason: 'worktree materialized',
      );
      expect(File(p.join(versionDir, 'version')).readAsStringSync(), '3.22.2');
      final versionJson =
          jsonDecode(
                File(
                  p.join(versionDir, 'bin', 'cache', 'flutter.version.json'),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(versionJson['dartSdkVersion'], '3.4.3');
      expect(
        File(
          p.join(versionDir, 'bin', 'cache', 'artifacts', 'engine.zip'),
        ).readAsBytesSync(),
        engineBytes,
        reason: 'artifact linked from the CAS',
      );
      expect(File(layout.casPayload(engineSha)).existsSync(), isTrue);
      final manifest =
          jsonDecode(File(layout.versionManifest('3.22.2')).readAsStringSync())
              as Map<String, Object?>;
      expect(manifest['artifacts'], [engineSha]);
    },
  );

  test(
    'a completed install is idempotent (no re-work, no new journal)',
    () async {
      final before = Directory(layout.journalDir).listSync().length;
      final result = await repo.ensureInstalled(release());
      expect(result.isOk, isTrue);
      expect(Directory(layout.journalDir).listSync().length, before);
    },
  );

  test('installed() lists the provisioned SDK from its manifest', () async {
    final sdks = await repo.installed();
    expect(sdks, hasLength(1));
    expect(sdks.single.release.version, SemVer.parse('3.22.2'));
    expect(sdks.single.release.dartVersion, SemVer.parse('3.4.3'));
  });

  test(
    'remove refuses while a live project references the version (exit 17)',
    () async {
      final projectDir = Directory(p.join(tmp.path, 'app'))..createSync();
      final projectStore = FileProjectStore(
        layout: layout,
        lock: StoreLock(layout.storeLockFile),
        createLink: symlinkCreate,
      );
      final sdk = (await repo.installed()).single;
      await projectStore.linkSdk(Project(rootPath: projectDir.path), sdk);

      final refused = await repo.remove(SemVer.parse('3.22.2'));
      expect(refused.failureOrNull, isA<ResourceInUse>());
      expect((refused.failureOrNull! as ResourceInUse).referencedBy, [
        projectDir.path,
      ]);

      final forced = await repo.remove(SemVer.parse('3.22.2'), force: true);
      expect(forced.isOk, isTrue, reason: '${forced.failureOrNull}');
      expect(Directory(layout.versionDir('3.22.2')).existsSync(), isFalse);
      expect(await repo.installed(), isEmpty);
    },
  );
}
