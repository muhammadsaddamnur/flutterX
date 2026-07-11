/// Git infrastructure: bare repo management, partial-clone fetches,
/// worktrees, integrity checks (docs/05 §4, docs/06 §5).
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

export 'src/git_engine.dart';
export 'src/system_git_engine.dart' show RunProcess, SystemGitEngine;
