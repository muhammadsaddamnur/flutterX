import 'package:args/args.dart';
import 'package:flutterx_application/flutterx_application.dart';
import 'package:flutterx_cli/src/commands/commands.dart';
import 'package:flutterx_cli/src/exit_codes.dart';
import 'package:flutterx_cli/src/output/console.dart';

/// The flutterx command-line interface (docs/04). Presentation only: maps
/// argv → use-case parameters → rendered output; contains no domain logic
/// (docs/06 §9).
final class FlutterXCli {
  FlutterXCli({
    required this.api,
    required void Function(String) out,
    required void Function(String) err,
    required this.workingDirectory,
  }) : _out = out,
       _err = err;

  final FlutterXApi api;
  final void Function(String) _out;
  final void Function(String) _err;
  final String workingDirectory;

  static const version = '0.1.0-dev';

  Future<int> run(List<String> args) async {
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

    final spec = commandSpecs.firstWhere((c) => c.name == commandResults.name);
    return spec.run(
      CommandContext(
        api: api,
        console: console,
        args: commandResults,
        workingDirectory: workingDirectory,
      ),
    );
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
    buffer.write(
      '\nGlobal flags: --json, --verbose, --no-color, --version, --help',
    );
    return buffer.toString();
  }
}
