import 'package:flutterx_application/src/use_cases/use_sdk.dart'
    show evidenceHash;
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:path/path.dart' as p;

/// One line of the `workspace resolve` report (docs/04 §3.12 example).
final class MemberRow {
  const MemberRow({
    required this.path,
    required this.constraintText,
    required this.candidateCount,
    this.tightest = false,
  });

  /// Workspace-root-relative member path.
  final String path;

  /// The member's dominant input: its pin, its tightest hard constraint,
  /// or `any`.
  final String constraintText;

  final int candidateCount;

  /// The member that narrows the intersection the most (`← tightest`).
  final bool tightest;
}

/// What `workspace resolve` did (docs/04 §3.12).
final class WorkspaceResolveOutcome {
  WorkspaceResolveOutcome({
    required this.chosen,
    required List<MemberRow> rows,
    List<ScanWarning> warnings = const [],
    required this.locksWritten,
  }) : rows = List.unmodifiable(rows),
       warnings = List.unmodifiable(warnings);

  final FlutterRelease chosen;
  final List<MemberRow> rows;
  final List<ScanWarning> warnings;
  final int locksWritten;
}

/// `workspace status` row: member + its current lock, if any.
final class MemberStatus {
  const MemberStatus({required this.path, this.lockedVersion});

  final String path;
  final SemVer? lockedVersion;
}

/// `flutterx workspace` (docs/04 §3.12): one policy, many packages.
/// The default reconcile policy is `single-sdk`: one version must satisfy
/// **all** members (intersection solve).
final class ManageWorkspace {
  ManageWorkspace({
    required ProjectStore projects,
    required RegistryPort registry,
    required SdkRepository sdks,
    required ConfigPort config,
    required PlatformPort platform,
    required DateTime Function() clock,
  }) : _projects = projects,
       _registry = registry,
       _sdks = sdks,
       _config = config,
       _platform = platform,
       _clock = clock;

  final ProjectStore _projects;
  final RegistryPort _registry;
  final SdkRepository _sdks;
  final ConfigPort _config;
  final PlatformPort _platform;
  final DateTime Function() _clock;

  /// Same extractor set as `resolve`: the prior lock is output, not input.
  static StandardProjectScanner _scanner() => StandardProjectScanner(
    extractors: standardExtractors()
        .where((extractor) => extractor.id != 'resolution-lock')
        .toList(),
  );

  static const _noWorkspace = StorageFailure(
    code: 'FX-STORE-010',
    message:
        'no workspace found here (no flutterx.yaml with workspace: '
        'globs at or above this directory)',
    nextActions: ['flutterx workspace init  # at the monorepo root'],
  );

  Future<Result<Workspace>> init(String cwd) => _projects.initWorkspace(cwd);

  Future<Result<(Workspace, List<MemberStatus>)>> status(String cwd) async {
    final workspace = await _projects.findWorkspace(cwd);
    if (workspace == null) return const Result.err(_noWorkspace);
    return Result.ok((
      workspace,
      [
        for (final member in workspace.members)
          MemberStatus(
            path: p.relative(member.path, from: workspace.rootPath),
            lockedVersion: (await _projects.readLock(
              member.project,
            ))?.chosen.version,
          ),
      ],
    ));
  }

