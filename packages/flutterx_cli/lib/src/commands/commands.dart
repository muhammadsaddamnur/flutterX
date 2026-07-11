import 'package:args/args.dart';
import 'package:flutterx_application/flutterx_application.dart';
import 'package:flutterx_cli/src/exit_codes.dart';
import 'package:flutterx_cli/src/output/console.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// Everything a command handler needs.
final class CommandContext {
  const CommandContext({
    required this.api,
    required this.console,
    required this.args,
    required this.workingDirectory,
  });

  final FlutterXApi api;
  final Console console;
  final ArgResults args;
  final String workingDirectory;
}

/// One CLI command: name, help, flags, handler. Handlers only map
/// arguments and render results (docs/06 §9) — logic lives below the
/// application layer.
final class CommandSpec {
  const CommandSpec({
    required this.name,
    required this.description,
    required this.configure,
    required this.run,
  });

  final String name;
  final String description;
  final void Function(ArgParser parser) configure;
  final Future<int> Function(CommandContext ctx) run;

  ArgParser buildParser() {
    final parser = ArgParser();
    configure(parser);
    return parser;
  }
}

/// Renders a failure per the documented format and maps it to its exit
/// code — the single funnel every command returns errors through.
int fail(Console console, FxFailure failure) {
  if (console.json) {
    console.emitJson(ok: false, error: failure);
  } else {
    console.failure(failure);
  }
  return ExitCodes.forFailure(failure);
}

