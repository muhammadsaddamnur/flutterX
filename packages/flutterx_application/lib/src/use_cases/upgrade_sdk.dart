import 'package:flutterx_application/src/use_cases/use_sdk.dart'
    show evidenceHash;
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';

/// What `upgrade --advise` reports (docs/04 §3.9).
final class UpgradeAdvice {
  const UpgradeAdvice({
    required this.current,
    this.report,
    this.isDowngrade = false,
  });

  final SemVer current;

  /// Null when there is nothing newer to move to.
  final UpgradeReport? report;

  /// Explicit `--to` below the current version (docs/03 §8 edge case).
  final bool isDowngrade;

  bool get alreadyLatest => report == null;
}

/// What an applied upgrade did.
final class UpgradeApplied {
  UpgradeApplied({
    required this.resolution,
    List<String> bumped = const [],
    this.pubGetExitCode,
  }) : bumped = List.unmodifiable(bumped);

  final Resolution resolution;

  /// pubspec.yaml dependencies rewritten by `--bump-deps`.
  final List<String> bumped;

  /// Exit code of the post-apply `pub get`; null when it wasn't run.
  final int? pubGetExitCode;
}

/// `flutterx upgrade` (docs/03 §8, docs/04 §3.9): plan an SDK upgrade with
/// the real resolver before anything is touched, then optionally apply it.
final class UpgradeSdk {
  UpgradeSdk({
    required ProjectStore projects,
    required RegistryPort registry,
    required SdkRepository sdks,
    required DependencySimPort sim,
    required PlatformPort platform,
    required DateTime Function() clock,
  }) : _projects = projects,
       _registry = registry,
       _sdks = sdks,
       _sim = sim,
       _platform = platform,
       _clock = clock;

  final ProjectStore _projects;
  final RegistryPort _registry;
  final SdkRepository _sdks;
  final DependencySimPort _sim;
  final PlatformPort _platform;
  final DateTime Function() _clock;
  final _advisor = StandardUpgradeAdvisor();
  final _knowledgeBase = KnowledgeBase.builtin();

  /// The dry-run impact report (docs/03 §8.1). Provisions the target SDK
  /// (the simulation needs its real resolver) but changes nothing in the
  /// project.
  Future<Result<UpgradeAdvice>> advise(
    String cwd, {
    String? targetSpecifier,
    ProgressReporter onProgress = noProgress,
  }) async {
    final context = await _context(cwd);
    if (context case Err(:final failure)) return Result.err(failure);
    final (project, current, snapshot) = context.valueOrNull!;

    // Pick the target: explicit --to, or the newest allowed stable above
    // the current version.
    final FlutterRelease? target;
    if (targetSpecifier != null) {
      target = snapshot.resolveSpecifier(targetSpecifier);
      if (target == null) {
        return Result.err(VersionNotFound(requested: targetSpecifier));
      }
    } else {
      target = snapshot.releases
          .where(
            (release) =>
                release.channel == Channel.stable &&
                !release.retracted &&
                release.version > current.version,
          )
          .firstOrNull;
      if (target == null) {
        return Result.ok(UpgradeAdvice(current: current.version));
      }
    }

    // The target must still satisfy the project's hard constraints
    // (docs/03 §8 edge case: refused with the solver's conflict story).
    final evidence = StandardProjectScanner(
      extractors: standardExtractors()
          .where((extractor) => extractor.id != 'resolution-lock')
          .toList(),
    ).scan(await _projects.readEvidence(project));
    for (final constraint in evidence.hard) {
      final satisfied = switch (constraint.kind) {
        ConstraintKind.dart => constraint.constraint.allows(target.dartVersion),
        ConstraintKind.flutter => constraint.constraint.allows(target.version),
      };
      if (!satisfied) {
        return Result.err(
          ResolutionConflict(
            message:
                'target ${target.version} violates '
                '${constraint.kind.name} ${constraint.constraint} '
                '(${constraint.origin})',
            conflictingSourceA: constraint.origin,
            conflictingSourceB: '--to ${target.version}',
            nextActions: const ['relax the constraint, or pick another --to'],
          ),
        );
      }
    }

    // Provision the target (needed for its resolver) and simulate.
    final installed = await _sdks.ensureInstalled(
      target,
      onProgress: onProgress,
    );
    if (installed case Err(:final failure)) return Result.err(failure);
    final sim = await _sim.simulate(
      project: project,
      targetSdk: installed.valueOrNull!,
    );
    if (sim case Err(:final failure)) return Result.err(failure);
    final outcome = sim.valueOrNull!;

    final report = _advisor.advise(
      UpgradeParams(
        current: current,
        target: target,
        dependencySimulation: DependencySimulation(
          unaffectedCount: outcome.unaffectedCount,
          needsBump: outcome.needsBump,
          blocking: outcome.blocking,
        ),
        knowledgeBaseNotes: _knowledgeBase.entriesBetween(
          current.version,
          target.version,
        ),
      ),
    );
    return Result.ok(
      UpgradeAdvice(
        current: current.version,
        report: report,
        isDowngrade: target.version < current.version,
      ),
    );
  }