  /// The `single-sdk` intersection solve (docs/04 §3.12): solve each
  /// member, intersect the candidate sets, apply the inherited policy
  /// layers (global → workspace → member, tighten-only), rank, and write
  /// every member's lock + link. Empty intersection → ResolutionConflict
  /// naming the two members that disagree (exit 11).
  Future<Result<WorkspaceResolveOutcome>> resolve(
    String cwd, {
    bool parallel = false,
    ProgressReporter onProgress = noProgress,
  }) async {
    final workspace = await _projects.findWorkspace(cwd);
    if (workspace == null) return const Result.err(_noWorkspace);
    if (workspace.members.isEmpty) {
      return Result.err(
        StorageFailure(
          code: 'FX-STORE-012',
          message:
              'the workspace at ${workspace.rootPath} matched no member '
              'projects (globs: ${workspace.memberGlobs.join(', ')})',
          nextActions: const ['check the workspace: globs in flutterx.yaml'],
        ),
      );
    }

    onProgress(
      const ProgressEvent(
        phase: 'registry',
        message: 'Fetching release registry…',
      ),
    );
    final snapshotResult = await _registry.snapshot();
    if (snapshotResult case Err(:final failure)) return Result.err(failure);
    final snapshot = snapshotResult.valueOrNull!;

    // 1. Scan + solve every member (--parallel fans the I/O out).
    onProgress(
      ProgressEvent(
        phase: 'scan',
        message: 'Solving ${workspace.members.length} member(s)…',
      ),
    );
    final solver = StandardVersionSolver();
    Future<(WorkspaceMember, ProjectEvidence, CandidateSet)> solveMember(
      WorkspaceMember member,
    ) async {
      final evidence = _scanner().scan(
        await _projects.readEvidence(member.project),
      );
      return (member, evidence, solver.solve(evidence, snapshot));
    }

    final solved = parallel
        ? await Future.wait(workspace.members.map(solveMember))
        : [for (final member in workspace.members) await solveMember(member)];

    // A member unsolvable on its own explains itself (exit 11).
    for (final (_, evidence, candidates) in solved) {
      if (candidates.isEmpty) {
        return Result.err(solver.explainEmpty(evidence, snapshot));
      }
    }

    // 2. Intersection across members.
    var intersection = [...solved.first.$3.candidates];
    for (final (_, _, candidates) in solved.skip(1)) {
      final versions = {for (final c in candidates.candidates) c.version};
      intersection = [
        for (final release in intersection)
          if (versions.contains(release.version)) release,
      ];
    }
    if (intersection.isEmpty) {
      final (a, b) = _conflictingPair(solved, workspace.rootPath);
      return Result.err(
        ResolutionConflict(
          message: 'no single SDK satisfies every workspace member',
          conflictingSourceA: a,
          conflictingSourceB: b,
          nextActions: const [
            'relax one member\'s constraint or pin, or split the workspace',
          ],
        ),
      );
    }

    // 3. Policy layers per member (docs/03 §4.3): global config →
    //    workspace root → member; tighten-only is enforced by the merger.
    final now = _clock().toUtc();
    final warnings = <ScanWarning>[];
    final globalSettings = await _config.list();
    var allowed = intersection;
    for (final (member, evidence, _) in solved) {
      final merged = mergePolicyLayers([
        PolicyLayer(source: 'global config', settings: globalSettings),
        PolicyLayer(
          source: 'workspace ${workspace.rootPath}',
          settings: workspace.policySettings,
        ),
        PolicyLayer(source: member.path, settings: member.policySettings),
      ]);
      warnings.addAll(merged.warnings);
      warnings.addAll(evidence.warnings);
      final engine = RuleEngine(buildRules(merged.settings));
      final context = RuleContext(
        evidence: evidence,
        newestKnown: snapshot.releases
            .where((release) => !release.retracted)
            .firstOrNull,
        now: now,
        candidates: allowed,
      );
      final ruled = engine.apply(allowed, context);
      if (ruled.allDenied) {
        return Result.err(engine.explainAllDenied(allowed, context, ruled));
      }
      allowed = ruled.allowed;
    }

    // 4. Rank the survivors on the combined evidence of all members.
    final combined = ProjectEvidence(
      pins: [for (final (_, e, _) in solved) ...e.pins],
      hard: [for (final (_, e, _) in solved) ...e.hard],
      hints: [for (final (_, e, _) in solved) ...e.hints],
    );
    final installed = await _sdks.installed();
    final recommendation = StandardRecommendationEngine().rank(
      CandidateSet.solved(
        allowed,
        ProvenanceTrace(
          steps: [
            TraceStep(
              description:
                  'workspace intersection of ${solved.length} member(s)',
              remaining: allowed.length,
            ),
          ],
        ),
      ),
      Signals(
        evidence: combined,
        installed: {for (final sdk in installed) sdk.release.version},
        now: now,
      ),
    );
    final chosen = recommendation.chosen.release;

    // 5. Provision once, then lock + link every member.
    final installedSdk = await _sdks.ensureInstalled(
      chosen,
      onProgress: onProgress,
    );
    if (installedSdk case Err(:final failure)) return Result.err(failure);

    var locksWritten = 0;
    for (final (member, _, _) in solved) {
      final resolution = Resolution(
        chosen: chosen,
        confidence: recommendation.confidence,
        reasons: [
          Reason(
            text:
                'workspace single-sdk: intersection of ${solved.length} '
                'member(s) (root ${workspace.rootPath})',
          ),
          ...recommendation.chosen.contributions,
        ],
        evidenceHash: await evidenceHash(_projects, member.project),
        resolvedBy: ResolvedBy.resolve,
        resolvedAt: now,
      );
      final locked = await _projects.writeLock(member.project, resolution);
      if (locked case Err(:final failure)) return Result.err(failure);
      final linked = await _projects.linkSdk(
        member.project,
        installedSdk.valueOrNull!,
      );
      if (linked case Err(:final failure)) return Result.err(failure);
      locksWritten++;
    }

    final tightestCount = solved
        .map((s) => s.$3.candidates.length)
        .reduce((a, b) => a < b ? a : b);
    return Result.ok(
      WorkspaceResolveOutcome(
        chosen: chosen,
        rows: [
          for (final (member, evidence, candidates) in solved)
            MemberRow(
              path: p.relative(member.path, from: workspace.rootPath),
              constraintText: _constraintText(evidence),
              candidateCount: candidates.candidates.length,
              tightest: candidates.candidates.length == tightestCount,
            ),
        ],
        warnings: warnings,
        locksWritten: locksWritten,
      ),
    );
  }

