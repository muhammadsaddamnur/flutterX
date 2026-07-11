import 'package:flutterx_domain/src/entities/evidence.dart';
import 'package:flutterx_domain/src/entities/installed_sdk.dart';
import 'package:flutterx_domain/src/entities/project.dart';
import 'package:flutterx_domain/src/entities/resolution.dart';
import 'package:flutterx_domain/src/result.dart';

/// Project-side persistence port (docs/06 §2.1) — implemented in
/// `flutterx_storage`.
abstract interface class ProjectStore {
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
