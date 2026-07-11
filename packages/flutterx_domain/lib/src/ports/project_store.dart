import 'package:flutterx_domain/src/entities/evidence.dart';
import 'package:flutterx_domain/src/entities/installed_sdk.dart';
import 'package:flutterx_domain/src/entities/project.dart';
import 'package:flutterx_domain/src/entities/resolution.dart';
import 'package:flutterx_domain/src/result.dart';

/// Project-side persistence port (docs/06 §2.1) — implemented in
/// `flutterx_storage`.
abstract interface class ProjectStore {
  /// Walks up from [startDir] to the nearest directory holding
  /// `pubspec.yaml` or `flutterx.yaml` (the shim's project-root walk,
  /// docs/02 §8.3). `null` when none is found.
  Future<Project?> findProject(String startDir);

  /// Writes the user-intent file `flutterx.yaml` (docs/04 §3.3): an exact
  /// [pinVersion], or a [policyChannel] to track on each resolve.
  Future<Result<void>> writePin(
    Project project, {
    String? pinVersion,
    String? policyChannel,
  });

  /// Collects the evidence file contents the Scanner parses (docs/03 §2.1).
  /// Missing files are simply absent — never an error.
  Future<EvidenceFiles> readEvidence(Project project);

  /// Reads the project's prior resolution, or `null` when unresolved.
  Future<Resolution?> readLock(Project project);

  /// Serializes [resolution] into `.flutterx/resolution.lock`
  /// (docs/03 §7 format).
  Future<Result<void>> writeLock(Project project, Resolution resolution);

  /// Points `.flutterx/sdk` at the installed SDK (symlink/junction per
  /// platform link mode) and registers the project in the store's project
  /// registry for GC reference counting (docs/05 §6.1).
  Future<Result<void>> linkSdk(Project project, InstalledSdk sdk);
}
