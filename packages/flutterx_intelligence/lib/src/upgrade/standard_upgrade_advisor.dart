import 'package:flutterx_domain/flutterx_domain.dart';

/// [UpgradeAdvisor] per docs/03 §8.1: classify the SDK jump, fold in the
/// deep dependency simulation and the curated knowledge-base notes, and
/// pronounce a verdict. Pure — the simulation ran upstream.
///
/// Verdict semantics follow the worked example in docs/03 §8.2 (the
/// section's pseudocode disagrees with its own example; the example wins,
/// noted in docs/09): blocking packages → BLOCKED; otherwise any needed
/// bumps → SAFE_WITH_CHANGES; otherwise SAFE.
final class StandardUpgradeAdvisor implements UpgradeAdvisor {
  @override
  UpgradeReport advise(UpgradeParams params) {
    final from = params.current.version;
    final to = params.target.version;
    final sim = params.dependencySimulation;

    final verdict = sim.blocking.isNotEmpty
        ? UpgradeVerdict.blocked
        : sim.needsBump.isNotEmpty
        ? UpgradeVerdict.safeWithChanges
        : UpgradeVerdict.safe;

    return UpgradeReport(
      from: from,
      to: to,
      sdkDelta: classifyDelta(from, to),
      dartFrom: params.current.dartVersion,
      dartTo: params.target.dartVersion,
      verdict: verdict,
      unaffectedCount: sim.unaffectedCount,
      needsBump: sim.needsBump,
      blocking: sim.blocking,
      notes: params.knowledgeBaseNotes,
    );
  }

  /// How big the jump is — order-independent (downgrades classify the
  /// same as the equivalent upgrade).
  static VersionDelta classifyDelta(SemVer from, SemVer to) {
    if (from.major != to.major) return VersionDelta.major;
    if (from.minor != to.minor) return VersionDelta.minor;
    return VersionDelta.patch;
  }
}
