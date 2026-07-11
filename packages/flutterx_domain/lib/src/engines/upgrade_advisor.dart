import 'package:flutterx_domain/src/entities/flutter_release.dart';
import 'package:flutterx_domain/src/entities/upgrade_report.dart';

/// Inputs for one upgrade simulation (docs/03 §8.1). The deep dependency
/// simulation needs process I/O, so the application layer runs it and
/// injects the per-package outcomes here — the advisor itself stays pure.
final class UpgradeParams {
  UpgradeParams({
    required this.current,
    required this.target,
    required this.dependencySimulation,
    List<UpgradeNote> knowledgeBaseNotes = const [],
  }) : knowledgeBaseNotes = List.unmodifiable(knowledgeBaseNotes);

  final FlutterRelease current;
  final FlutterRelease target;

  /// Deep-mode result on the target SDK (docs/03 §6.1): what resolves,
  /// what needs bumps, what blocks.
  final DependencySimulation dependencySimulation;

  /// Curated notes between the two releases (docs/03 §8.1 step 3).
  final List<UpgradeNote> knowledgeBaseNotes;
}

/// Outcome of running the real resolver against the target SDK.
final class DependencySimulation {
  DependencySimulation({
    this.unaffectedCount = 0,
    List<PackageImpact> needsBump = const [],
    List<PackageImpact> blocking = const [],
  }) : needsBump = List.unmodifiable(needsBump),
       blocking = List.unmodifiable(blocking);

  final int unaffectedCount;
  final List<PackageImpact> needsBump;
  final List<PackageImpact> blocking;
}

/// Produces the dry-run impact report and verdict for an SDK upgrade
/// (docs/03 §8) — nothing is touched until the user applies.
abstract interface class UpgradeAdvisor {
  UpgradeReport advise(UpgradeParams params);
}
