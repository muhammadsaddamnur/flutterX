import 'package:flutterx_domain/flutterx_domain.dart';

/// `flutterx remove <version>` (docs/04 §3.2). Matches the specifier
/// against *installed* versions only — removal never needs the network.
final class RemoveSdk {
  RemoveSdk(this._sdks);

  final SdkRepository _sdks;

  Future<Result<void>> execute(String specifier, {bool force = false}) async {
    final installed = await _sdks.installed();
    final matches = installed
        .where(
          (sdk) =>
              sdk.release.version.toString() == specifier ||
              sdk.release.version.toString().startsWith('$specifier.'),
        )
        .toList();
    if (matches.isEmpty) {
      return Result.err(
        VersionNotFound(
          requested: specifier,
          suggestions: [
            for (final sdk in installed.take(3)) sdk.release.version.toString(),
          ],
        ),
      );
    }
    if (matches.length > 1) {
      return Result.err(
        VersionNotFound(
          requested: '$specifier (ambiguous)',
          suggestions: [
            for (final sdk in matches) sdk.release.version.toString(),
          ],
        ),
      );
    }
    return _sdks.remove(matches.single.release.version, force: force);
  }
}
