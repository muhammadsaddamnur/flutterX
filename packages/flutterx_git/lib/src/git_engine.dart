import 'package:flutterx_domain/flutterx_domain.dart';

/// Repository health summary from `git fsck` (docs/06 §5), consumed by
/// `doctor`/`repair` probes.
final class GitHealth {
  GitHealth({required this.healthy, List<String> issues = const []})
    : issues = List.unmodifiable(issues);

  final bool healthy;

  /// fsck findings, one per line, empty when healthy.
  final List<String> issues;
}

/// All git operations against the shared bare repository (docs/05 §4,
/// docs/06 §5). Implemented over the system `git` binary (≥ 2.30) — never a
/// Dart reimplementation; worktrees and partial clone must be
/// battle-tested.
abstract interface class GitEngine {
  /// Creates the bare repo (with partial-clone/promisor configuration for
  /// [originUrl]) if missing. Idempotent.
  Future<Result<void>> ensureBareRepo(String originUrl);

  /// Whether [tag]'s objects are already present locally
  /// ("if tag not in bareRepo", docs/05 §4.1).
  Future<bool> hasTag(String tag);

  /// Fetches [tag] using partial clone (`--filter=blob:none`), falling back
  /// to a full tag fetch when the server rejects filters (docs/05 §4.1).
  /// Shallow fetches are never used. Transient network errors are retried.
  ///
  /// When [onProgress] is supplied, streams `git fetch --progress` so the
  /// CLI can show a live bar (this is the slow phase — hundreds of MB).
  Future<Result<void>> fetchTag(String tag, {ProgressReporter? onProgress});

  /// Refreshes all remote refs (blobless — refs only, cheap). Backs
  /// `flutterx cache refresh` (docs/04 §3.10). No-op success when the bare
  /// repo does not exist yet.
  Future<Result<void>> refreshRemote();

  /// Materializes [tag] as a detached worktree at [path] and returns the
  /// path. Blobs missing from the partial clone are fetched on checkout —
  /// which is why [onProgress] matters here too.
  Future<Result<String>> addWorktree(
    String tag,
    String path, {
    ProgressReporter? onProgress,
  });

  /// Removes the worktree at [path] via git porcelain (keeps bare-repo
  /// bookkeeping consistent, docs/05 §6.2) and prunes stale entries.
  Future<Result<void>> removeWorktree(String path);

  /// Integrity summary for doctor/repair (diagnosis FX-R04).
  Future<GitHealth> fsck();

  /// Repacks/prunes the object store (`cache gc --aggressive`, docs/05
  /// §6.2).
  Future<Result<void>> repack({bool aggressive = false});
}
