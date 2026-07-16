import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// Process seam so unit tests can fake `dart pub` without spawning it.
typedef RunPub =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

Future<ProcessResult> _defaultRunPub(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) => Process.run(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
);

/// [DependencySimPort] over the target SDK's own `dart pub get --dry-run`
/// (docs/03 §6.1 deep mode, §8.1 step 2): authoritative because it is the
/// real resolver. Runs in a temp copy of the project's pubspec (+lock), so
/// the project is never touched; offline first, then online.
final class PubDependencySimulator implements DependencySimPort {
  PubDependencySimulator({RunPub? runPub}) : _run = runPub ?? _defaultRunPub;

  final RunPub _run;

  @override
  Future<Result<PubSimOutcome>> simulate({
    required Project project,
    required InstalledSdk targetSdk,
  }) async {
    final pubspec = File(p.join(project.rootPath, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      return const Result.err(
        StorageFailure(
          code: 'FX-SIM-001',
          message: 'no pubspec.yaml to simulate against',
        ),
      );
    }

    final tmp = await Directory.systemTemp.createTemp('flutterx_sim_');
    try {
      await pubspec.copy(p.join(tmp.path, 'pubspec.yaml'));
      final lock = File(p.join(project.rootPath, 'pubspec.lock'));
      if (lock.existsSync()) {
        // The lock baseline is what makes "(was X)" diffs meaningful.
        await lock.copy(p.join(tmp.path, 'pubspec.lock'));
      }

      final dartBin = p.join(
        targetSdk.path,
        'bin',
        Platform.isWindows ? 'dart.bat' : 'dart',
      );
      // FLUTTER_ROOT lets pub resolve `sdk: flutter` dependencies against
      // the target SDK.
      final environment = {'FLUTTER_ROOT': targetSdk.path};

      Future<ProcessResult> attempt({required bool offline}) => _run(
        dartBin,
        [
          'pub',
          'get',
          '--dry-run',
          '--no-precompile',
          if (offline) '--offline',
        ],
        workingDirectory: tmp.path,
        environment: environment,
      );

      // Offline first (docs/03 §6.1); a cache miss falls back to online.
      var result = await attempt(offline: true);
      if (result.exitCode != 0) {
        result = await attempt(offline: false);
      }
      final output = '${result.stdout}\n${result.stderr}';
      return Result.ok(
        parsePubDryRun(exitCode: result.exitCode, output: output),
      );
    } on ProcessException catch (e) {
      return Result.err(
        StorageFailure(
          code: 'FX-SIM-002',
          message: 'cannot run the target SDK\'s dart: ${e.message}',
          nextActions: const [
            'flutterx repair  # the target SDK may be corrupt',
          ],
        ),
      );
    } finally {
      await tmp.delete(recursive: true);
    }
  }
}

final _changedLine = RegExp(
  r'^[>!<]\s+([a-z_][a-z0-9_]*)\s+(\S+)\s+\(was\s+([^)\s]+)',
);
final _unchangedLine = RegExp(r'^\s{2}([a-z_][a-z0-9_]*)\s+\d');
final _constraintMention = RegExp(
  r'\b([a-z_][a-z0-9_]{2,})\s+(?:>=|<=|<|>|\^|\bany\b)',
);

/// Parses `dart pub get --dry-run` output into a [PubSimOutcome]. Pure —
/// unit-tested against recorded pub output shapes.
///
/// Success format (pub's summary): unchanged deps are plain indented
/// lines; `>`/`<`/`!` mark version changes with `(was X)`. Failure with
/// "version solving failed" means the target SDK blocks resolution; the
/// offending package names are pulled from the solver text heuristically
/// (best effort — the raw text ships in [PubSimOutcome.solverOutput]).
PubSimOutcome parsePubDryRun({required int exitCode, required String output}) {
  if (exitCode != 0) {
    final blocked = output.contains('version solving failed');
    final names = <String>{
      for (final match in _constraintMention.allMatches(output))
        match.group(1)!,
    }..removeAll(const {'sdk', 'dart', 'flutter', 'version', 'because'});
    return PubSimOutcome(
      resolvable: false,
      blocking: [
        if (names.isEmpty)
          PackageImpact(
            name: 'dependencies',
            currentVersion: SemVer.parse('0.0.0'),
            note: blocked ? 'version solving failed' : 'pub get failed',
          )
        else
          for (final name in names)
            PackageImpact(
              name: name,
              currentVersion: SemVer.parse('0.0.0'),
              note: 'involved in the solving conflict',
            ),
      ],
      solverOutput: output.trim(),
    );
  }

  final needsBump = <PackageImpact>[];
  var unaffected = 0;
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trimRight();
    final changed = _changedLine.firstMatch(line);
    if (changed != null) {
      try {
        needsBump.add(
          PackageImpact(
            name: changed.group(1)!,
            currentVersion: SemVer.parse(changed.group(3)!),
            suggestedVersion: SemVer.parse(changed.group(2)!),
          ),
        );
      } on FormatException {
        // Odd version token — skip rather than lie.
      }
      continue;
    }
    if (_unchangedLine.hasMatch(line)) unaffected++;
  }
  return PubSimOutcome(
    resolvable: true,
    unaffectedCount: unaffected,
    needsBump: needsBump,
  );
}
