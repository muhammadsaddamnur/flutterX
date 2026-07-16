import 'package:flutterx_application/src/use_cases/resolve_project.dart';
import 'package:flutterx_application/src/use_cases/use_sdk.dart'
    show evidenceHash;
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';

/// What `repair` did (docs/03 §9.2): per-diagnosis outcome.
final class RepairReport {
  RepairReport({
    List<String> fixed = const [],
    List<String> skipped = const [],
    List<String> failed = const [],
  }) : fixed = List.unmodifiable(fixed),
       skipped = List.unmodifiable(skipped),
       failed = List.unmodifiable(failed);

  final List<String> fixed;
  final List<String> skipped;
  final List<String> failed;

  bool get clean => failed.isEmpty;
}

/// `flutterx repair` (docs/03 §9, docs/04 §3.8): the same probes doctor
/// renders, matched against the FX-R catalogue by the pure planner, then
/// executed as idempotent steps through the ports. Running repair twice is
/// always safe — every executor checks before acting.
final class RepairEnvironment {
  RepairEnvironment({
    required StoreHealthPort storeHealth,
    required ProjectStore projects,
    required SdkRepository sdks,
    required RegistryPort registry,
    required CacheOps cacheOps,
    required ConfigPort config,
    required DateTime Function() clock,
  }) : _storeHealth = storeHealth,
       _projects = projects,
       _sdks = sdks,
       _registry = registry,
       _cacheOps = cacheOps,
       _resolve = ResolveProject(
         projects: projects,
         registry: registry,
         sdks: sdks,
         config: config,
         clock: clock,
       );

  final StoreHealthPort _storeHealth;
  final ProjectStore _projects;
  final SdkRepository _sdks;
  final RegistryPort _registry;
  final CacheOps _cacheOps;
  final ResolveProject _resolve;
  final _planner = StandardRepairPlanner();

  /// Diagnoses without fixing (doctor = this, repair = this + execute).
  Future<List<Diagnosis>> plan(String cwd) async {
    final probes = [...await _storeHealth.probeStore()];
    final project = await _projects.findProject(cwd);
    if (project != null) {
      probes.addAll(await _storeHealth.probeProject(project));
      // Stale-lock probe (FX-R02): evidence drifted since resolution.
      final lock = await _projects.readLock(project);
      if (lock != null &&
          lock.evidenceHash != await evidenceHash(_projects, project)) {
        probes.add(
          Probe(
            kind: 'stale-lock',
            subject: project.rootPath,
            ok: false,
            detail: 'evidence changed since ${lock.resolvedAt}',
          ),
        );
      }
    }
    return _planner.diagnose(HealthProbes(probes: probes));
  }

  /// Executes [diagnoses] (from [plan]), honoring `--only` and the
  /// destructive-consent rules (docs/03 §9.2). [allowReResolve] is the
  /// `--yes` consent FX-R02 requires.
  Future<RepairReport> execute(
    List<Diagnosis> diagnoses, {
    Set<String>? only,
    bool allowDestructive = false,
    bool allowReResolve = false,
    ProgressReporter onProgress = noProgress,
  }) async {
    final fixed = <String>[];
    final skipped = <String>[];
    final failed = <String>[];

    for (final diagnosis in diagnoses) {
      if (only != null && !only.contains(diagnosis.id)) {
        skipped.add('${diagnosis.id}: excluded by --only');
        continue;
      }
      if (diagnosis.plan.hasDestructiveStep && !allowDestructive) {
        skipped.add('${diagnosis.id}: destructive fix requires --force');
        continue;
      }
      onProgress(
        ProgressEvent(
          phase: 'repair-${diagnosis.id}',
          message: 'Fixing ${diagnosis.id}: ${diagnosis.summary}…',
        ),
      );
      final result = await _fix(
        diagnosis,
        allowReResolve: allowReResolve,
        onProgress: onProgress,
      );
      switch (result) {
        case Ok(:final value):
          value == null
              ? skipped.add('${diagnosis.id}: ${diagnosis.summary}')
              : fixed.add('${diagnosis.id}: $value');
        case Err(:final failure):
          failed.add('${diagnosis.id}: ${failure.message}');
      }
    }
    return RepairReport(fixed: fixed, skipped: skipped, failed: failed);
  }

  /// Ok(null) = deliberately skipped; Ok(detail) = fixed.
  Future<Result<String?>> _fix(
    Diagnosis diagnosis, {
    required bool allowReResolve,
    ProgressReporter onProgress = noProgress,
  }) async {
    switch (diagnosis.id) {
      case 'FX-R01': // broken project link → re-link from the lock
        final project = Project(rootPath: diagnosis.subject);
        final lock = await _projects.readLock(project);
        if (lock == null) {
          return const Result.err(
            StorageFailure(
              code: 'FX-STORE-008',
              message: 'no lock to re-link from — run `flutterx resolve`',
            ),
          );
        }
        final ensured = await _ensureVersion(
          lock.chosen.version,
          force: false,
          onProgress: onProgress,
        );
        if (ensured case Err(:final failure)) return Result.err(failure);
        final linked = await _projects.linkSdk(project, ensured.valueOrNull!);
        if (linked case Err(:final failure)) return Result.err(failure);
        return Result.ok('re-linked to ${lock.chosen.version}');

      case 'FX-R02': // stale lock → re-resolve (consent required)
        if (!allowReResolve) {
          return const Result.ok(null); // skipped: needs --yes (docs/03 §9.1)
        }
        final resolved = await _resolve.execute(
          diagnosis.subject,
          onProgress: onProgress,
        );
        return switch (resolved) {
          Ok(:final value) => Result.ok(
            're-resolved to ${value.recommendation.chosen.release.version}',
          ),
          Err(:final failure) => Result.err(failure),
        };

      case 'FX-R03': // corrupt worktree → remove + recreate
        final version = SemVer.parse(diagnosis.subject);
        final removed = await _sdks.remove(version, force: true);
        if (removed case Err(:final failure)) return Result.err(failure);
        final ensured = await _ensureVersion(
          version,
          force: false,
          onProgress: onProgress,
        );
        if (ensured case Err(:final failure)) return Result.err(failure);
        return Result.ok('worktree recreated');

      case 'FX-R04': // unhealthy bare repo → re-fetch objects
        final refreshed = await _cacheOps.refreshGitObjects(
          onProgress: onProgress,
        );
        if (refreshed case Err(:final failure)) return Result.err(failure);
        return Result.ok('objects re-fetched from origin');

      case 'FX-R05': // missing artifacts → re-ensure (idempotent steps)
        final ensured = await _ensureVersion(
          SemVer.parse(diagnosis.subject),
          force: true,
          onProgress: onProgress,
        );
        if (ensured case Err(:final failure)) return Result.err(failure);
        return Result.ok('artifacts re-downloaded');

      default:
        return const Result.ok(null);
    }
  }

  Future<Result<InstalledSdk>> _ensureVersion(
    SemVer version, {
    required bool force,
    ProgressReporter onProgress = noProgress,
  }) async {
    final snapshot = await _registry.snapshot();
    if (snapshot case Err(:final failure)) return Result.err(failure);
    final release = snapshot.valueOrNull!.find(version);
    if (release == null) {
      return Result.err(VersionNotFound(requested: '$version'));
    }
    return _sdks.ensureInstalled(
      release,
      options: InstallOptions(force: force),
      onProgress: onProgress,
    );
  }
}
