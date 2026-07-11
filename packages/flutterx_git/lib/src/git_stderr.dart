import 'package:flutterx_domain/flutterx_domain.dart';

/// Classification of a failed git invocation, driving retry/fallback
/// behavior in the engine (docs/06 §5: stderr → FxFailure translation).
enum GitErrorKind {
  /// Transient network problem — retried with backoff.
  network,

  /// The server rejected `--filter` — triggers the full-fetch fallback
  /// (docs/05 §4.1).
  filterUnsupported,

  /// The requested ref does not exist on the remote.
  refNotFound,

  /// Anything else.
  other,
}

/// Pattern table for classifying git stderr. Matching is substring-based
/// and case-insensitive; git's messages vary across versions, so patterns
/// are deliberately loose.
GitErrorKind classifyGitStderr(String stderr) {
  final lower = stderr.toLowerCase();

  const networkMarkers = [
    'could not resolve host',
    'unable to access',
    'connection timed out',
    'connection refused',
    'operation timed out',
    'early eof',
    'the remote end hung up',
    'gnutls',
    'network is unreachable',
  ];
  const filterMarkers = [
    'filtering not recognized',
    'does not support filter',
    'server does not support',
    'invalid filter-spec',
  ];
  const refMarkers = ["couldn't find remote ref", 'no such ref', 'not our ref'];

  if (filterMarkers.any(lower.contains)) return GitErrorKind.filterUnsupported;
  if (refMarkers.any(lower.contains)) return GitErrorKind.refNotFound;
  if (networkMarkers.any(lower.contains)) return GitErrorKind.network;
  return GitErrorKind.other;
}

/// Builds the public failure for a git invocation that exhausted its
/// retries/fallbacks. Stable codes per the failure catalogue:
///
/// - `FX-GIT-002` network failure (exit 10 class)
/// - `FX-GIT-003` partial fetch failed (filter rejected and fallback failed)
/// - `FX-GIT-004` remote ref not found
/// - `FX-GIT-007` unclassified git failure
FxFailure failureFor(GitErrorKind kind, String command, String stderr) {
  final detail = stderr.trim().split('\n').first;
  return switch (kind) {
    GitErrorKind.network => NetworkFailure(
      code: 'FX-GIT-002',
      message: 'git $command failed: $detail',
      nextActions: const [
        'check your network connection',
        're-run the command — fetches resume from where they stopped',
      ],
    ),
    GitErrorKind.filterUnsupported => GitFailure(
      code: 'FX-GIT-003',
      message: 'partial fetch failed: $detail',
      nextActions: const [
        're-run with a git >= 2.30 and a filter-capable remote',
      ],
    ),
    GitErrorKind.refNotFound => GitFailure(
      code: 'FX-GIT-004',
      message: 'git $command failed: $detail',
      nextActions: const [
        'flutterx cache refresh  # the registry may be ahead of the remote',
      ],
    ),
    GitErrorKind.other => GitFailure(
      code: 'FX-GIT-007',
      message: 'git $command failed: $detail',
      nextActions: const ['run with --verbose and check ~/.flutterx/logs'],
    ),
  };
}
