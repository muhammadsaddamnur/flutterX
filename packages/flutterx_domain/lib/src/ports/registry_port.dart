import 'package:flutterx_domain/src/entities/package_meta.dart';
import 'package:flutterx_domain/src/entities/registry_snapshot.dart';
import 'package:flutterx_domain/src/result.dart';
import 'package:flutterx_domain/src/values/sem_ver.dart';

/// Release-knowledge port (docs/06 §2.1) — implemented in
/// `flutterx_registry` (releases index + pub.dev clients + caches,
/// docs/03 §1).
abstract interface class RegistryPort {
  /// The current snapshot: cached within TTL, refetched when [refresh] or
  /// expired, last-known (with its `fetchedAt` exposing staleness) when
  /// offline (docs/03 §1.2).
  Future<Result<RegistrySnapshot>> snapshot({bool refresh = false});

  /// SDK constraints of one published package version, from cache or
  /// pub.dev (Dependency Intelligence fast mode, docs/03 §6.1).
  Future<Result<PackageMeta>> packageMeta(String name, SemVer version);
}
