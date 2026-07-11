import 'package:flutterx_domain/flutterx_domain.dart';

/// Context-aware proxies to the resolved SDK (docs/04 §3.13): resolve via
/// the project link (fast path — no intelligence, no network), then exec
/// the real tool with argv untouched. The returned int is the child's exit
/// code, passed through verbatim (contract class 20).
final class ProxyExec {
  ProxyExec(this._projects, this._platform);

  final ProjectStore _projects;
  final PlatformPort _platform;

  /// Runs `<sdk>/bin/[tool] [args]` for the project at [cwd]. A failure
  /// Result means FlutterX itself refused (unresolved project); an Ok
  /// carries the child's exit code.
  Future<Result<int>> execute(
    String cwd,
    String tool,
    List<String> args,
  ) async {
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
    final sdkPath = await _projects.resolvedSdkPath(project);
    if (sdkPath == null) {
      return Result.err(
        StorageFailure(
          code: 'FX-STORE-008',
          message: 'no resolved SDK for ${project.rootPath}',
          nextActions: const [
            'flutterx use <version>  # pin explicitly',
            '(from Beta: flutterx resolve picks one automatically)',
          ],
        ),
      );
    }
    final exitCode = await _platform.exec(
      '$sdkPath/bin/$tool',
      args,
      workingDirectory: cwd,
    );
    return Result.ok(exitCode);
  }
}

/// `flutterx shell <version> [-- cmd …]` (docs/04 §3.11): an ephemeral
/// environment with the chosen *installed* SDK first on PATH — no project
/// state is touched.
final class ShellExec {
  ShellExec(this._sdks, this._platform);

  final SdkRepository _sdks;
  final PlatformPort _platform;

  Future<Result<int>> execute(
    String specifier, {
    List<String> command = const [],
    required String shellExecutable,
    required String currentPath,
    String? cwd,
  }) async {
    final installed = await _sdks.installed();
    final matches = installed
        .where(
          (sdk) =>
              sdk.release.version.toString() == specifier ||
              sdk.release.version.toString().startsWith('$specifier.') ||
              sdk.release.channel.name == specifier,
        )
        .toList();
    if (matches.isEmpty) {
      return Result.err(
        VersionNotFound(
          requested: specifier,
          suggestions: [
            for (final sdk in installed.take(3)) sdk.release.version.toString(),
          ],
        ),
      );
    }
    final sdk = matches.first;
    final environment = {
      'PATH': '${sdk.path}/bin:$currentPath',
      'FLUTTERX_SHELL': sdk.release.version.toString(),
    };
    final exitCode = command.isEmpty
        ? await _platform.exec(
            shellExecutable,
            const [],
            workingDirectory: cwd,
            environment: environment,
          )
        : await _platform.exec(
            command.first,
            command.skip(1).toList(),
            workingDirectory: cwd,
            environment: environment,
          );
    return Result.ok(exitCode);
  }
}
