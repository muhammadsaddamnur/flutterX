import 'package:flutterx_domain/src/progress.dart';
import 'package:flutterx_domain/src/result.dart';

/// Store size breakdown for `flutterx cache status` (docs/04 §3.10).
final class CacheStatus {
  CacheStatus({
    required this.bareRepoBytes,
    required Map<String, int> versionBytes,
    required this.artifactCount,
    required this.artifactBytes,
    required this.downloadsBytes,
    required this.uncommittedJournalEntries,
  }) : versionBytes = Map.unmodifiable(versionBytes);

  final int bareRepoBytes;

  /// Per installed version: its worktree size (the marginal cost —
  /// docs/05 §2).
  final Map<String, int> versionBytes;

  final int artifactCount;
  final int artifactBytes;
  final int downloadsBytes;
  final int uncommittedJournalEntries;

  int get totalBytes =>
      bareRepoBytes +
      versionBytes.values.fold<int>(0, (a, b) => a + b) +
      artifactBytes +
      downloadsBytes;
}

/// Options for `cache gc` (docs/05 §6.2).
final class GcOptions {
  GcOptions({
    this.dryRun = false,
    this.aggressive = false,
    Set<String> keep = const {},
    this.orphanGrace = const Duration(days: 14),
    this.downloadGrace = const Duration(days: 7),
    required this.now,
  }) : keep = Set.unmodifiable(keep);

  final bool dryRun;

  /// Also repack/prune git objects — slower, reclaims more.
  final bool aggressive;

  /// Versions never reclaimed regardless of references.
  final Set<String> keep;

  /// Orphans younger than this are left alone (docs/05 §6.2 safety).
  final Duration orphanGrace;
  final Duration downloadGrace;

  /// Injected clock.
  final DateTime now;
}

/// What GC reclaimed (or would reclaim, when dry-run) — docs/04 §3.10.
final class GcReport {
  GcReport({
    Map<String, int> versionBytes = const {},
    this.artifactsRemoved = 0,
    this.artifactBytes = 0,
    this.downloadBytes = 0,
    this.adoptedArtifacts = 0,
    required this.dryRun,
  }) : versionBytes = Map.unmodifiable(versionBytes);

  /// Orphaned version → bytes reclaimed.
  final Map<String, int> versionBytes;
  final int artifactsRemoved;
  final int artifactBytes;
  final int downloadBytes;

  /// Stray files adopted into the CAS (docs/05 §4.3 precache adoption).
  final int adoptedArtifacts;
  final bool dryRun;

  int get totalBytes =>
      versionBytes.values.fold<int>(0, (a, b) => a + b) +
      artifactBytes +
      downloadBytes;
}

/// `cache verify` (docs/04 §3.10): read-only integrity audit.
final class CacheVerifyReport {
  CacheVerifyReport({
    required this.checkedArtifacts,
    List<String> corruptArtifacts = const [],
    required this.gitHealthy,
    List<String> gitIssues = const [],
  }) : corruptArtifacts = List.unmodifiable(corruptArtifacts),
       gitIssues = List.unmodifiable(gitIssues);

  final int checkedArtifacts;
  final List<String> corruptArtifacts;
  final bool gitHealthy;
  final List<String> gitIssues;

  bool get healthy => corruptArtifacts.isEmpty && gitHealthy;
}

/// Store-side cache operations (docs/04 §3.10) — implemented in
/// `flutterx_storage`. Registry refresh is orchestrated by the
/// application layer through `RegistryPort` alongside this.
abstract interface class CacheOps {
  Future<CacheStatus> status();

  /// Refreshes the bare repo's refs from origin (blobless — cheap).
  /// A store without a bare repo yet is a no-op success.
  Future<Result<void>> refreshGitObjects({
    ProgressReporter onProgress = noProgress,
  });

  /// FX-R04's destructive last resort (docs/03 §9.1): delete the bare
  /// repository and re-clone it from origin. Existing worktrees lose their
  /// backing store — a follow-up `repair` run recreates them (FX-R03).
  /// Callers gate this behind explicit consent (`--force`).
  Future<Result<void>> recloneBareRepo({
    ProgressReporter onProgress = noProgress,
  });

  /// The reference-counted collector (docs/05 §6.2): orphaned versions,
  /// unreferenced artifacts, stale downloads; adoption pass first.
  Future<Result<GcReport>> gc(
    GcOptions options, {
    ProgressReporter onProgress = noProgress,
  });

  /// Hash-audit every CAS payload + `git fsck` — read-only.
  Future<CacheVerifyReport> verify({ProgressReporter onProgress = noProgress});
}
