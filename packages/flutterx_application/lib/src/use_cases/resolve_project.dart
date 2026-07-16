import 'package:flutterx_application/src/use_cases/use_sdk.dart'
    show evidenceHash;
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';

/// Everything `resolve`/`recommend` report (docs/04 §3.4).
final class ResolveOutcome {
  ResolveOutcome({
    required this.recommendation,
    this.resolution,
    List<ScanWarning> warnings = const [],
    required this.trace,
    required this.candidatesSolved,
    required this.candidatesAllowed,
  }) : warnings = List.unmodifiable(warnings);

  final Recommendation recommendation;

  /// Set when the decision was applied (resolve); null for recommend.
  final Resolution? resolution;

  /// Scanner + policy warnings — always shown (docs/03 §2.3).
  final List<ScanWarning> warnings;

  final ProvenanceTrace trace;
  final int candidatesSolved;
  final int candidatesAllowed;

  /// Package × candidate view, set when `--matrix` was requested
  /// (docs/03 §6.2).
  CompatibilityMatrix? matrix;

  /// The `--explain` breakdown (docs/03 §5.3) — exposed here so the CLI
  /// never needs to import the intelligence package directly.
  String explain() => explainRecommendation(recommendation);
}

/// The Resolver orchestrator (docs/03 §7): a pipeline conductor that owns
/// no domain logic — scan → solve → rules → rank → (optionally) apply.
final class ResolveProject {
  ResolveProject({
    required ProjectStore projects,
    required RegistryPort registry,
    required SdkRepository sdks,
    required ConfigPort config,
    required DateTime Function() clock,
  }) : _projects = projects,
       _registry = registry,
       _sdks = sdks,
       _config = config,
       _clock = clock;

  final ProjectStore _projects;
  final RegistryPort _registry;
  final SdkRepository _sdks;
  final ConfigPort _config;
  final DateTime Function() _clock;

  /// The prior lock is this pipeline's *output*, never its input — shims
  /// and `current` treat it as the decision, but re-resolving must not be
  /// decided by it (noted in docs/09 T2.5.1).
  static StandardProjectScanner _scanner() => StandardProjectScanner(
    extractors: standardExtractors()
        .where((extractor) => extractor.id != 'resolution-lock')
        .toList(),
  );

