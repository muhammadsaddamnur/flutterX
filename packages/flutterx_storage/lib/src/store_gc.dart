import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_storage/src/artifact_store.dart';
import 'package:flutterx_storage/src/file_journal.dart';
import 'package:flutterx_storage/src/store_layout.dart';
import 'package:flutterx_storage/src/store_lock.dart';
import 'package:path/path.dart' as p;

/// The reference-counted garbage collector (docs/05 §6.2).
///
/// Reference graph: live projects (registry entries whose `.flutterx/sdk`
/// still points at the version) hold versions; live versions' manifests
/// hold artifacts. Everything else is reclaimable — behind grace periods,
/// journaled, and with `--dry-run` always available.
final class StoreGc {
  StoreGc({
    required this.layout,
    required this.git,
    required this.artifacts,
    required this.journal,
    required this.lock,
  });

  final StoreLayout layout;
  final GitEngine git;
  final ArtifactStore artifacts;
  final FileJournal journal;
  final StoreLock lock;

  Future<Result<GcReport>> run(GcOptions options) {
    return lock.withExclusive(() async {
      final state = await layout.loadState();
      if (state case Err(:final failure)) return Result.err(failure);

      // 1. Live versions: validated project registry ∪ --keep.
      final live = <String>{...options.keep};
      for (final ref in state.valueOrNull!.projects) {
        final link = Link(p.join(ref.path, '.flutterx', 'sdk'));
        if (link.existsSync() && p.basename(link.targetSync()) == ref.version) {
          live.add(ref.version);
        }
      }

      // 2. Orphans past the grace period.
      final versionBytes = <String, int>{};
      final orphanDirs = <String, Directory>{};
      final versionsDir = Directory(layout.versionsDir);
      if (versionsDir.existsSync()) {
        await for (final dir in versionsDir.list()) {
          if (dir is! Directory) continue;
          final version = p.basename(dir.path);
          if (live.contains(version)) continue;
          if (_installedAt(
            version,
          ).isAfter(options.now.subtract(options.orphanGrace))) {
            continue; // young orphan — grace period (docs/05 §6.2)
          }
          versionBytes[version] = await _dirBytes(dir);
          orphanDirs[version] = dir;
        }
      }

      // 3. Adoption pass over live versions (docs/05 §4.3): stray regular
      //    files under bin/cache/artifacts return to the CAS.
      var adopted = 0;
      final adoptedRefs = <String>{};
      if (!options.dryRun) {
        for (final version in live) {
          final artifactsDir = Directory(
            p.join(layout.versionDir(version), 'bin', 'cache', 'artifacts'),
          );
          if (!artifactsDir.existsSync()) continue;
          await for (final entry in artifactsDir.list(followLinks: false)) {
            if (entry is! File) continue; // links are already CAS-backed
            final result = await artifacts.adoptFile(entry.path);
            if (result case Ok(:final value)) {
              adopted++;
              adoptedRefs.add(value.sha256);
            }
          }
        }
      }

      // 4. Live artifacts = manifests of surviving versions ∪ adopted.
      final liveArtifacts = <String>{...adoptedRefs};
      if (versionsDir.existsSync()) {
        await for (final dir in versionsDir.list()) {
          if (dir is! Directory) continue;
          final version = p.basename(dir.path);
          if (versionBytes.containsKey(version)) continue; // being removed
          final manifest = File(layout.versionManifest(version));
          if (!manifest.existsSync()) continue;
          try {
            final json =
                jsonDecode(await manifest.readAsString())
                    as Map<String, Object?>;
            for (final sha in json['artifacts'] as List<Object?>? ?? const []) {
              liveArtifacts.add((sha! as String).toLowerCase());
            }
          } on Exception {
            continue;
          }
        }
      }
      final unreferenced = await artifacts.unreferenced(liveArtifacts);
      var artifactBytes = 0;
      for (final sha in unreferenced) {
        artifactBytes += await _dirBytes(Directory(layout.casEntryDir(sha)));
      }

      // 5. Stale downloads.
      var downloadBytes = 0;
      final staleDownloads = <File>[];
      final downloadsDir = Directory(layout.downloadsDir);
      if (downloadsDir.existsSync()) {
        await for (final entry in downloadsDir.list()) {
          if (entry is! File) continue;
          if (entry.statSync().modified.isBefore(
            options.now.subtract(options.downloadGrace),
          )) {
            downloadBytes += entry.lengthSync();
            staleDownloads.add(entry);
          }
        }
      }

      final report = GcReport(
        versionBytes: versionBytes,
        artifactsRemoved: unreferenced.length,
        artifactBytes: artifactBytes,
        downloadBytes: downloadBytes,
        adoptedArtifacts: adopted,
        dryRun: options.dryRun,
      );
      if (options.dryRun) return Result.ok(report);

      // 6. Reclaim — journaled, porcelain worktree removal (docs/05 §6.2).
      final begun = await journal.begin(
        operation: 'gc',
        target: 'store',
        stepIds: const ['worktrees', 'artifacts', 'downloads', 'repack'],
      );
      if (begun case Err(:final failure)) return Result.err(failure);
      final entry = begun.valueOrNull! as FileJournalEntry;

      await entry.stepStarted('worktrees');
      for (final orphan in orphanDirs.entries) {
        await git.removeWorktree(orphan.value.path);
        if (orphan.value.existsSync()) {
          await orphan.value.delete(recursive: true);
        }
      }
      await entry.stepDone('worktrees');

      await entry.stepStarted('artifacts');
      for (final sha in unreferenced) {
        await artifacts.delete(sha);
      }
      await entry.stepDone('artifacts');

      await entry.stepStarted('downloads');
      for (final file in staleDownloads) {
        if (file.existsSync()) await file.delete();
      }
      await entry.stepDone('downloads');

      await entry.stepStarted('repack');
      if (options.aggressive) {
        final repacked = await git.repack(aggressive: true);
        if (repacked case Err(:final failure)) return Result.err(failure);
      }
      await entry.stepDone('repack');
      await entry.commit();

      return Result.ok(report);
    });
  }

  DateTime _installedAt(String version) {
    final manifest = File(layout.versionManifest(version));
    if (manifest.existsSync()) {
      try {
        final json =
            jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
        return DateTime.parse(json['installedAt']! as String);
      } on Exception {
        // fall through to directory mtime
      }
    }
    return Directory(layout.versionDir(version)).statSync().modified;
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
