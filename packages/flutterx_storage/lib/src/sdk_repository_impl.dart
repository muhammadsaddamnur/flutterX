import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_storage/src/artifact_store.dart';
import 'package:flutterx_storage/src/file_journal.dart';
import 'package:flutterx_storage/src/store_layout.dart';
import 'package:flutterx_storage/src/store_lock.dart';
import 'package:path/path.dart' as p;

/// [SdkRepository] over the git engine + CAS (docs/05 §4.1, docs/06 §6).
///
/// The install algorithm is journaled and every step checks before acting,
/// so an interrupted install is completed by simply re-running it
/// (roll-forward, docs/05 §7).
final class StoreSdkRepository implements SdkRepository {
  StoreSdkRepository({
    required this.layout,
    required this.git,
    required this.artifacts,
    required this.journal,
    required this.lock,
    required this.os,
    this.originUrl = 'https://github.com/flutter/flutter.git',
  });

  final StoreLayout layout;
  final GitEngine git;
  final ArtifactStore artifacts;
  final FileJournal journal;
  final StoreLock lock;
  final TargetOs os;
  final String originUrl;

  @override
  Future<Result<InstalledSdk>> ensureInstalled(
    FlutterRelease release, {
    InstallOptions options = const InstallOptions(),
  }) {
    return lock.withExclusive(() async {
      final version = release.version.toString();
      final versionDir = layout.versionDir(version);
      final manifestFile = File(layout.versionManifest(version));

      if (manifestFile.existsSync() && !options.force) {
        return Result.ok(InstalledSdk(release: release, path: versionDir));
      }
      if (release.retracted && !options.force) {
        return Result.err(
          PolicyDenied(
            message:
                'Flutter $version is retracted'
                '${release.retractionReason == null ? '' : ': ${release.retractionReason}'}',
            denials: [
              (
                candidate: version,
                ruleId: 'deny-retracted',
                reason: release.retractionReason ?? 'known-bad release',
              ),
            ],
            nextActions: const ['pass --force to install it anyway'],
          ),
        );
      }

      final begun = await journal.begin(
        operation: 'install',
        target: version,
        stepIds: const [
          'fetch-tag',
          'worktree-add',
          'version-stamp',
          'artifacts',
          'manifest',
        ],
      );
      if (begun case Err(:final failure)) return Result.err(failure);
      final entry = begun.valueOrNull! as FileJournalEntry;

      final ensured = await git.ensureBareRepo(originUrl);
      if (ensured case Err(:final failure)) return Result.err(failure);

      // 1. objects
      await entry.stepStarted('fetch-tag');
      if (!await git.hasTag(release.gitTag)) {
        final fetched = await git.fetchTag(release.gitTag);
        if (fetched case Err(:final failure)) return Result.err(failure);
      }
      await entry.stepDone('fetch-tag');

      // 2. working tree
      await entry.stepStarted('worktree-add');
      if (!Directory(versionDir).existsSync()) {
        final added = await git.addWorktree(release.gitTag, versionDir);
        if (added case Err(:final failure)) return Result.err(failure);
      }
      await entry.stepDone('worktree-add');

      // 3. version stamp — what bin/flutter would write, without network
      //    (docs/05 §4.1 step 3).
      await entry.stepStarted('version-stamp');
      await File(p.join(versionDir, 'version')).writeAsString(version);
      final versionJson = File(
        p.join(versionDir, 'bin', 'cache', 'flutter.version.json'),
      );
      await versionJson.parent.create(recursive: true);
      await versionJson.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'frameworkVersion': version,
          'channel': release.channel.name,
          'repositoryUrl': originUrl,
          'frameworkRevision': release.frameworkSha,
          'dartSdkVersion': release.dartVersion.toString(),
          'flutterVersion': version,
        }),
      );
      await entry.stepDone('version-stamp');

      // 4. artifacts via CAS
      final linked = <String>[];
      await entry.stepStarted('artifacts');
      if (!options.skipArtifacts) {
        final wanted = release.artifacts[os];
        if (wanted != null) {
          final ensuredArtifact = await artifacts.ensure(wanted);
          if (ensuredArtifact case Err(:final failure)) {
            return Result.err(failure);
          }
          final ref = ensuredArtifact.valueOrNull!;
          final target = p.join(
            versionDir,
            'bin',
            'cache',
            'artifacts',
            artifactFileName(wanted),
          );
          final link = await artifacts.linkInto(ref, target);
          if (link case Err(:final failure)) return Result.err(failure);
          linked.add(ref.sha256);
        }
      }
      await entry.stepDone('artifacts');