  /// Runs a command in every member directory (docs/04 §3.12), stopping at
  /// the first failure. Returns the last exit code (contract class 20).
  Future<Result<(int, String?)>> exec(String cwd, List<String> argv) async {
    final workspace = await _projects.findWorkspace(cwd);
    if (workspace == null) return const Result.err(_noWorkspace);
    for (final member in workspace.members) {
      final exit = await _platform.exec(
        argv.first,
        argv.sublist(1),
        workingDirectory: member.path,
      );
      if (exit != 0) {
        return Result.ok((
          exit,
          p.relative(member.path, from: workspace.rootPath),
        ));
      }
    }
    return const Result.ok((0, null));
  }

  /// The first pair of members whose candidate sets are pairwise disjoint
  /// — the docs/04 §3.12 conflict report.
  static (String, String) _conflictingPair(
    List<(WorkspaceMember, ProjectEvidence, CandidateSet)> solved,
    String rootPath,
  ) {
    for (var i = 0; i < solved.length; i++) {
      for (var j = i + 1; j < solved.length; j++) {
        final a = {for (final c in solved[i].$3.candidates) c.version};
        final b = {for (final c in solved[j].$3.candidates) c.version};
        if (a.intersection(b).isEmpty) {
          String describe(int index) =>
              '${p.relative(solved[index].$1.path, from: rootPath)} '
              '(${_constraintText(solved[index].$2)})';
          return (describe(i), describe(j));
        }
      }
    }
    // Only a 3+-way disagreement: name the two tightest members.
    final byCount = [...solved]
      ..sort((x, y) => x.$3.candidates.length - y.$3.candidates.length);
    String describe((WorkspaceMember, ProjectEvidence, CandidateSet) s) =>
        '${p.relative(s.$1.path, from: rootPath)} (${_constraintText(s.$2)})';
    return (describe(byCount[0]), describe(byCount[1]));
  }

  static String _constraintText(ProjectEvidence evidence) {
    final pin = evidence.effectivePin;
    if (pin != null) return 'pin ${pin.version} (${pin.origin})';
    final hard = evidence.hard.firstOrNull;
    if (hard != null) return '${hard.kind.name} ${hard.constraint}';
    return 'any';
  }
}
