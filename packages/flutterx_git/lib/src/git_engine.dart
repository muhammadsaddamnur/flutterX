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
  Future<Result<void>> fetchTag(String tag);

  /// Materializes [tag] as a detached worktree at [path] and returns the
  /// path. Blobs missing from the partial clone are fetched on checkout.
  Future<Result<String>> addWorktree(String tag, String path);

  /// Removes the worktree at [path] via git porcelain (keeps bare-repo
  /// bookkeeping consistent, docs/05 §6.2) and prunes stale entries.
  Future<Result<void>> removeWorktree(String path);

  /// Integrity summary for doctor/repair (diagnosis FX-R04).
  Future<GitHealth> fsck();

  /// Repacks/prunes the object store (`cache gc --aggressive`, docs/05
  /// §6.2).
  Future<Result<void>> repack({bool aggressive = false});
}
