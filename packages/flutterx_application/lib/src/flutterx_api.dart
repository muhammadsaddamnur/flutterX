import 'package:flutterx_application/src/use_cases/install_sdk.dart';
import 'package:flutterx_application/src/use_cases/list_sdks.dart';
import 'package:flutterx_application/src/use_cases/manage_cache.dart';
import 'package:flutterx_application/src/use_cases/manage_config.dart';
import 'package:flutterx_application/src/use_cases/proxy_exec.dart';
import 'package:flutterx_application/src/use_cases/remove_sdk.dart';
import 'package:flutterx_application/src/use_cases/repair_environment.dart';
import 'package:flutterx_application/src/use_cases/resolve_project.dart';
import 'package:flutterx_application/src/use_cases/run_doctor.dart';
import 'package:flutterx_application/src/use_cases/show_current.dart';
import 'package:flutterx_application/src/use_cases/upgrade_sdk.dart';
import 'package:flutterx_application/src/use_cases/use_sdk.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';

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
    required DependencySimPort dependencySim,
    ProjectScanner? scanner,
    DateTime Function()? clock,
  }) : install = InstallSdk(sdkRepository, registry),
       remove = RemoveSdk(sdkRepository),
       use = UseSdk(
         sdkRepository,
         registry,
         projectStore,
         scanner ?? StandardProjectScanner(),
         clock ?? DateTime.now,
       ),
       current = ShowCurrent(projectStore, scanner ?? StandardProjectScanner()),
       list = ListSdks(sdkRepository, registry),
       doctor = RunDoctor(storeHealth, platformHealth, projectStore),
       cache = ManageCache(cacheOps, registry, config, clock ?? DateTime.now),
       config = ManageConfig(config),
       proxy = ProxyExec(projectStore, platform),
       shell = ShellExec(sdkRepository, platform),
       resolve = ResolveProject(
         projects: projectStore,
         registry: registry,
         sdks: sdkRepository,
         config: config,
         clock: clock ?? DateTime.now,
       ),
       upgrade = UpgradeSdk(
         projects: projectStore,
         registry: registry,
         sdks: sdkRepository,
         sim: dependencySim,
         platform: platform,
         clock: clock ?? DateTime.now,
       ),
       repair = RepairEnvironment(
         storeHealth: storeHealth,
         projects: projectStore,
         sdks: sdkRepository,
         registry: registry,
         cacheOps: cacheOps,
         config: config,
         clock: clock ?? DateTime.now,
       );

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
  final ResolveProject resolve;
  final RepairEnvironment repair;
  final UpgradeSdk upgrade;
}
