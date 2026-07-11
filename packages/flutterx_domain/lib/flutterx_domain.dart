/// Entities, value objects, failures, and the port/engine interfaces every
/// FlutterX package implements or consumes (docs/06 §2).
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

export 'src/engines/project_scanner.dart';
export 'src/engines/recommendation_engine.dart';
export 'src/engines/repair_planner.dart';
export 'src/engines/rule.dart';
export 'src/engines/upgrade_advisor.dart';
export 'src/engines/version_solver.dart';
export 'src/entities/artifact_ref.dart';
export 'src/entities/candidate_set.dart';
export 'src/entities/diagnosis.dart';
export 'src/entities/evidence.dart';
export 'src/entities/flutter_release.dart';
export 'src/entities/installed_sdk.dart';
export 'src/entities/package_meta.dart';
export 'src/entities/project.dart';
export 'src/entities/recommendation.dart';
export 'src/entities/registry_snapshot.dart';
export 'src/entities/resolution.dart';
export 'src/entities/upgrade_report.dart';
export 'src/failures/fx_failure.dart';
export 'src/ports/journal.dart';
export 'src/ports/platform_port.dart';
export 'src/ports/project_store.dart';
export 'src/ports/registry_port.dart';
export 'src/ports/sdk_repository.dart';
export 'src/result.dart';
export 'src/values/channel.dart';
export 'src/values/confidence.dart';
export 'src/values/sem_ver.dart';
export 'src/values/target_os.dart';
export 'src/values/version_constraint_x.dart';
