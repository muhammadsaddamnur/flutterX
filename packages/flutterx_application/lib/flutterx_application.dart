/// Use cases orchestrating the engines and ports; the API the CLI and
/// future daemon consume (docs/06 §4).
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

// Intelligence types that surface through this package's API
// (ResolveOutcome.matrix) — re-exported so the CLI never imports the
// intelligence package directly (docs/06 §1 dependency rule).
export 'package:flutterx_intelligence/flutterx_intelligence.dart'
    show CompatibilityMatrix, PackageCompatibility;

export 'src/flutterx_api.dart';
export 'src/use_cases/install_sdk.dart';
export 'src/use_cases/list_sdks.dart';
export 'src/use_cases/manage_cache.dart';
export 'src/use_cases/manage_config.dart';
export 'src/use_cases/manage_workspace.dart';
export 'src/use_cases/proxy_exec.dart';
export 'src/use_cases/remove_sdk.dart';
export 'src/use_cases/repair_environment.dart';
export 'src/use_cases/resolve_project.dart';
export 'src/use_cases/run_doctor.dart';
export 'src/use_cases/show_current.dart';
export 'src/use_cases/upgrade_sdk.dart';
export 'src/use_cases/use_sdk.dart';
