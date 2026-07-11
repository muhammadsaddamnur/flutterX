import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// A cached raw index plus its HTTP metadata.
final class CachedIndex {
  const CachedIndex({required this.body, required this.fetchedAt, this.etag});

  final String body;
  final DateTime fetchedAt;
  final String? etag;

  Duration ageAt(DateTime now) => now.difference(fetchedAt);
}

/// Raw releases-index cache under `cache/registry/` (docs/05 §3): the JSON
/// body verbatim plus a sidecar with etag + fetchedAt.
final class SnapshotCache {
  SnapshotCache({required this.cacheDir});

  final String cacheDir;

  String _bodyPath(TargetOs os) => p.join(cacheDir, 'releases-${os.name}.json');
  String _metaPath(TargetOs os) =>
      p.join(cacheDir, 'releases-${os.name}.meta.json');

  Future<CachedIndex?> read(TargetOs os) async {
    final body = File(_bodyPath(os));
    final meta = File(_metaPath(os));
    if (!body.existsSync() || !meta.existsSync()) return null;
    try {
      final json =
          jsonDecode(await meta.readAsString()) as Map<String, Object?>;
      return CachedIndex(
        body: await body.readAsString(),
        fetchedAt: DateTime.parse(json['fetchedAt']! as String),
        etag: json['etag'] as String?,
      );
    } on Exception {
      return null; // torn cache → treated as absent, refetched
    }
  }

  Future<void> write(
    TargetOs os, {
    required String body,
    required DateTime fetchedAt,
    String? etag,
  }) async {
    await Directory(cacheDir).create(recursive: true);
    await File(_bodyPath(os)).writeAsString(body);
    await _writeMeta(os, fetchedAt: fetchedAt, etag: etag);
  }

  /// Refreshes only `fetchedAt` after an HTTP 304 — the body is unchanged
  /// but the snapshot is verified current.
  Future<void> touch(TargetOs os, {required DateTime fetchedAt}) async {
    final existing = await read(os);
    if (existing == null) return;
    await _writeMeta(os, fetchedAt: fetchedAt, etag: existing.etag);
  }

  Future<void> _writeMeta(
    TargetOs os, {
    required DateTime fetchedAt,
    String? etag,
  }) => File(_metaPath(os)).writeAsString(
    jsonEncode({
      'fetchedAt': fetchedAt.toUtc().toIso8601String(),
      'etag': ?etag,
    }),
  );
}
