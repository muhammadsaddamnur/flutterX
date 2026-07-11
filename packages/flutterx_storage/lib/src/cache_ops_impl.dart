import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_storage/src/file_journal.dart';
import 'package:flutterx_storage/src/store_layout.dart';
import 'package:path/path.dart' as p;

/// [CacheOps] over the store layout (docs/04 §3.10).
final class StoreCacheOps implements CacheOps {
  StoreCacheOps({
    required this.layout,
    required this.git,
    required this.journal,
  });

  final StoreLayout layout;
  final GitEngine git;
  final FileJournal journal;

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
  Future<Result<void>> refreshGitObjects() => git.refreshRemote();

  static Future<int> _dirBytes(Directory dir) async {
    if (!dir.existsSync()) return 0;
    var bytes = 0;
    await for (final entry in dir.list(recursive: true, followLinks: false)) {
      if (entry is File) bytes += entry.lengthSync();
    }
    return bytes;
  }
}
