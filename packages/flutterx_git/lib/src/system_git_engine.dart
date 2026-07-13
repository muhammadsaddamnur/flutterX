import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/src/git_engine.dart';
import 'package:flutterx_git/src/git_progress.dart';
import 'package:flutterx_git/src/git_stderr.dart';

/// Minimal process-runner seam so unit tests can fake git without spawning
/// processes; integration tests use the real default.
typedef RunProcess =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Streaming-process seam for the slow phases (fetch/checkout) so their
/// live `--progress` output can be surfaced. Defaults to [Process.start];
/// unit tests never trigger it (they pass no reporter).
typedef StartProcess =
    Future<Process> Function(String executable, List<String> arguments);

Future<ProcessResult> _defaultRunProcess(
  String executable,
  List<String> arguments,
) => Process.run(executable, arguments);

Future<Process> _defaultStartProcess(
  String executable,
  List<String> arguments,
) => Process.start(executable, arguments);

/// [GitEngine] over the system git binary (docs/06 §5).
///
/// Requires git >= 2.30 (worktrees + partial clone are mature there); the
/// gate is checked once, lazily, and surfaces as `FX-GIT-001`.
final class SystemGitEngine implements GitEngine {
  SystemGitEngine({
    required this.bareRepoPath,
    this.gitExecutable = 'git',
    RunProcess? runProcess,
    StartProcess? startProcess,
    this.retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  }) : _run = runProcess ?? _defaultRunProcess,
       _start = startProcess ?? _defaultStartProcess;

  static const minimumGitVersion = (major: 2, minor: 30);

  /// Absolute path of the shared bare repository
  /// (`~/.flutterx/cache/git/flutter.git`, docs/05 §3).
  final String bareRepoPath;

  final String gitExecutable;

  /// Backoff schedule for transient network errors (docs/06 §5: 3 attempts).
  /// Empty in tests to avoid real sleeps.
  final List<Duration> retryDelays;

  final RunProcess _run;
  final StartProcess _start;

  bool _versionChecked = false;

  // ── GitEngine ─────────────────────────────────────────────────────────

  @override
  Future<Result<void>> ensureBareRepo(String originUrl) async {
    final gate = await _ensureSupportedGit();
    if (gate case Err(:final failure)) return Result.err(failure);

    if (await _isBareRepo()) return const Result.ok(null);

    // init + promisor config instead of `clone --bare`: the first real
    // download happens per-tag in fetchTag (docs/05 §4.1), not here.
    final steps = <List<String>>[
      ['init', '--bare', bareRepoPath],
      ['-C', bareRepoPath, 'remote', 'add', 'origin', originUrl],
      ['-C', bareRepoPath, 'config', 'remote.origin.promisor', 'true'],
      [
        '-C',
        bareRepoPath,
        'config',
        'remote.origin.partialclonefilter',
        'blob:none',
      ],
    ];
    for (final args in steps) {
      final result = await _git(args);
      if (result case Err(:final failure)) return Result.err(failure);
    }
    return const Result.ok(null);
  }

  @override
  Future<bool> hasTag(String tag) async {
    final result = await _run(gitExecutable, [
      '-C',
      bareRepoPath,
      'rev-parse',
      '-q',
      '--verify',
      'refs/tags/$tag^{commit}',
    ]);
    return result.exitCode == 0;
  }

  @override
  Future<Result<void>> fetchTag(
    String tag, {
    ProgressReporter? onProgress,
  }) async {
    final gate = await _ensureSupportedGit();
    if (gate case Err(:final failure)) return Result.err(failure);

    // Partial clone first; never shallow (docs/05 §4.1, ADR-2).
    final partial = await _fetchWithRetry(
      tag,
      filter: true,
      onProgress: onProgress,
    );
    switch (partial) {
      case Ok():
        return partial;
      case Err(:final failure):
        if (failure.code != 'FX-GIT-003') return partial;
        // Server rejected the filter → full tag fetch fallback.
        return _fetchWithRetry(tag, filter: false, onProgress: onProgress);
    }
  }

  @override
  Future<Result<void>> refreshRemote() async {
    if (!await _isBareRepo()) return const Result.ok(null);
    return _git([
      '-C',
      bareRepoPath,
      'fetch',
      '--filter=blob:none',
      '--no-write-fetch-head',
      '--tags',
      'origin',
    ]);
  }

  @override
  Future<Result<String>> addWorktree(
    String tag,
    String path, {
    ProgressReporter? onProgress,
  }) async {
    // `git worktree add` has no --progress flag; blob checkout progress
    // isn't controllable over a pipe. The caller shows an indeterminate
    // "checking out…" spinner around this — streaming still gives typed
    // failures and catches any incidental "Updating files" lines.
    final args = [
      '-C',
      bareRepoPath,
      'worktree',
      'add',
      '--detach',
      path,
      'refs/tags/$tag',
    ];
    final result = onProgress != null
        ? await _streamGit(args, onProgress, phase: 'checkout')
        : await _git(args);
    return result.map((_) => path);
  }

  @override
  Future<Result<void>> removeWorktree(String path) async {
    final removed = await _git([
      '-C',
      bareRepoPath,
      'worktree',
      'remove',
      '--force',
      path,
    ]);
    if (removed.isOk) return removed;
    // The worktree dir may already be gone (crash, manual delete) — prune
    // reconciles bookkeeping; that is a successful removal.
    final pruned = await _git(['-C', bareRepoPath, 'worktree', 'prune']);
    return pruned;
  }

