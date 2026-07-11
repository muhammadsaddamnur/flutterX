import 'package:flutterx_domain/src/values/sem_ver.dart';

/// Advisor verdict (docs/03 §8.1).
enum UpgradeVerdict { safe, safeWithChanges, blocked }

/// How big the SDK jump is.
enum VersionDelta { patch, minor, major }

/// A dependency that needs attention for the upgrade to succeed.
final class PackageImpact {
  const PackageImpact({
    required this.name,
    required this.currentVersion,
    this.suggestedVersion,
    this.note,
  });

  final String name;
  final SemVer currentVersion;

  /// The version that resolves on the target SDK; `null` when none does
  /// (blocking).
  final SemVer? suggestedVersion;

  /// E.g. `has breaking changes — see notes`.
  final String? note;
}

/// A curated breaking-change note between two releases (docs/03 §8.1,
/// knowledge base).
final class UpgradeNote {
  const UpgradeNote({required this.text, this.link});

  final String text;
  final String? link;
}

/// The Upgrade Advisor's dry-run impact report (docs/03 §8).
final class UpgradeReport {
  UpgradeReport({
    required this.from,
    required this.to,
    required this.sdkDelta,
    required this.dartFrom,
    required this.dartTo,
    required this.verdict,
    this.unaffectedCount = 0,
    List<PackageImpact> needsBump = const [],
    List<PackageImpact> blocking = const [],
    List<UpgradeNote> notes = const [],
  }) : needsBump = List.unmodifiable(needsBump),
       blocking = List.unmodifiable(blocking),
       notes = List.unmodifiable(notes);

  final SemVer from;
  final SemVer to;
  final VersionDelta sdkDelta;
  final SemVer dartFrom;
  final SemVer dartTo;
  final UpgradeVerdict verdict;

  final int unaffectedCount;

  /// Packages resolvable only with newer versions (with exact suggestions).
  final List<PackageImpact> needsBump;

  /// Packages that cannot resolve on the target — upgrade is blocked.
  final List<PackageImpact> blocking;

  final List<UpgradeNote> notes;
}
