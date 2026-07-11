import 'package:flutterx_application/src/use_cases/install_sdk.dart';
import 'package:flutterx_application/src/use_cases/list_sdks.dart';
import 'package:flutterx_application/src/use_cases/remove_sdk.dart';
import 'package:flutterx_application/src/use_cases/show_current.dart';
import 'package:flutterx_application/src/use_cases/use_sdk.dart';
import 'package:flutterx_domain/flutterx_domain.dart';

/// Façade over all use cases (docs/06 §4) — the API the CLI (and a future
/// daemon or IDE plugin) consumes. Ports are injected; the composition
/// root wires real infrastructure, tests wire fakes.
final class FlutterXApi {
  FlutterXApi({
    required SdkRepository sdkRepository,
    required RegistryPort registry,
    required ProjectStore projectStore,
    DateTime Function()? clock,
  }) : install = InstallSdk(sdkRepository, registry),
       remove = RemoveSdk(sdkRepository),
       use = UseSdk(
         sdkRepository,
         registry,
         projectStore,
         clock ?? DateTime.now,
       ),
       current = ShowCurrent(projectStore),
       list = ListSdks(sdkRepository, registry);

  final InstallSdk install;
  final RemoveSdk remove;
  final UseSdk use;
  final ShowCurrent current;
  final ListSdks list;
}