  Future<Result<ResolveOutcome>> execute(
    String cwd, {
    bool apply = true,
    bool acceptLow = false,
    bool refresh = false,
    bool matrix = false,
    ProgressReporter onProgress = noProgress,
  }) async {
    final project = await _projects.findProject(cwd);
    if (project == null) {
      return const Result.err(
        StorageFailure(
          code: 'FX-STORE-005',
          message: 'no Dart/Flutter project found here',
          nextActions: ['cd into a project, or create pubspec.yaml'],
        ),
      );
    }

    // 1. Evidence (I/O) → scan (pure).
    final files = await _projects.readEvidence(project);
    final evidence = _scanner().scan(files);

    // 2. Registry snapshot.
    onProgress(
      const ProgressEvent(
        phase: 'registry',
        message: 'Fetching release registry…',
      ),
    );
    final snapshotResult = await _registry.snapshot(refresh: refresh);
    if (snapshotResult case Err(:final failure)) return Result.err(failure);
    final snapshot = snapshotResult.valueOrNull!;

    // 3. Solve — empty set short-circuits with the conflict story
    //    (exit 11).
    final solver = StandardVersionSolver();
    final solved = solver.solve(evidence, snapshot);
    if (solved.isEmpty) {
      return Result.err(solver.explainEmpty(evidence, snapshot));
    }

    // 4. Rules (skipped for pins — the flowchart's pin fast path).
    final now = _clock().toUtc();
    var allowed = solved;
    final warnings = [...evidence.warnings];
    var ruleModifiers = const <SemVer, int>{};
    if (!solved.isPinned) {
      final merged = mergePolicyLayers([
        PolicyLayer(source: 'global config', settings: await _config.list()),
      ]);
      warnings.addAll(merged.warnings);
      final engine = RuleEngine(buildRules(merged.settings));
      final context = RuleContext(
        evidence: evidence,
        newestKnown: snapshot.releases
            .where((release) => !release.retracted)
            .firstOrNull,
        now: now,
        candidates: solved.candidates,
      );
      final ruled = engine.apply(solved.candidates, context);
      if (ruled.allDenied) {
        return Result.err(
          engine.explainAllDenied(solved.candidates, context, ruled),
        );
      }
      allowed = CandidateSet.solved(ruled.allowed, solved.trace);
      ruleModifiers = ruled.modifiers;
    }

    // 5. Dependency Intelligence fast mode (docs/03 §6.1): metadata is
    //    per package-version (cache-first, offline-tolerant), then the
    //    per-candidate check is pure. Failures mean unverified, never
    //    blocked.
    final lockedPackages = parseLockedPackages(files['pubspec.lock'] ?? '');
    final metas = <String, PackageMeta?>{};
    final hosted = lockedPackages.where((p) => p.hosted).toList();
    for (final (index, package) in hosted.indexed) {
      onProgress(
        ProgressEvent(
          phase: 'meta',
          message:
              'Checking package compatibility '
              '(${index + 1}/${hosted.length}: ${package.name})…',
          fraction: (index + 1) / hosted.length,
        ),
      );
      final meta = await _registry.packageMeta(package.name, package.version);
      metas['${package.name}@${package.version}'] = meta.valueOrNull;
    }
    PackageMeta? metaFor(LockedPackage package) =>
        metas['${package.name}@${package.version}'];
    final compatibility = <SemVer, DependencyCompatibility>{
      if (lockedPackages.isNotEmpty)
        for (final candidate in allowed.candidates)
          candidate.version: checkCompatibility(
            candidate,
            lockedPackages,
            metaFor,
          ),
    };

    // 6. Rank.
    final installed = await _sdks.installed();
    final recommendation = StandardRecommendationEngine().rank(
      allowed,
      Signals(
        evidence: evidence,
        installed: {for (final sdk in installed) sdk.release.version},
        ruleModifiers: ruleModifiers,
        compatibility: compatibility,
        now: now,
      ),
    );

    // 6. Confidence gate (docs/03 §5.2): low needs explicit consent —
    //    the CLI prompts on a TTY and passes acceptLow.
    if (recommendation.confidence == Confidence.low && !acceptLow) {
      return Result.err(
        LowConfidenceRefused(
          message:
              'evidence is weak (${recommendation.chosen.release.version} '
              'chosen from hints/defaults only)',
        ),
      );
    }

    ResolveOutcome outcome({Resolution? resolution}) {
      final result = ResolveOutcome(
        recommendation: recommendation,
        resolution: resolution,
        warnings: warnings,
        trace: solved.trace,
        candidatesSolved: solved.candidates.length,
        candidatesAllowed: allowed.candidates.length,
      );
      if (matrix && lockedPackages.isNotEmpty) {
        // The matrix compares the chosen release and its alternatives
        // (docs/03 §6.2).
        result.matrix = buildCompatibilityMatrix(
          [
            recommendation.chosen.release,
            for (final alt in recommendation.alternatives) alt.release,
          ],
          lockedPackages,
          metaFor,
        );
      }
      return result;
    }

    if (!apply) return Result.ok(outcome());

    // 7. Apply: provision + lock + link (docs/03 §7 flowchart tail).
    final chosen = recommendation.chosen.release;
    final installedSdk = await _sdks.ensureInstalled(
      chosen,
      onProgress: onProgress,
    );
    if (installedSdk case Err(:final failure)) return Result.err(failure);

    final resolution = Resolution(
      chosen: chosen,
      confidence: recommendation.confidence,
      reasons: recommendation.chosen.contributions,
      evidenceHash: await evidenceHash(_projects, project),
      resolvedBy: ResolvedBy.resolve,
      resolvedAt: now,
    );
    final locked = await _projects.writeLock(project, resolution);
    if (locked case Err(:final failure)) return Result.err(failure);
    final linked = await _projects.linkSdk(project, installedSdk.valueOrNull!);
    if (linked case Err(:final failure)) return Result.err(failure);

    return Result.ok(outcome(resolution: resolution));
  }
}