      // 5. manifest — the version is "installed" only once this exists.
      await entry.stepStarted('manifest');
      await manifestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'version': version,
          'channel': release.channel.name,
          'gitTag': release.gitTag,
          'frameworkSha': release.frameworkSha,
          'dartVersion': release.dartVersion.toString(),
          'releasedAt': release.releasedAt.toIso8601String(),
          'artifacts': linked,
          'installedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await entry.stepDone('manifest');
      await entry.commit();

      return Result.ok(InstalledSdk(release: release, path: versionDir));
    });
  }

  @override
  Future<Result<void>> remove(SemVer version, {bool force = false}) {
    return lock.withExclusive(() async {
      final v = version.toString();
      final dir = Directory(layout.versionDir(v));
      if (!dir.existsSync()) return const Result.ok(null);

      if (!force) {
        final state = await layout.loadState();
        if (state case Err(:final failure)) return Result.err(failure);
        final holders = state.valueOrNull!.projects
            .where((ref) => ref.version == v)
            // Advisory registry — trust only refs whose project still exists
            // (docs/05 §6.1).
            .where((ref) => Directory(ref.path).existsSync())
            .map((ref) => ref.path)
            .toList();
        if (holders.isNotEmpty) {
          return Result.err(
            ResourceInUse(
              message:
                  '${holders.length} project(s) still pinned to Flutter $v',
              referencedBy: holders,
            ),
          );
        }
      }

      final begun = await journal.begin(
        operation: 'remove',
        target: v,
        stepIds: const ['worktree-remove'],
      );
      if (begun case Err(:final failure)) return Result.err(failure);
      final entry = begun.valueOrNull! as FileJournalEntry;

      await entry.stepStarted('worktree-remove');
      final removed = await git.removeWorktree(dir.path);
      if (removed case Err(:final failure)) return Result.err(failure);
      if (dir.existsSync()) await dir.delete(recursive: true);
      await entry.stepDone('worktree-remove');
      await entry.commit();
      return const Result.ok(null);
    });
  }

  @override
  Future<List<InstalledSdk>> installed() async {
    final root = Directory(layout.versionsDir);
    if (!root.existsSync()) return [];
    final sdks = <InstalledSdk>[];
    await for (final dir in root.list()) {
      if (dir is! Directory) continue;
      final manifest = File(layout.versionManifest(p.basename(dir.path)));
      if (!manifest.existsSync()) continue; // half-installed → not listed
      try {
        final json =
            jsonDecode(await manifest.readAsString()) as Map<String, Object?>;
        sdks.add(
          InstalledSdk(
            release: FlutterRelease(
              version: SemVer.parse(json['version']! as String),
              channel:
                  Channel.tryParse(json['channel']! as String) ??
                  Channel.stable,
              gitTag: json['gitTag']! as String,
              frameworkSha: json['frameworkSha']! as String,
              dartVersion: SemVer.parse(json['dartVersion']! as String),
              releasedAt: DateTime.parse(json['releasedAt']! as String),
              artifacts: const {},
            ),
            path: dir.path,
          ),
        );
      } on Exception {
        continue; // corrupt manifest → surfaces via doctor, not here
      }
    }
    sdks.sort((a, b) => b.release.version.compareTo(a.release.version));
    return sdks;
  }

  @override
  Future<Map<String, List<String>>> references() async {
    final state = await layout.loadState();
    final refs = <String, List<String>>{};
    for (final ref in state.valueOrNull?.projects ?? const <ProjectRef>[]) {
      if (!Directory(ref.path).existsSync()) continue; // advisory registry
      refs.putIfAbsent(ref.version, () => []).add(ref.path);
    }
    return refs;
  }

  /// Stable on-disk name for a linked artifact payload.
  static String artifactFileName(ArtifactRef artifact) {
    final segments = artifact.url.pathSegments;
    return segments.isEmpty ? artifact.sha256 : segments.last;
  }
}
