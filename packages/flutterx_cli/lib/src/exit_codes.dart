import 'package:flutterx_domain/flutterx_domain.dart';

/// The public exit-code contract (docs/04 §1.2). The switch is exhaustive
/// over the sealed [FxFailure] — adding a failure kind forces an exit-code
/// decision here at compile time.
abstract final class ExitCodes {
  static const ok = 0;
  static const generic = 1;
  static const usage = 2;

  static int forFailure(FxFailure failure) => switch (failure) {
    NetworkFailure() => 10,
    ResolutionConflict() => 11,
    LowConfidenceRefused() => 12,
    PolicyDenied() => 13,
    VersionNotFound() => 14,
    StorageFailure() => 15,
    GitFailure() => 15,
    UpgradeBlocked() => 16,
    ResourceInUse() => 17,
  };
}
