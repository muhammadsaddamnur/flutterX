/// Presentation layer: command parsing, output rendering, exit codes,
/// composition root (docs/04, docs/06 §9).
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

export 'src/cli.dart';
export 'src/commands/commands.dart';
export 'src/composition_root.dart';
export 'src/exit_codes.dart';
export 'src/output/console.dart';
export 'src/output/progress_renderer.dart';
