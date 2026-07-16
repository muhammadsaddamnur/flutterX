import 'package:flutterx_domain/src/entities/installed_sdk.dart';
import 'package:flutterx_domain/src/entities/project.dart';
import 'package:flutterx_domain/src/entities/upgrade_report.dart';
import 'package:flutterx_domain/src/result.dart';

/// Deep-mode dependency simulation (docs/03 §6.1, §8.1 step 2) —
/// implemented in `flutterx_platform`: runs the *real* resolver
/// (`dart pub get --dry-run`, offline first then online) against
/// [targetSdk] in a temporary copy of the project's pubspec, so nothing
/// in the project is touched.
///
/// Authoritative but slower and possibly network-dependent — used by the
/// Upgrade Advisor automatically and by `resolve --deep`.
abstract interface class DependencySimPort {
  Future<Result<PubSimOutcome>> simulate({
    required Project project,
    required InstalledSdk targetSdk,
  });
}

/// Raw outcome of one real-resolver run — the application layer adapts it
/// into the engine-facing `DependencySimulation` input.
final class PubSimOutcome {
  PubSimOutcome({
    this.resolvable = true,
    this.unaffectedCount = 0,
    List<PackageImpact> needsBump = const [],
    List<PackageImpact> blocking = const [],
    this.solverOutput = '',
  }) : needsBump = List.unmodifiable(needsBump),
       blocking = List.unmodifiable(blocking);

  /// Whether `pub get` succeeded at all on the target SDK.
  final bool resolvable;

  final int unaffectedCount;

  /// Packages that resolve only with newer versions (exact suggestions).
  final List<PackageImpact> needsBump;

  /// Packages that cannot resolve on the target — upgrade is blocked.
  final List<PackageImpact> blocking;

  /// The raw solver text — shown when blocking, for human diagnosis.
  final String solverOutput;
}
