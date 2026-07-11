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

/// Store-side cache operations (docs/04 §3.10) — implemented in
/// `flutterx_storage`. Registry refresh is orchestrated by the
/// application layer through `RegistryPort` alongside this.
abstract interface class CacheOps {
  Future<CacheStatus> status();

  /// Refreshes the bare repo's refs from origin (blobless — cheap).
  /// A store without a bare repo yet is a no-op success.
  Future<Result<void>> refreshGitObjects();
}