  @override
  Future<GitHealth> fsck() async {
    final result = await _run(gitExecutable, [
      '-C',
      bareRepoPath,
      'fsck',
      '--no-progress',
      '--connectivity-only',
    ]);
    if (result.exitCode == 0) return GitHealth(healthy: true);
    final output = '${result.stdout}\n${result.stderr}'.trim();
    return GitHealth(
      healthy: false,
      issues: output.split('\n').where((l) => l.trim().isNotEmpty).toList(),
    );
  }

  @override
  Future<Result<void>> repack({bool aggressive = false}) => _git([
    '-C',
    bareRepoPath,
    'gc',
    if (aggressive) ...['--aggressive', '--prune=now'],
  ]);

  // ── internals ─────────────────────────────────────────────────────────

  Future<Result<void>> _ensureSupportedGit() async {
    if (_versionChecked) return const Result.ok(null);
    final ProcessResult result;
    try {
      result = await _run(gitExecutable, ['--version']);
    } on ProcessException {
      return const Result.err(
        GitFailure(
          code: 'FX-GIT-001',
          message: 'git executable not found',
          nextActions: ['install git >= 2.30 and ensure it is on PATH'],
        ),
      );
    }
    final match = RegExp(
      r'git version (\d+)\.(\d+)',
    ).firstMatch(result.stdout.toString());
    final major = int.tryParse(match?.group(1) ?? '');
    final minor = int.tryParse(match?.group(2) ?? '');
    final supported =
        major != null &&
        minor != null &&
        (major > minimumGitVersion.major ||
            (major == minimumGitVersion.major &&
                minor >= minimumGitVersion.minor));
    if (!supported) {
      return Result.err(
        GitFailure(
          code: 'FX-GIT-001',
          message:
              'git ${major ?? '?'}.${minor ?? '?'} is too old — '
              '>= ${minimumGitVersion.major}.${minimumGitVersion.minor} '
              'required (worktrees + partial clone)',
          nextActions: const ['upgrade git and re-run'],
        ),
      );
    }
    _versionChecked = true;
    return const Result.ok(null);
  }

  Future<bool> _isBareRepo() async {
    final result = await _run(gitExecutable, [
      '-C',
      bareRepoPath,
      'rev-parse',
      '--is-bare-repository',
    ]);
    return result.exitCode == 0 && result.stdout.toString().trim() == 'true';
  }

  Future<Result<void>> _fetchWithRetry(
    String tag, {
    required bool filter,
    ProgressReporter? onProgress,
  }) async {
    final args = [
      '-C',
      bareRepoPath,
      'fetch',
      if (filter) '--filter=blob:none',
      if (onProgress != null) '--progress',
      '--no-write-fetch-head',
      'origin',
      'tag',
      tag,
    ];
    FxFailure? last;
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      if (attempt > 0) await Future<void>.delayed(retryDelays[attempt - 1]);
      final result = onProgress != null
          ? await _streamGit(args, onProgress, phase: 'download')
          : await _git(args);
      switch (result) {
        case Ok():
          return result;
        case Err(:final failure):
          last = failure;
          // Only transient network errors are worth retrying.
          if (failure is! NetworkFailure) return result;
      }
    }
    return Result.err(last!);
  }

  /// Runs git with `Process.start`, streaming stderr `--progress` lines to
  /// [onProgress], and translating non-zero exits into typed failures like
  /// [_git] does. The slow phases (fetch, checkout) route through here so
  /// the CLI can show a live bar instead of appearing stuck.
  Future<Result<void>> _streamGit(
    List<String> args,
    ProgressReporter onProgress, {
    required String phase,
  }) async {
    final Process process;
    try {
      process = await _start(gitExecutable, args);
    } on ProcessException catch (e) {
      return Result.err(
        GitFailure(code: 'FX-GIT-001', message: 'cannot run git: ${e.message}'),
      );
    }
    final stderrBuffer = StringBuffer();
    // git writes progress to stderr, CR-delimited during a phase.
    final stderrDone = process.stderr.transform(utf8.decoder).listen((chunk) {
      stderrBuffer.write(chunk);
      for (final line in chunk.split(RegExp(r'[\r\n]'))) {
        final event = parseGitProgressLine(line, phase: phase);
        if (event != null) onProgress(event);
      }
    }).asFuture<void>();
    await process.stdout.drain<void>();
    final exitCode = await process.exitCode;
    await stderrDone;
    if (exitCode == 0) return const Result.ok(null);
    final stderr = stderrBuffer.toString();
    final command = args.firstWhere(
      (a) => !a.startsWith('-') && a != bareRepoPath,
      orElse: () => 'git',
    );
    return Result.err(failureFor(classifyGitStderr(stderr), command, stderr));
  }

  /// Runs git, translating non-zero exits into typed failures.
  Future<Result<void>> _git(List<String> args) async {
    final ProcessResult result;
    try {
      result = await _run(gitExecutable, args);
    } on ProcessException catch (e) {
      return Result.err(
        GitFailure(code: 'FX-GIT-001', message: 'cannot run git: ${e.message}'),
      );
    }
    if (result.exitCode == 0) return const Result.ok(null);
    final stderr = result.stderr.toString();
    final command = args.firstWhere(
      (a) => !a.startsWith('-') && a != bareRepoPath,
      orElse: () => 'git',
    );
    return Result.err(failureFor(classifyGitStderr(stderr), command, stderr));
  }
}
