import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutterx_application/flutterx_application.dart';
import 'package:flutterx_cli/src/cli.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_platform/flutterx_platform.dart';
import 'package:flutterx_registry/flutterx_registry.dart';
import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:path/path.dart' as p;

/// The ONE place infrastructure is constructed and wired (docs/06 §9).
/// Everything below here talks through domain ports.
Future<FlutterXCli> buildCli() async {
  final storeHome =
      Platform.environment['FLUTTERX_HOME'] ?? p.join(_userHome(), '.flutterx');

  final layout = StoreLayout(storeHome);
  final initialized = await layout.init();
  if (initialized case Err(:final failure)) {
    // Even a broken store must produce the documented error format —
    // surface it through a CLI that fails every command with the failure.
    stderr.writeln('✗ ${failure.code}: ${failure.message}');
    for (final action in failure.nextActions) {
      stderr.writeln('  → $action');
    }
    exit(15);
  }

  // Keep shims current on every run — idempotent and cheap (docs/02 §8.3).
  // PATH guidance is doctor's job; failures here are non-fatal.
  final shimInstaller = ShimInstaller(binDir: layout.binDir);
  await shimInstaller.ensure();

  final lock = StoreLock(layout.storeLockFile);
  final git = SystemGitEngine(bareRepoPath: layout.bareRepoDir);
  final downloads = DownloadManager(downloadsDir: layout.downloadsDir);
  final artifacts = ArtifactStore(
    layout: layout,
    downloads: downloads,
    createLink: _createLink,
  );
  final journal = FileJournal(journalDir: layout.journalDir);
  final os = _hostOs();

  final api = FlutterXApi(
    sdkRepository: StoreSdkRepository(
      layout: layout,
      git: git,
      artifacts: artifacts,
      journal: journal,
      lock: lock,
      os: os,
    ),
    registry: HttpRegistry(
      client: ReleasesClient(),
      cache: SnapshotCache(cacheDir: layout.registryCacheDir),
      pubMeta: PubMetaClient(cacheDir: p.join(layout.registryCacheDir, 'pub')),
      os: os,
      preferredArch: Abi.current().toString().endsWith('arm64')
          ? 'arm64'
          : 'x64',
    ),
    projectStore: FileProjectStore(
      layout: layout,
      lock: lock,
      createLink: _createLink,
    ),
    storeHealth: StoreHealth(layout: layout, git: git, journal: journal),
    platformHealth: PlatformHealth(shimInstaller: shimInstaller),
    cacheOps: StoreCacheOps(layout: layout, git: git, journal: journal),
    config: FileConfigStore(configFilePath: layout.configFile),
    platform: HostPlatform(storeHome: storeHome),
  );

  return FlutterXCli(
    api: api,
    out: stdout.writeln,
    err: stderr.writeln,
    workingDirectory: Directory.current.path,
    environment: Platform.environment,
    interactive: stdin.hasTerminal,
    promptLine: stdin.readLineSync,
  );
}

TargetOs _hostOs() {
  if (Platform.isMacOS) return TargetOs.macos;
  if (Platform.isLinux) return TargetOs.linux;
  return TargetOs.windows;
}

String _userHome() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    Directory.current.path;

/// Interim link strategy until flutterx_platform lands (M1.7/M1.11):
/// symlinks everywhere. Windows junctions and hardlink probing move into
/// PlatformPort then.
Future<Result<void>> _createLink({
  required String targetPath,
  required String linkPath,
}) async {
  try {
    await Link(linkPath).create(targetPath, recursive: true);
    return const Result.ok(null);
  } on FileSystemException catch (e) {
    return Result.err(
      StorageFailure(
        code: 'FX-STORE-006',
        message: 'cannot link $linkPath → $targetPath: ${e.message}',
      ),
    );
  }
}