  /// Applies a previously advised upgrade (docs/04 §3.9): re-pin + lock +
  /// link, optionally bump blocking constraints, then run `pub get`.
  Future<Result<UpgradeApplied>> apply(
    String cwd,
    UpgradeReport report, {
    bool bumpDeps = false,
    ProgressReporter onProgress = noProgress,
  }) async {
    if (report.verdict == UpgradeVerdict.blocked) {
      return Result.err(
        UpgradeBlocked(
          message:
              '${report.blocking.length} package(s) cannot resolve on '
              '${report.to}',
          remediations: [
            for (final impact in report.blocking)
              '${impact.name}: ${impact.note ?? 'no resolvable version'}',
          ],
        ),
      );
    }

    final context = await _context(cwd);
    if (context case Err(:final failure)) return Result.err(failure);
    final (project, _, snapshot) = context.valueOrNull!;
    final target = snapshot.find(report.to);
    if (target == null) {
      return Result.err(VersionNotFound(requested: '${report.to}'));
    }

    final installed = await _sdks.ensureInstalled(
      target,
      onProgress: onProgress,
    );
    if (installed case Err(:final failure)) return Result.err(failure);

    var bumped = const <String>[];
    if (bumpDeps && report.needsBump.isNotEmpty) {
      final result = await _projects.bumpDependencies(project, {
        for (final impact in report.needsBump)
          impact.name: ?impact.suggestedVersion,
      });
      if (result case Err(:final failure)) return Result.err(failure);
      bumped = result.valueOrNull!;
    }

    final pinned = await _projects.writePin(
      project,
      pinVersion: '${target.version}',
    );
    if (pinned case Err(:final failure)) return Result.err(failure);
    final resolution = Resolution(
      chosen: target,
      confidence: Confidence.high,
      reasons: [
        Reason(
          text:
              'upgraded ${report.from} → ${report.to} via `flutterx '
              'upgrade` (verdict: ${report.verdict.name})',
        ),
      ],
      evidenceHash: await evidenceHash(_projects, project),
      resolvedBy: ResolvedBy.use,
      resolvedAt: _clock().toUtc(),
    );
    final locked = await _projects.writeLock(project, resolution);
    if (locked case Err(:final failure)) return Result.err(failure);
    final linked = await _projects.linkSdk(project, installed.valueOrNull!);
    if (linked case Err(:final failure)) return Result.err(failure);

    // Post-apply `pub get` with the new SDK, streamed to the user.
    final pubGetExit = await _platform.exec(
      '${installed.valueOrNull!.path}/bin/dart',
      const ['pub', 'get'],
      workingDirectory: project.rootPath,
      environment: {'FLUTTER_ROOT': installed.valueOrNull!.path},
    );

    return Result.ok(
      UpgradeApplied(
        resolution: resolution,
        bumped: bumped,
        pubGetExitCode: pubGetExit,
      ),
    );
  }

  /// Shared preamble: project + current release + snapshot.
  Future<Result<(Project, FlutterRelease, RegistrySnapshot)>> _context(
    String cwd,
  ) async {
    final project = await _projects.findProject(cwd);
    if (project == null) {
      return const Result.err(
        StorageFailure(
          code: 'FX-STORE-005',
          message: 'no Dart/Flutter project found here',
        ),
      );
    }
    final lock = await _projects.readLock(project);
    if (lock == null) {
      return const Result.err(
        StorageFailure(
          code: 'FX-STORE-008',
          message: 'nothing to upgrade from — the project is unresolved',
          nextActions: ['flutterx resolve  # or flutterx use <version>'],
        ),
      );
    }
    final snapshot = await _registry.snapshot();
    if (snapshot case Err(:final failure)) return Result.err(failure);
    // Prefer full registry data; fall back to the lock's reconstruction.
    final current =
        snapshot.valueOrNull!.find(lock.chosen.version) ?? lock.chosen;
    return Result.ok((project, current, snapshot.valueOrNull!));
  }
}
