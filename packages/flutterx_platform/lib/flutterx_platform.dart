/// OS abstraction: paths, links, process execution, shims (docs/06 §8).
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

export 'src/platform_health.dart';
export 'src/shim_installer.dart';
