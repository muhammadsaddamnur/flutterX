import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_storage/src/download_manager.dart';
import 'package:flutterx_storage/src/store_layout.dart';
import 'package:path/path.dart' as p;

/// A committed content-addressed entry.
final class CasRef {
  const CasRef({required this.sha256, required this.payloadPath});

  final String sha256;
  final String payloadPath;
}

/// Integrity audit result (`flutterx cache verify`, docs/04 §3.10).
final class VerifyReport {
  VerifyReport({required this.checked, List<String> corrupt = const []})
    : corrupt = List.unmodifiable(corrupt);

  final int checked;

  /// sha256 addresses whose payload no longer hashes to its address.
  final List<String> corrupt;

  bool get healthy => corrupt.isEmpty;
}

/// How links are materialized — injected by the composition root so the
/// platform-specific mechanism (hardlink/symlink/junction/copy) stays in
/// `flutterx_platform` (docs/05 §5.1, docs/06 §8).
typedef CreateLink =
    Future<Result<void>> Function({
      required String targetPath,
      required String linkPath,
    });

/// The content-addressed artifact store (docs/05 §5, ADR-3).
///
/// Write-once: a committed entry (`payload` + `meta.json`) is immutable;
/// corruption detection is re-hashing. The address is the lowercase-hex
/// sha256 of the payload.
final class ArtifactStore {
  ArtifactStore({
    required this.layout,
    required this.downloads,
    required this.createLink,
  });

  final StoreLayout layout;
  final DownloadManager downloads;
  final CreateLink createLink;

  /// Ensures [artifact] exists in the CAS: download → verify → atomic move
  /// into place. Idempotent and safe under concurrent callers (the losing
  /// racer finds the entry committed and succeeds).
  Future<Result<CasRef>> ensure(ArtifactRef artifact) async {
    final sha = artifact.sha256.toLowerCase();
    final ref = CasRef(sha256: sha, payloadPath: layout.casPayload(sha));
    if (File(ref.payloadPath).existsSync()) return Result.ok(ref);

    final downloaded = await downloads.fetch(artifact.url, sha);
    switch (downloaded) {
      case Err(:final failure):
        return Result.err(failure);
      case Ok(:final value):
        final entryDir = Directory(layout.casEntryDir(sha));
        await entryDir.create(recursive: true);
        try {
          await value.rename(ref.payloadPath);
        } on FileSystemException {
          // Lost a race — someone committed the same content first.
          if (!File(ref.payloadPath).existsSync()) rethrow;
        }
        await File(p.join(entryDir.path, 'meta.json')).writeAsString(
          jsonEncode({
            'sha256': sha,
            'sourceUrl': artifact.url.toString(),
            'committedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        );
        return Result.ok(ref);
    }
  }

  /// Links a committed payload into a version tree (docs/05 §2). Idempotent:
  /// an existing target is left alone.
  Future<Result<void>> linkInto(CasRef ref, String targetPath) async {
    if (File(targetPath).existsSync() || Link(targetPath).existsSync()) {
      return const Result.ok(null);
    }
    await Directory(p.dirname(targetPath)).create(recursive: true);
    return createLink(targetPath: ref.payloadPath, linkPath: targetPath);
  }

  /// Re-hashes every payload against its address (docs/05 §5.1).
  Future<VerifyReport> verify() async {
    var checked = 0;
    final corrupt = <String>[];
    for (final sha in await _entries()) {
      checked++;
      final digest = await sha256
          .bind(File(layout.casPayload(sha)).openRead())
          .first;
      if (digest.toString() != sha) corrupt.add(sha);
    }
    return VerifyReport(checked: checked, corrupt: corrupt);
  }

  /// CAS addresses not referenced by any live manifest — GC input
  /// (docs/05 §6.2).
  Future<Set<String>> unreferenced(Set<String> live) async {
    final lowerLive = live.map((s) => s.toLowerCase()).toSet();
    return (await _entries()).where((s) => !lowerLive.contains(s)).toSet();
  }

  /// Deletes one CAS entry (GC only — never called outside `cache gc`).
  Future<void> delete(String sha) async {
    final dir = Directory(layout.casEntryDir(sha));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<Set<String>> _entries() async {
    final root = Directory(layout.artifactsDir);
    if (!root.existsSync()) return {};
    final entries = <String>{};
    await for (final shard in root.list()) {
      if (shard is! Directory) continue;
      await for (final entry in shard.list()) {
        if (entry is Directory &&
            File(p.join(entry.path, 'payload')).existsSync()) {
          entries.add(p.basename(entry.path));
        }
      }
    }
    return entries;
  }
}
