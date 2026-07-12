import 'package:flutterx_domain/flutterx_domain.dart';

/// `flutterx cache status|refresh|gc|verify` (docs/04 §3.10).
final class ManageCache {
  ManageCache(this._cacheOps, this._registry, this._config, this._clock);

  final CacheOps _cacheOps;
  final RegistryPort _registry;
  final ConfigPort _config;
  final DateTime Function() _clock;

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

  Future<Result<GcReport>> gc({
    bool dryRun = false,
    bool aggressive = false,
    Set<String> keep = const {},
  }) => _cacheOps.gc(
    GcOptions(
      dryRun: dryRun,
      aggressive: aggressive,
      keep: keep,
      now: _clock().toUtc(),
    ),
  );

  Future<CacheVerifyReport> verify() => _cacheOps.verify();

  /// Opt-in auto-hygiene (docs/05 §6.3): when `gc.auto` is set, a dry-run
  /// sizes what is reclaimable; the CLI prints a one-line suggestion above
  /// the configured threshold. FlutterX never deletes silently.
  Future<int?> autoHygieneSuggestion() async {
    if (await _config.get('gc.auto') != 'true') return null;
    final threshold =
        (int.tryParse(await _config.get('gc.autoThresholdMb') ?? '') ?? 500) *
        1024 *
        1024;
    final report = await gc(dryRun: true);
    final reclaimable = report.valueOrNull?.totalBytes ?? 0;
    return reclaimable >= threshold ? reclaimable : null;
  }
}
