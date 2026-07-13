import 'package:flutterx_domain/flutterx_domain.dart';

/// `flutterx install <version>` (docs/04 §3.1): resolve the specifier
/// against the registry, then provision into the store.
final class InstallSdk {
  InstallSdk(this._sdks, this._registry);

  final SdkRepository _sdks;
  final RegistryPort _registry;

  Future<Result<InstalledSdk>> execute(
    String specifier, {
    InstallOptions options = const InstallOptions(),
    bool refreshRegistry = false,
    ProgressReporter onProgress = noProgress,
  }) async {
    final snapshot = await _registry.snapshot(refresh: refreshRegistry);
    switch (snapshot) {
      case Err(:final failure):
        return Result.err(failure);
      case Ok(:final value):
        final release = value.resolveSpecifier(specifier);
        if (release == null) {
          return Result.err(
            VersionNotFound(
              requested: specifier,
              suggestions: suggestionsFor(specifier, value),
            ),
          );
        }
        return _sdks.ensureInstalled(
          release,
          options: options,
          onProgress: onProgress,
        );
    }
  }

  /// Close matches for the "did you mean" hint: releases sharing the
  /// specifier's major.minor prefix, newest first, capped at 3.
  static List<String> suggestionsFor(
    String specifier,
    RegistrySnapshot snapshot,
  ) {
    final prefix = specifier.split('.').take(2).join('.');
    return snapshot.releases
        .where((r) => r.version.toString().startsWith(prefix))
        .map((r) => r.version.toString())
        .take(3)
        .toList();
  }
}
