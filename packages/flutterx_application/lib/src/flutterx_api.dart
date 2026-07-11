import 'package:flutterx_application/src/use_cases/install_sdk.dart';
import 'package:flutterx_application/src/use_cases/list_sdks.dart';
import 'package:flutterx_application/src/use_cases/manage_cache.dart';
import 'package:flutterx_application/src/use_cases/manage_config.dart';
import 'package:flutterx_application/src/use_cases/proxy_exec.dart';
import 'package:flutterx_application/src/use_cases/remove_sdk.dart';
import 'package:flutterx_application/src/use_cases/run_doctor.dart';
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
    required StoreHealthPort storeHealth,
    required PlatformHealthPort platformHealth,
    required CacheOps cacheOps,
    required ConfigPort config,
    required PlatformPort platform,
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
       list = ListSdks(sdkRepository, registry),
       doctor = RunDoctor(storeHealth, platformHealth, projectStore),
       cache = ManageCache(cacheOps, registry),
       config = ManageConfig(config),
       proxy = ProxyExec(projectStore, platform),
       shell = ShellExec(sdkRepository, platform);

  final InstallSdk install;
  final RemoveSdk remove;
  final UseSdk use;
  final ShowCurrent current;
  final ListSdks list;
  final RunDoctor doctor;
  final ManageCache cache;
  final ManageConfig config;
  final ProxyExec proxy;
  final ShellExec shell;
}
