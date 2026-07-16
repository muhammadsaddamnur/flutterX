/// Typed, expected failures (docs/02 §9, docs/06 §2.1, docs/08 §3).
///
/// Every failure carries a stable `code` (documented in the failure
/// catalogue and used in issue templates) plus concrete next actions for the
/// user. Expected failures are *returned* via `Result`, never thrown —
/// exceptions mean programmer error.
///
/// The hierarchy is sealed so `flutterx_cli` can map failure → exit code
/// (docs/04 §1.2) with an exhaustive, compiler-checked switch. New failure
/// kinds therefore always force an exit-code decision.
library;

sealed class FxFailure {
  const FxFailure();

  /// Stable machine-readable code, `FX-<AREA>-<NNN>` (e.g. `FX-SOLVE-001`).
  String get code;

  /// One-line human-readable cause.
  String get message;

  /// Concrete next actions shown under the error (docs/04 §1.3). May be
  /// empty, but should rarely be.
  List<String> get nextActions;

  /// Supporting lines rendered between message and next actions — e.g.
  /// the projects holding a reference, or per-candidate denial rows.
  List<String> get details => const [];

  @override
  String toString() => '$code: $message';
}

/// Network unreachable, timed out, or a download failed (exit 10).
final class NetworkFailure extends FxFailure {
  const NetworkFailure({
    required this.code,
    required this.message,
    this.nextActions = const [],
  });

  @override
  final String code;
  @override
  final String message;
  @override
  final List<String> nextActions;
}

/// No release satisfies the combined constraints (exit 11). Carries the
/// minimal conflicting pair for the explanation (docs/03 §3.2).
final class ResolutionConflict extends FxFailure {
  const ResolutionConflict({
    required this.message,
    required this.conflictingSourceA,
    required this.conflictingSourceB,
    this.nextActions = const [],
  });

  /// Evidence source names of the minimal conflicting pair
  /// (e.g. `pubspec.yaml`, `ci workflow`).
  final String conflictingSourceA;
  final String conflictingSourceB;

  @override
  List<String> get details => [
    'conflicts: $conflictingSourceA ↔ $conflictingSourceB',
  ];

  @override
  String get code => 'FX-SOLVE-002';
  @override
  final String message;
  @override
  final List<String> nextActions;
}

/// Resolution confidence was low in a non-interactive context and
/// `--accept-low` was not passed (exit 12, docs/03 §5.2).
final class LowConfidenceRefused extends FxFailure {
  const LowConfidenceRefused({required this.message});

  @override
  String get code => 'FX-RESOLVE-001';
  @override
  final String message;
  @override
  List<String> get nextActions => const [
    'run interactively to confirm the choice',
    'pass --accept-low to accept it in CI',
    'pin explicitly with `flutterx use <version>`',
  ];
}

/// A rule/policy denied the candidate(s) (exit 13). Carries the denial
/// details so the CLI can render the denial table (docs/03 §4.3).
final class PolicyDenied extends FxFailure {
  const PolicyDenied({
    required this.message,
    required this.denials,
    this.nextActions = const [],
  });

  /// Rule id → human reason, per denied candidate rendering.
  final List<({String candidate, String ruleId, String reason})> denials;

  @override
  List<String> get details => [
    for (final d in denials)
      '${d.candidate}: denied by ${d.ruleId} — ${d.reason}',
  ];

  @override
  String get code => 'FX-RULE-001';
  @override
  final String message;
  @override
  final List<String> nextActions;
}

/// A version specifier matched nothing in the registry (exit 14).
final class VersionNotFound extends FxFailure {
  const VersionNotFound({required this.requested, this.suggestions = const []});

  final String requested;

  /// Close matches to show the user.
  final List<String> suggestions;

  @override
  String get code => 'FX-SOLVE-001';
  @override
  String get message => 'version $requested not found in registry';
  @override
  List<String> get nextActions => [
    if (suggestions.isNotEmpty) 'did you mean: ${suggestions.join(', ')}',
    'flutterx list --remote  # see available releases',
    'flutterx cache refresh  # refresh the registry snapshot',
  ];
}

/// Store corruption or filesystem-level failure (exit 15).
final class StorageFailure extends FxFailure {
  const StorageFailure({
    required this.code,
    required this.message,
    this.nextActions = const ['flutterx doctor', 'flutterx repair'],
  });

  @override
  final String code;
  @override
  final String message;
  @override
  final List<String> nextActions;
}

/// Git operation failed (surfaces as storage class, exit 15; codes FX-GIT-*).
final class GitFailure extends FxFailure {
  const GitFailure({
    required this.code,
    required this.message,
    this.nextActions = const [],
  });

  @override
  final String code;
  @override
  final String message;
  @override
  final List<String> nextActions;
}

/// The Upgrade Advisor verdict is BLOCKED (exit 16, docs/03 §8.1).
final class UpgradeBlocked extends FxFailure {
  const UpgradeBlocked({required this.message, required this.remediations});

  final List<String> remediations;

  @override
  String get code => 'FX-UPGRADE-001';
  @override
  final String message;
  @override
  List<String> get nextActions => remediations;
}

/// The operation was refused because the resource is still referenced
/// (exit 17) — e.g. `remove` while projects pin the version (docs/04 §3.2).
final class ResourceInUse extends FxFailure {
  const ResourceInUse({required this.message, required this.referencedBy});

  /// Project paths (or other holders) that still reference the resource.
  final List<String> referencedBy;

  @override
  List<String> get details => referencedBy;

  @override
  String get code => 'FX-STORE-001';
  @override
  final String message;
  @override
  List<String> get nextActions => const [
    're-pin the listed projects with `flutterx use` or `flutterx resolve`',
    'pass --force to break the links',
  ];
}
