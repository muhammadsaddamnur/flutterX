import 'package:args/args.dart';
import 'package:flutterx_application/flutterx_application.dart';
import 'package:flutterx_cli/src/commands/commands.dart';
import 'package:flutterx_cli/src/exit_codes.dart';
import 'package:flutterx_cli/src/output/console.dart';
import 'package:flutterx_cli/src/output/progress_renderer.dart';
import 'package:flutterx_domain/flutterx_domain.dart';

/// The flutterx command-line interface (docs/04). Presentation only: maps
/// argv → use-case parameters → rendered output; contains no domain logic
/// (docs/06 §9).
final class FlutterXCli {
  FlutterXCli({
    required this.api,
    required void Function(String) out,
    required void Function(String) err,
    required this.workingDirectory,
    this.environment = const {},
    this.interactive = false,
    this.promptLine,
    void Function(String)? errRaw,
    this.progressInteractive = false,
  }) : _out = out,
       _err = err,
       _errRaw = errRaw;

  final FlutterXApi api;
  final void Function(String) _out;
  final void Function(String) _err;

  /// Raw stderr writer (no newline) for the live progress line; null in
  /// tests, where progress is not rendered.
  final void Function(String)? _errRaw;
  final String workingDirectory;

  /// Host environment (PATH, SHELL) for the shell command — injected for
  /// testability.
  final Map<String, String> environment;

  /// Whether stdin is a TTY; gates confirmation prompts (docs/04 §1.1).
  final bool interactive;

  /// Whether stderr is a TTY; gates the live (carriage-return) progress
  /// line versus plain per-phase lines.
  final bool progressInteractive;

  /// Reads one line from the user; null when non-interactive.
  final String? Function()? promptLine;

  static const version = '0.1.0-dev';

  /// Commands whose arguments pass through verbatim (docs/04 §3.13) —
  /// they never go through the arg parser, so `flutterx run --release`
  /// just works.
  static const rawCommands = {'run', 'build', 'test', 'pub', 'shell'};

  Future<int> run(List<String> args) async {
    if (args.isNotEmpty && rawCommands.contains(args.first)) {
      return _runRaw(args.first, args.sublist(1));
    }
    return _runParsed(args);
  }

  Future<int> _runRaw(String command, List<String> rest) async {
    final console = Console(write: _out, writeError: _err, color: false);

    final Result<int> result;
    switch (command) {
      case 'run' || 'build' || 'test':
        result = await api.proxy.execute(workingDirectory, 'flutter', [
          command,
          ...rest,
        ]);
      case 'pub':
        result = await api.proxy.execute(workingDirectory, 'flutter', [
          'pub',
          ...rest,
        ]);
      case 'shell':
        if (rest.isEmpty) {
          console.writeError('✗ usage: flutterx shell <version> [-- <cmd …>]');
          return ExitCodes.usage;
        }
        final separator = rest.indexOf('--');
        result = await api.shell.execute(
          rest.first,
          command: separator == -1 ? const [] : rest.sublist(separator + 1),
          shellExecutable: environment['SHELL'] ?? '/bin/sh',
          currentPath: environment['PATH'] ?? '',
          cwd: workingDirectory,
        );
      default:
        throw StateError('unreachable: $command');
    }

    return switch (result) {
      // Contract class 20: the child's exit code, verbatim (docs/04 §1.2).
      Ok(:final value) => value,
      Err(:final failure) => () {
        console.failure(failure);
        return ExitCodes.forFailure(failure);
      }(),
    };
  }

  Future<int> _runParsed(List<String> args) async {
    final parser = ArgParser(allowTrailingOptions: false)
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addFlag('version', negatable: false)
      ..addFlag('json', negatable: false, help: 'Machine-readable output.')
      ..addFlag('verbose', negatable: false)
      ..addFlag('no-color', negatable: false);
    for (final command in commandSpecs) {
      parser.addCommand(command.name, command.buildParser());
    }

    final ArgResults results;
    try {
      results = parser.parse(args);
    } on FormatException catch (e) {
      _err('✗ ${e.message}');
      _err(_usage());
      return ExitCodes.usage;
    }

    final console = Console(
      write: _out,
      writeError: _err,
      color: !(results['no-color'] as bool),
      json: results['json'] as bool,
    );

    if (results['version'] as bool) {
      console.write('flutterx $version');
      return ExitCodes.ok;
    }
    final commandResults = results.command;
    if (results['help'] as bool || commandResults == null) {
      console.write(_usage());
      return commandResults == null && !(results['help'] as bool)
          ? ExitCodes.usage
          : ExitCodes.ok;
    }

    // Live progress is stderr-only and suppressed under --json; null in
    // tests (no raw sink) → a no-op renderer.
    final progress = (_errRaw == null || console.json)
        ? null
        : ProgressRenderer(
            writeRaw: _errRaw,
            interactive: progressInteractive,
            color: !(results['no-color'] as bool),
          );

    final spec = commandSpecs.firstWhere((c) => c.name == commandResults.name);
    try {
      return await spec.run(
        CommandContext(
          api: api,
          console: console,
          args: commandResults,
          workingDirectory: workingDirectory,
          interactive: interactive,
          promptLine: promptLine,
          progress: progress,
        ),
      );
    } finally {
      // Whatever path the command exits through, the live line is cleared
      // and its animation timer stopped (a leaked timer would keep the
      // process alive).
      progress?.finish();
    }
  }

  String _usage() {
    final buffer = StringBuffer()
      ..writeln('FlutterX — Flutter Development Platform')
      ..writeln()
      ..writeln('Usage: flutterx <command> [arguments]')
      ..writeln()
      ..writeln('Commands:');
    for (final command in commandSpecs) {
      buffer.writeln('  ${command.name.padRight(10)} ${command.description}');
    }
    buffer
      ..writeln(
        '  run/build/test/pub  Proxy to the resolved SDK '
        '(args pass through verbatim)',
      )
      ..writeln('  shell      Subshell with a chosen SDK first on PATH')
      ..write(
        '\nGlobal flags: --json, --verbose, --no-color, --version, --help',
      );
    return buffer.toString();
  }
}
