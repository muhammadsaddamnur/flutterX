import 'package:flutterx_domain/flutterx_domain.dart';

/// One row of `flutterx list` output.
final class InstalledRow {
  const InstalledRow({required this.sdk, required this.usedBy});

  final InstalledSdk sdk;
  final List<String> usedBy;
}

/// `flutterx list` report: installed SDKs (with references) or remote
/// releases (docs/04 §3.6).
final class SdkListing {
  SdkListing({
    List<InstalledRow> installed = const [],
    List<FlutterRelease> remote = const [],
  }) : installed = List.unmodifiable(installed),
       remote = List.unmodifiable(remote);

  final List<InstalledRow> installed;
  final List<FlutterRelease> remote;
}

final class ListSdks {
  ListSdks(this._sdks, this._registry);

  final SdkRepository _sdks;
  final RegistryPort _registry;

  Future<Result<SdkListing>> execute({
    bool remote = false,
    String? filter,
    Channel? channel,
  }) async {
    if (!remote) {
      final installed = await _sdks.installed();
      final refs = await _sdks.references();
      return Result.ok(
        SdkListing(
          installed: [
            for (final sdk in installed)
              InstalledRow(
                sdk: sdk,
                usedBy: refs[sdk.release.version.toString()] ?? const [],
              ),
          ],
        ),
      );
    }

    final snapshot = await _registry.snapshot();
    if (snapshot case Err(:final failure)) return Result.err(failure);
    final releases = snapshot.valueOrNull!.releases
        .where((r) => channel == null || r.channel == channel)
        .where((r) => filter == null || r.version.toString().startsWith(filter))
        .toList();
    return Result.ok(SdkListing(remote: releases));
  }
}
