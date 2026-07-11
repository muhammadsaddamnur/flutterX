/// Use cases orchestrating the engines and ports; the API the CLI and
/// future daemon consume (docs/06 §4).
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

export 'src/flutterx_api.dart';
export 'src/use_cases/install_sdk.dart';
export 'src/use_cases/list_sdks.dart';
export 'src/use_cases/manage_cache.dart';
export 'src/use_cases/manage_config.dart';
export 'src/use_cases/remove_sdk.dart';
export 'src/use_cases/run_doctor.dart';
export 'src/use_cases/show_current.dart';
export 'src/use_cases/use_sdk.dart';
