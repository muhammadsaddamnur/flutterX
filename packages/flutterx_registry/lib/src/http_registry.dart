import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_registry/src/pub_meta_client.dart';
import 'package:flutterx_registry/src/releases_client.dart';
import 'package:flutterx_registry/src/releases_index.dart';
import 'package:flutterx_registry/src/seed_snapshot.g.dart' as seed;
import 'package:flutterx_registry/src/snapshot_cache.dart';

/// [RegistryPort] over the releases index (docs/03 §1.2, docs/06 §7).
///
/// Freshness policy: cached snapshot within [ttl] (default 6h) is served
/// without network; otherwise a conditional GET runs (etag → 304 is a
/// metadata-only touch). Offline behavior is honest: the last snapshot is
/// served with its true `fetchedAt` so staleness stays visible, falling
/// back to the bundled seed on a cold offline start, and failing with
/// `FX-REG-001` only when nothing exists at all.
final class HttpRegistry implements RegistryPort {
  HttpRegistry({
    required this.client,
    required this.cache,
    required this.os,
    required this.preferredArch,
    this.pubMeta,
    this.ttl = const Duration(hours: 6),
    DateTime Function()? clock,
    Map<String, String>? seedBodies,
  }) : _clock = clock ?? DateTime.now,
       _seedBodies = seedBodies ?? seed.seedReleaseIndexes;

  final ReleasesClient client;
  final SnapshotCache cache;

  /// Pub.dev metadata for Dependency Intelligence (M2.6); optional so
  /// registry-only contexts stay light.
  final PubMetaClient? pubMeta;
  final TargetOs os;

  /// Host CPU arch (`arm64`/`x64`) — picks among per-arch index entries.
  final String preferredArch;

  final Duration ttl;
  final DateTime Function() _clock;
  final Map<String, String> _seedBodies;

  @override
  Future<Result<RegistrySnapshot>> snapshot({bool refresh = false}) async {
    final now = _clock().toUtc();
    final cached = await cache.read(os);

    if (cached != null && !refresh && cached.ageAt(now) < ttl) {
      return Result.ok(_parse(cached.body, cached.fetchedAt, 'cache'));
    }

    final fetched = await client.fetch(os, etag: cached?.etag);
    switch (fetched) {
      case Ok(value: FetchedBody(:final body, :final etag)):
        await cache.write(os, body: body, fetchedAt: now, etag: etag);
        return Result.ok(_parse(body, now, client.baseUrl));
      case Ok(value: NotModified()):
        await cache.touch(os, fetchedAt: now);
        return Result.ok(_parse(cached!.body, now, 'cache'));
      case Err(:final failure):
        // Offline ladder (docs/03 §1.2): stale cache → seed → failure.
        if (cached != null) {
          return Result.ok(_parse(cached.body, cached.fetchedAt, 'cache'));
        }
        final seedBody = _seedBodies[os.name];
        if (seedBody != null) {
          return Result.ok(_parse(seedBody, seed.seedGeneratedAt, 'seed'));
        }
        return Result.err(failure);
    }
  }

  @override
  Future<Result<PackageMeta>> packageMeta(String name, SemVer version) {
    final client = pubMeta;
    if (client == null) {
      return Future.value(
        const Result.err(
          NetworkFailure(
            code: 'FX-REG-002',
            message: 'pub metadata client not configured',
          ),
        ),
      );
    }
    return client.fetch(name, version);
  }

  RegistrySnapshot _parse(String body, DateTime fetchedAt, String source) =>
      parseReleasesIndex(
        body,
        os: os,
        preferredArch: preferredArch,
        fetchedAt: fetchedAt,
        source: source,
      );
}