/// The M1.6 command set (docs/04 §3.1–§3.6). Later milestones append here.
final commandSpecs = <CommandSpec>[
  CommandSpec(
    name: 'install',
    description: 'Provision an SDK version into the shared store.',
    configure: (parser) => parser
      ..addFlag('force', negatable: false)
      ..addFlag('skip-artifacts', negatable: false)
      ..addFlag('refresh', negatable: false),
    run: (ctx) async {
      final rest = ctx.args.rest;
      if (rest.length != 1) {
        ctx.console.writeError('✗ usage: flutterx install <version>');
        return ExitCodes.usage;
      }
      final result = await ctx.api.install.execute(
        rest.single,
        options: InstallOptions(
          force: ctx.args['force'] as bool,
          skipArtifacts: ctx.args['skip-artifacts'] as bool,
        ),
        refreshRegistry: ctx.args['refresh'] as bool,
      );
      switch (result) {
        case Err(:final failure):
          return fail(ctx.console, failure);
        case Ok(:final value):
          final r = value.release;
          if (ctx.console.json) {
            ctx.console.emitJson(
              ok: true,
              data: {'version': '${r.version}', 'path': value.path},
            );
          } else {
            ctx.console.success(
              'Flutter ${r.version} (Dart ${r.dartVersion}) installed '
              'at ${value.path}',
            );
          }
          return ExitCodes.ok;
      }
    },
  ),
  CommandSpec(
    name: 'remove',
    description: 'Delete an SDK version from the store.',
    configure: (parser) => parser..addFlag('force', negatable: false),
    run: (ctx) async {
      final rest = ctx.args.rest;
      if (rest.length != 1) {
        ctx.console.writeError('✗ usage: flutterx remove <version>');
        return ExitCodes.usage;
      }
      final result = await ctx.api.remove.execute(
        rest.single,
        force: ctx.args['force'] as bool,
      );
      switch (result) {
        case Err(:final failure):
          return fail(ctx.console, failure);
        case Ok():
          if (ctx.console.json) {
            ctx.console.emitJson(ok: true, data: {'removed': rest.single});
          } else {
            ctx.console.success('Flutter ${rest.single} removed');
          }
          return ExitCodes.ok;
      }
    },
  ),
  CommandSpec(
    name: 'list',
    description: 'List installed SDKs, or --remote for available releases.',
    configure: (parser) => parser
      ..addFlag('remote', negatable: false)
      ..addOption('channel', allowed: ['stable', 'beta', 'dev', 'master']),
    run: (ctx) async {
      final channelName = ctx.args['channel'] as String?;
      final result = await ctx.api.list.execute(
        remote: ctx.args['remote'] as bool,
        filter: ctx.args.rest.isEmpty ? null : ctx.args.rest.single,
        channel: channelName == null ? null : Channel.tryParse(channelName),
      );
      switch (result) {
        case Err(:final failure):
          return fail(ctx.console, failure);
        case Ok(:final value):
          if (ctx.console.json) {
            ctx.console.emitJson(
              ok: true,
              data: {
                'installed': [
                  for (final row in value.installed)
                    {
                      'version': '${row.sdk.release.version}',
                      'dart': '${row.sdk.release.dartVersion}',
                      'channel': row.sdk.release.channel.name,
                      'usedBy': row.usedBy,
                    },
                ],
                'remote': [
                  for (final r in value.remote)
                    {
                      'version': '${r.version}',
                      'dart': '${r.dartVersion}',
                      'channel': r.channel.name,
                    },
                ],
              },
            );
            return ExitCodes.ok;
          }
          if (ctx.args['remote'] as bool) {
            ctx.console.table([
              ['VERSION', 'DART', 'CHANNEL'],
              for (final r in value.remote)
                ['${r.version}', '${r.dartVersion}', r.channel.name],
            ]);
          } else if (value.installed.isEmpty) {
            ctx.console.info(
              'no SDKs installed — try `flutterx install stable`',
            );
          } else {
            ctx.console.table([
              ['VERSION', 'DART', 'CHANNEL', 'USED BY'],
              for (final row in value.installed)
                [
                  '${row.sdk.release.version}',
                  '${row.sdk.release.dartVersion}',
                  row.sdk.release.channel.name,
                  row.usedBy.isEmpty
                      ? '—'
                      : row.usedBy.map(p.basename).join(', '),
                ],
            ]);
          }
          return ExitCodes.ok;
      }
    },
  ),
  CommandSpec(
    name: 'use',
    description: 'Pin the current project to an SDK version.',
    configure: (parser) => parser
      ..addOption('policy', help: 'Track a channel instead of an exact pin.')
      ..addFlag('no-install', negatable: false),
    run: (ctx) async {
      final rest = ctx.args.rest;
      if (rest.length != 1) {
        ctx.console.writeError('✗ usage: flutterx use <version>');
        return ExitCodes.usage;
      }
      final result = await ctx.api.use.execute(
        ctx.workingDirectory,
        rest.single,
        policyChannel: ctx.args['policy'] as String?,
        noInstall: ctx.args['no-install'] as bool,
      );
      switch (result) {
        case Err(:final failure):
          return fail(ctx.console, failure);
        case Ok(:final value):
          final r = value.chosen;
          if (ctx.console.json) {
            ctx.console.emitJson(
              ok: true,
              data: {'flutter': '${r.version}', 'dart': '${r.dartVersion}'},
            );
            return ExitCodes.ok;
          }
          ctx.console.success(
            'project pinned to Flutter ${r.version} (Dart ${r.dartVersion})',
          );
          ctx.console.success(
            'flutterx.yaml + .flutterx/resolution.lock written',
          );
          ctx.console.info(
            'commit resolution.lock; add .flutterx/sdk to .gitignore',
          );
          return ExitCodes.ok;
      }
    },
  ),
  CommandSpec(
    name: 'current',
    description: 'Show the active SDK for this directory.',
    configure: (_) {},
    run: (ctx) async {
      final info = await ctx.api.current.execute(ctx.workingDirectory);
      if (ctx.console.json) {
        ctx.console.emitJson(
          ok: true,
          data: {
            'project': info.project?.rootPath,
            'flutter': info.resolution == null
                ? null
                : '${info.resolution!.chosen.version}',
            'dart': info.resolution == null
                ? null
                : '${info.resolution!.chosen.dartVersion}',
            'lockFresh': info.lockFresh,
          },
        );
        return ExitCodes.ok;
      }
      if (!info.insideProject) {
        ctx.console.info('not inside a Dart/Flutter project');
        return ExitCodes.ok;
      }
      ctx.console.write('Project : ${info.project!.rootPath}');
      if (!info.resolved) {
        ctx.console.info('no SDK resolved yet — run `flutterx use <version>`');
        return ExitCodes.ok;
      }
      final r = info.resolution!;
      ctx.console.write(
        'Flutter : ${r.chosen.version} (${r.chosen.channel.name}) '
        '— via ${r.resolvedBy.name}',
      );
      ctx.console.write('Dart    : ${r.chosen.dartVersion}');
      ctx.console.write(
        'Lock    : ${info.lockFresh! ? 'fresh' : 'stale — evidence changed; '
                  're-run `flutterx use` (or `resolve`, from Beta)'}',
      );
      return ExitCodes.ok;
    },
  ),
];
