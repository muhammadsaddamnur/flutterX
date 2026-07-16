import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_storage/src/artifact_store.dart';
import 'package:flutterx_storage/src/file_journal.dart';
import 'package:flutterx_storage/src/store_gc.dart';
import 'package:flutterx_storage/src/store_layout.dart';
import 'package:flutterx_storage/src/store_lock.dart';
import 'package:path/path.dart' as p;

/// [CacheOps] over the store layout (docs/04 §3.10).
final class StoreCacheOps implements CacheOps {
  StoreCacheOps({
    required this.layout,
    required this.git,
    required this.journal,
    required this.artifacts,
    required this.lock,
    this.originUrl = 'https://github.com/flutter/flutter.git',
  }) : _gc = StoreGc(
         layout: layout,
         git: git,
         artifacts: artifacts,
         journal: journal,
         lock: lock,
       );

  final StoreLayout layout;
  final GitEngine git;
  final FileJournal journal;
  final ArtifactStore artifacts;
  final StoreLock lock;
  final String originUrl;
  final StoreGc _gc;

  @override
  Future<CacheStatus> status() async {
    final versionBytes = <String, int>{};
    final versionsDir = Directory(layout.versionsDir);
    if (versionsDir.existsSync()) {
      await for (final dir in versionsDir.list()) {
        if (dir is Directory) {
          versionBytes[p.basename(dir.path)] = await _dirBytes(dir);
        }
      }
    }

    var artifactCount = 0;
    var artifactBytes = 0;
    final artifactsDir = Directory(layout.artifactsDir);
    if (artifactsDir.existsSync()) {
      await for (final shard in artifactsDir.list()) {
        if (shard is! Directory) continue;
        await for (final entry in shard.list()) {
          if (entry is! Directory) continue;
          artifactCount++;
          artifactBytes += await _dirBytes(entry);
        }
      }
    }

    return CacheStatus(
      bareRepoBytes: await _dirBytes(Directory(layout.bareRepoDir)),
      versionBytes: versionBytes,
      artifactCount: artifactCount,
      artifactBytes: artifactBytes,
      downloadsBytes: await _dirBytes(Directory(layout.downloadsDir)),
      uncommittedJournalEntries: (await journal.uncommitted()).length,
    );
  }

  @override
  Future<Result<void>> refreshGitObjects({
    ProgressReporter onProgress = noProgress,
  }) {
    onProgress(
      const ProgressEvent(
        phase: 'fetch',
        message: 'Refreshing git objects from origin…',
      ),
    );
    return git.refreshRemote();
  }

  @override
  Future<Result<void>> recloneBareRepo({
    ProgressReporter onProgress = noProgress,
  }) {
    // Journaled + exclusive: deleting the shared repo must never race an
    // install, and an interruption must be visible (FX-R08 rolls forward
    // by re-running the clone).
    return lock.withExclusive(() async {
      final begun = await journal.begin(
        operation: 'reclone',
        target: 'bare-repo',
        stepIds: const ['delete', 'clone'],
      );
      if (begun case Err(:final failure)) return Result.err(failure);
      final entry = begun.valueOrNull! as FileJournalEntry;

      await entry.stepStarted('delete');
      final dir = Directory(layout.bareRepoDir);
      if (dir.existsSync()) await dir.delete(recursive: true);
      await entry.stepDone('delete');

      await entry.stepStarted('clone');
      onProgress(
        const ProgressEvent(
          phase: 'clone',
          message: 'Re-cloning the shared repository from origin…',
        ),
      );
      final cloned = await git.ensureBareRepo(originUrl);
      if (cloned case Err(:final failure)) return Result.err(failure);
      await entry.stepDone('clone');
      await entry.commit();
      return const Result.ok(null);
    });
  }

  @override
  Future<Result<GcReport>> gc(
    GcOptions options, {
    ProgressReporter onProgress = noProgress,
  }) {
    onProgress(
      ProgressEvent(
        phase: 'gc',
        message: options.dryRun
            ? 'Sizing reclaimable store space…'
            : 'Collecting garbage…',
      ),
    );
    return _gc.run(options);
  }

  @override
  Future<CacheVerifyReport> verify({
    ProgressReporter onProgress = noProgress,
  }) async {
    onProgress(
      const ProgressEvent(
        phase: 'verify-cas',
        message: 'Hash-auditing artifact store…',
      ),
    );
    final cas = await artifacts.verify();
    onProgress(
      const ProgressEvent(
        phase: 'verify-git',
        message: 'Checking git object health (fsck)…',
      ),
    );
    final gitHealth = Directory(layout.bareRepoDir).existsSync()
        ? await git.fsck()
        : GitHealth(healthy: true);
    return CacheVerifyReport(
      checkedArtifacts: cas.checked,
      corruptArtifacts: cas.corrupt,
      gitHealthy: gitHealth.healthy,
      gitIssues: gitHealth.issues,
    );
  }

  static Future<int> _dirBytes(Directory dir) async {
    if (!dir.existsSync()) return 0;
    var bytes = 0;
    await for (final entry in dir.list(recursive: true, followLinks: false)) {
      if (entry is File) bytes += entry.lengthSync();
    }
    return bytes;
  }
}
