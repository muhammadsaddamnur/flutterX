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
    required PlatformHealthPort platformHealth,
    required ProjectStore projects,
    required SdkRepository sdks,
    required RegistryPort registry,
    required CacheOps cacheOps,
    required Journal journal,
    required ConfigPort config,
    required DateTime Function() clock,
  }) : _storeHealth = storeHealth,
       _platformHealth = platformHealth,
       _projects = projects,
       _sdks = sdks,
       _registry = registry,
       _cacheOps = cacheOps,
       _journal = journal,
       _clock = clock,
       _resolve = ResolveProject(
         projects: projects,
         registry: registry,
         sdks: sdks,
         config: config,
         clock: clock,
       );

  final StoreHealthPort _storeHealth;
  final PlatformHealthPort _platformHealth;
  final ProjectStore _projects;
  final SdkRepository _sdks;
  final RegistryPort _registry;
  final CacheOps _cacheOps;
  final Journal _journal;
  final DateTime Function() _clock;
  final ResolveProject _resolve;
  final _planner = StandardRepairPlanner();

  /// Diagnoses without fixing (doctor = this, repair = this + execute).
  Future<List<Diagnosis>> plan(String cwd) async {
    final probes = [
      ...await _storeHealth.probeStore(),
      // Shim drift (FX-R07) lives in the platform probes.
      ...await _platformHealth.probePlatform(),
    ];
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
      // Plans that are destructive through-and-through are gated on
      // --force; a mixed plan (e.g. FX-R04's refresh-then-reclone) still
      // runs its safe steps — the executor gates the escalation itself.
      if (diagnosis.plan.steps.every((s) => s.destructive) &&
          !allowDestructive) {
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
        allowDestructive: allowDestructive,
        onProgress: onProgress,
      );
      switch (result) {
        case Ok(:final value):
          value == null
              ? skipped.add('${diagnosis.id}: ${diagnosis.summary}')
              : fixed.add('${diagnosis.id}: $value');
        case Err(:final failure):
          // Keep the failure's remediation with it — "what now" matters
          // most on the failed path.
          failed.add(
            '${diagnosis.id}: ${failure.message}'
            '${failure.nextActions.isEmpty ? '' : ' → ${failure.nextActions.join('; ')}'}',
          );
      }
    }
    return RepairReport(fixed: fixed, skipped: skipped, failed: failed);
  }

  /// Ok(null) = deliberately skipped; Ok(detail) = fixed.
  Future<Result<String?>> _fix(
    Diagnosis diagnosis, {
    required bool allowReResolve,
    bool allowDestructive = false,
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

      case 'FX-R04': // unhealthy bare repo → re-fetch; last resort re-clone
        final refreshed = await _cacheOps.refreshGitObjects(
          onProgress: onProgress,
        );
        if (refreshed case Err(:final failure)) return Result.err(failure);
        // Re-probe: did the refresh actually heal the repository?
        final stillBroken = (await _storeHealth.probeStore()).any(
          (probe) => probe.kind == 'bare-repo' && !probe.ok,
        );
        if (!stillBroken) return Result.ok('objects re-fetched from origin');
        if (!allowDestructive) {
          return const Result.err(
            StorageFailure(
              code: 'FX-STORE-015',
              message:
                  'bare repository is still unhealthy after re-fetching '
                  'objects — the last resort is a destructive re-clone',
              nextActions: [
                'flutterx repair --yes --force  # delete + re-clone, then '
                    'run repair again to recreate worktrees',
              ],
            ),
          );
        }
        final recloned = await _cacheOps.recloneBareRepo(
          onProgress: onProgress,
        );
        if (recloned case Err(:final failure)) return Result.err(failure);
        return Result.ok(
          'bare repository re-cloned — run `flutterx repair` again to '
          'recreate the worktrees',
        );

      case 'FX-R05': // missing artifacts → re-ensure (idempotent steps)
        final ensured = await _ensureVersion(
          SemVer.parse(diagnosis.subject),
          force: true,
          onProgress: onProgress,
        );
        if (ensured case Err(:final failure)) return Result.err(failure);
        return Result.ok('artifacts re-downloaded');

      case 'FX-R06': // orphaned version → delegate to the collector
        final collected = await _cacheOps.gc(
          GcOptions(now: _clock().toUtc()),
          onProgress: onProgress,
        );
        if (collected case Err(:final failure)) return Result.err(failure);
        final report = collected.valueOrNull!;
        return Result.ok(
          report.versionBytes.containsKey(diagnosis.subject)
              ? 'orphan ${diagnosis.subject} reclaimed by gc'
              : 'gc ran — ${diagnosis.subject} kept (grace period)',
        );

      case 'FX-R07': // shim drift → reinstall (probe's ensure() heals)
        if (diagnosis.plan.steps.any((s) => s.id == 'path-guidance')) {
          // PATH is user config — the guidance is in the diagnosis text;
          // repair never edits shell profiles.
          return const Result.ok(null);
        }
        final healed = (await _platformHealth.probePlatform()).any(
          (probe) => probe.kind == 'shims' && probe.ok,
        );
        return healed
            ? const Result.ok('shims reinstalled')
            : const Result.err(
                StorageFailure(
                  code: 'FX-STORE-016',
                  message: 'shim reinstall failed — check bin/ permissions',
                ),
              );

      case 'FX-R08': // interrupted journal → per-operation policy table
        return _recoverJournalEntry(diagnosis, onProgress: onProgress);

      case 'FX-R09': // wrong tag checked out → recheckout from bare repo
        final version = SemVer.parse(diagnosis.subject);
        final removed = await _sdks.remove(version, force: true);
        if (removed case Err(:final failure)) return Result.err(failure);
        final ensured = await _ensureVersion(
          version,
          force: false,
          onProgress: onProgress,
        );
        if (ensured case Err(:final failure)) return Result.err(failure);
        return Result.ok('worktree re-checked out at tag ${diagnosis.subject}');

      default:
        return const Result.ok(null);
    }
  }

  /// FX-R08 executor: docs/05 §7's policy table — roll forward for
  /// `install`/`gc`/`reclone` (finish the idempotent steps), roll back for
  /// `remove` (restore what was being deleted). Either way the journal
  /// entry is committed afterwards so the diagnosis clears.
  Future<Result<String?>> _recoverJournalEntry(
    Diagnosis diagnosis, {
    ProgressReporter onProgress = noProgress,
  }) async {
    final space = diagnosis.subject.indexOf(' ');
    if (space < 0) return const Result.ok(null);
    final operation = diagnosis.subject.substring(0, space);
    final target = diagnosis.subject.substring(space + 1);

    final Result<void> recovered;
    final String story;
    switch (recoveryDirectionFor(operation)) {
      case RecoveryDirection.rollForward:
        switch (operation) {
          case 'install':
            recovered = await _ensureVersion(
              SemVer.parse(target),
              force: false,
              onProgress: onProgress,
            );
            story = 'rolled forward: install $target completed';
          case 'gc':
            recovered = await _cacheOps.gc(
              GcOptions(now: _clock().toUtc()),
              onProgress: onProgress,
            );
            story = 'rolled forward: gc completed';
          case 'reclone':
            // The interrupted journal is the past consent — completing a
            // half-done re-clone is the only way back to health.
            recovered = await _cacheOps.recloneBareRepo(onProgress: onProgress);
            story = 'rolled forward: bare-repo re-clone completed';
          default:
            return const Result.ok(null); // unknown op — leave as evidence
        }
      case RecoveryDirection.rollBack:
        // remove gone wrong: restore the version being deleted (the user
        // can re-run `flutterx remove` deliberately afterwards).
        recovered = await _ensureVersion(
          SemVer.parse(target),
          force: false,
          onProgress: onProgress,
        );
        story = 'rolled back: $target restored';
    }
    if (recovered case Err(:final failure)) return Result.err(failure);

    // The damage is repaired — commit the journal so FX-R08 clears.
    for (final entry in await _journal.uncommitted()) {
      if (entry.operation == operation && entry.target == target) {
        await entry.commit();
      }
    }
    return Result.ok(story);
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
