import 'package:flutterx_domain/src/entities/flutter_release.dart';
import 'package:flutterx_domain/src/entities/installed_sdk.dart';
import 'package:flutterx_domain/src/progress.dart';
import 'package:flutterx_domain/src/result.dart';
import 'package:flutterx_domain/src/values/sem_ver.dart';

/// Options for provisioning (docs/04 §3.1).
final class InstallOptions {
  const InstallOptions({
    this.force = false,
    this.skipArtifacts = false,
    this.precachePlatforms = const [],
  });

  /// Reinstall even if present; allow retracted releases.
  final bool force;

  /// Worktree only; artifacts fetched lazily on first run.
  final bool skipArtifacts;

  /// Values forwarded to `flutter precache` (e.g. `android`, `ios`).
  final List<String> precachePlatforms;
}

/// Provisioned-SDK store port (docs/06 §2.1) — implemented in
/// `flutterx_storage` composing the git engine (docs/05 §4.1).
abstract interface class SdkRepository {
  /// Provisions [release] if missing (journaled, idempotent, resumable) and
  /// returns it. An already-installed release returns immediately.
  ///
  /// [onProgress] receives phase updates (fetch/checkout/download/…) for
  /// live display; defaults to a no-op for non-interactive callers.
  Future<Result<InstalledSdk>> ensureInstalled(
    FlutterRelease release, {
    InstallOptions options = const InstallOptions(),
    ProgressReporter onProgress = noProgress,
  });

  /// Removes the version's worktree. Fails with `ResourceInUse` when a
  /// registered project still references it (docs/04 §3.2); shared objects
  /// and artifacts are reclaimed later by GC.
  Future<Result<void>> remove(SemVer version, {bool force = false});

  /// Everything currently provisioned.
  Future<List<InstalledSdk>> installed();

  /// Which projects reference which version (advisory registry,
  /// docs/05 §6.1) — powers `list`'s USED BY column and `remove`'s check.
  Future<Map<String, List<String>>> references();
}
