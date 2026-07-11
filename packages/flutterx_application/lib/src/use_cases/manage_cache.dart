import 'package:flutterx_domain/flutterx_domain.dart';

/// `flutterx cache status|refresh` (docs/04 §3.10). `gc` and `verify`
/// land with M2.8.
final class ManageCache {
  ManageCache(this._cacheOps, this._registry);

  final CacheOps _cacheOps;
  final RegistryPort _registry;

  Future<CacheStatus> status() => _cacheOps.status();

  /// Registry snapshot refresh + (unless [registryOnly]) a blobless refs
  /// refresh of the bare repo.
  Future<Result<RegistrySnapshot>> refresh({bool registryOnly = false}) async {
    final snapshot = await _registry.snapshot(refresh: true);
    if (snapshot case Err()) return snapshot;
    if (!registryOnly) {
      final git = await _cacheOps.refreshGitObjects();
      if (git case Err(:final failure)) return Result.err(failure);
    }
    return snapshot;
  }
}
