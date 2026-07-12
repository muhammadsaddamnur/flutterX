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
    this.interactive = false,
    this.promptLine,
  });

  final FlutterXApi api;
  final Console console;
  final ArgResults args;
  final String workingDirectory;

  /// Whether stdin is a TTY — gates confirmation prompts (docs/04 §1.1).
  final bool interactive;

  /// Reads one line from the user; null in non-interactive contexts.
  final String? Function()? promptLine;
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

/// Human-readable sizes for `cache status` (docs/04 §3.10).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Shared handler for `resolve` (applies) and `recommend` (reports only)
/// — docs/04 §3.4. Low confidence prompts on a TTY and fails with exit 12
/// otherwise (docs/03 §5.2).
Future<int> runResolvePipeline(
  CommandContext ctx, {
  required bool apply,
}) async {
  var acceptLow = apply && ctx.args['accept-low'] as bool;
  final refresh = apply && ctx.args['refresh'] as bool;
  final matrix = !apply && ctx.args['matrix'] as bool;

  var result = await ctx.api.resolve.execute(
    ctx.workingDirectory,
    apply: apply,
    acceptLow: acceptLow,
    refresh: refresh,
    matrix: matrix,
  );

  // TTY consent path: ask once, then re-run accepting low confidence.
  if (result case Err(
    failure: LowConfidenceRefused(:final message),
  ) when ctx.interactive && !acceptLow && !ctx.console.json) {
    ctx.console.warn(message);
    ctx.console.write('Proceed anyway? [y/N]');
    if ((ctx.promptLine?.call() ?? '').trim().toLowerCase() == 'y') {
      acceptLow = true;
      result = await ctx.api.resolve.execute(
        ctx.workingDirectory,
        apply: apply,
        acceptLow: true,
        refresh: refresh,
      );
    }
  }

  switch (result) {
    case Err(:final failure):
      return fail(ctx.console, failure);
    case Ok(:final value):
      final chosen = value.recommendation.chosen.release;
      if (ctx.console.json) {
        ctx.console.emitJson(
          ok: true,
          data: {
            'flutter': '${chosen.version}',
            'dart': '${chosen.dartVersion}',
            'confidence': value.recommendation.confidence.name,
            'applied': value.resolution != null,
            'candidatesSolved': value.candidatesSolved,
            'candidatesAllowed': value.candidatesAllowed,
            'reasons': [
              for (final r in value.recommendation.chosen.contributions)
                {'text': r.text, 'delta': r.delta},
            ],
            'alternatives': [
              for (final alt in value.recommendation.alternatives)
                {'version': '${alt.release.version}', 'score': alt.score},
            ],
            'warnings': [for (final w in value.warnings) '$w'],
          },
        );
        return ExitCodes.ok;
      }

      for (final warning in value.warnings) {
        ctx.console.warn('$warning');
      }
      ctx.console.step(
        'solved ${value.candidatesSolved} candidate(s) → policy → '
        '${value.candidatesAllowed}',
      );
      ctx.console.success(
        '${apply ? 'Resolved' : 'Recommended'} Flutter ${chosen.version} '
        '(Dart ${chosen.dartVersion}) — confidence: '
        '${value.recommendation.confidence.name}',
      );
      if (value.recommendation.chosen.contributions.isNotEmpty &&
          !(ctx.args['explain'] as bool)) {
        ctx.console.info(
          'top reason: '
          '${value.recommendation.chosen.contributions.first.text} '
          '(run with --explain for the full trace)',
        );
      }
      if (ctx.args['explain'] as bool) {
        ctx.console.write('');
        ctx.console.write(value.explain());
      }
      if (!apply && value.recommendation.alternatives.isNotEmpty) {
        for (final alt in value.recommendation.alternatives) {
          ctx.console.step(
            'alternative: ${alt.release.version} (score ${alt.score})',
          );
        }
      }
      if (value.matrix case final m?) {
        ctx.console.write('');
        ctx.console.table([
          ['PACKAGE', for (final v in m.candidates) '$v'],
          for (final row in m.rows.entries)
            [
              row.key,
              for (final status in row.value)
                switch (status) {
                  PackageCompatibility.compatible => '✓',
                  PackageCompatibility.incompatible => '✗',
                  PackageCompatibility.unknown => '?',
                },
            ],
        ]);
      }
      if (apply) {
        ctx.console.info('lock written — commit .flutterx/resolution.lock');
      }
      return ExitCodes.ok;
  }
}

/// The command set (docs/04 §3). Later milestones append here.
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
    description:
        'Pin the current project to an SDK version '
        '(no argument: adopt an existing FVM/Puro/flutterx pin).',
    configure: (parser) => parser
      ..addOption('policy', help: 'Track a channel instead of an exact pin.')
      ..addFlag('no-install', negatable: false),
    run: (ctx) async {
      final rest = ctx.args.rest;
      if (rest.length > 1) {
        ctx.console.writeError('✗ usage: flutterx use [version]');
        return ExitCodes.usage;
      }
      final result = await ctx.api.use.execute(
        ctx.workingDirectory,
        rest.isEmpty ? null : rest.single,
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
    name: 'resolve',
    description: 'Run SDK Intelligence and pin the result.',
    configure: (parser) => parser
      ..addFlag('explain', negatable: false)
      ..addFlag('accept-low', negatable: false)
      ..addFlag('refresh', negatable: false),
    run: (ctx) => runResolvePipeline(ctx, apply: true),
  ),
  CommandSpec(
    name: 'recommend',
    description: 'Show the SDK recommendation without applying it.',
    configure: (parser) => parser
      ..addFlag('explain', negatable: false)
      ..addFlag('matrix', negatable: false),
    run: (ctx) => runResolvePipeline(ctx, apply: false),
  ),
  CommandSpec(
    name: 'doctor',
    description: 'Diagnose the environment (read-only).',
    configure: (parser) => parser
      ..addFlag('store', negatable: false)
      ..addFlag('project', negatable: false)
      ..addFlag('all', negatable: false)
      ..addFlag('path-fix', negatable: false),
    run: (ctx) async {
      // Section flags narrow the run; none (or --all) means everything.
      final onlyStore = ctx.args['store'] as bool;
      final onlyProject = ctx.args['project'] as bool;
      final all = ctx.args['all'] as bool || (!onlyStore && !onlyProject);
      final report = await ctx.api.doctor.execute(
        ctx.workingDirectory,
        store: all || onlyStore,
        project: all || onlyProject,
        platform: all,
      );

      if (ctx.args['path-fix'] as bool) {
        final pathProbe = report.sections
            .expand((s) => s.probes)
            .where((probe) => probe.kind == 'path' && !probe.ok)
            .firstOrNull;
        ctx.console.write(
          pathProbe?.detail?.split('Fix: ').last ??
              '# PATH already ok — nothing to fix',
        );
        return ExitCodes.ok;
      }

      if (ctx.console.json) {
        ctx.console.emitJson(
          ok: report.healthy,
          data: {
            'sections': [
              for (final section in report.sections)
                {
                  'name': section.name,
                  'probes': [
                    for (final probe in section.probes)
                      {
                        'kind': probe.kind,
                        'subject': probe.subject,
                        'ok': probe.ok,
                        'detail': ?probe.detail,
                        'severity': probe.severity.name,
                      },
                  ],
                },
            ],
            'warnings': report.warnings,
            'errors': report.errors,
          },
        );
        return report.healthy ? ExitCodes.ok : 15;
      }

      ctx.console.write('FlutterX — environment check');
      for (final section in report.sections) {
        ctx.console.write('');
        ctx.console.write(' ${section.name}');
        for (final probe in section.probes) {
          final label = probe.detail == null
              ? probe.subject
              : '${probe.subject} — ${probe.detail}';
          if (probe.ok) {
            ctx.console.write('  ✓ ${probe.kind}: $label');
          } else if (probe.severity == Severity.error) {
            ctx.console.write('  ✗ ${probe.kind}: $label');
          } else {
            ctx.console.write('  ⚠ ${probe.kind}: $label');
          }
        }
      }
      ctx.console.write('');
      ctx.console.write(
        '${report.warnings} warning(s), ${report.errors} error(s).',
      );
      return report.healthy ? ExitCodes.ok : 15;
    },
  ),
  CommandSpec(
    name: 'repair',
    description: 'Diagnose and fix store/project problems.',
    configure: (parser) => parser
      ..addFlag('yes', negatable: false)
      ..addFlag('force', negatable: false)
      ..addFlag('dry-run', negatable: false)
      ..addOption('only', help: 'Comma-separated diagnosis ids (FX-R03,…).'),
    run: (ctx) async {
      final diagnoses = await ctx.api.repair.plan(ctx.workingDirectory);
      if (diagnoses.isEmpty) {
        ctx.console.json
            ? ctx.console.emitJson(ok: true, data: {'issues': 0})
            : ctx.console.success('no issues found');
        return ExitCodes.ok;
      }

      if (!ctx.console.json) {
        ctx.console.write('Found ${diagnoses.length} issue(s):');
        for (final diagnosis in diagnoses) {
          ctx.console.write(
            '  [${diagnosis.id}] ${diagnosis.summary}'
            ' → ${diagnosis.plan.steps.map((s) => s.description).join('; ')}',
          );
        }
      }
      if (ctx.args['dry-run'] as bool) {
        if (ctx.console.json) {
          ctx.console.emitJson(
            ok: true,
            data: {
              'issues': [
                for (final d in diagnoses) {'id': d.id, 'summary': d.summary},
              ],
              'dryRun': true,
            },
          );
        }
        return ExitCodes.ok;
      }

      final yes = ctx.args['yes'] as bool;
      if (!yes) {
        if (!ctx.interactive) {
          ctx.console.writeError(
            '✗ refusing to fix without consent — pass --yes '
            '(or --dry-run to only look)',
          );
          return ExitCodes.usage;
        }
        ctx.console.write('Apply ${diagnoses.length} fix(es)? [Y/n]');
        final answer = (ctx.promptLine?.call() ?? 'n').trim().toLowerCase();
        if (answer == 'n' || answer == 'no') {
          ctx.console.info('nothing changed');
          return ExitCodes.ok;
        }
      }

      final only = (ctx.args['only'] as String?)
          ?.split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();
      final report = await ctx.api.repair.execute(
        diagnoses,
        only: only,
        // Destructive fixes need --force even under --yes (docs/03 §9.2).
        allowDestructive: ctx.args['force'] as bool,
        allowReResolve: yes || ctx.interactive,
      );

      if (ctx.console.json) {
        ctx.console.emitJson(
          ok: report.clean,
          data: {
            'fixed': report.fixed,
            'skipped': report.skipped,
            'failed': report.failed,
          },
        );
        return report.clean ? ExitCodes.ok : 15;
      }
      for (final line in report.fixed) {
        ctx.console.success(line);
      }
      for (final line in report.skipped) {
        ctx.console.warn('skipped $line');
      }
      for (final line in report.failed) {
        ctx.console.writeError('✗ $line');
      }
      if (report.clean) {
        ctx.console.info('re-run `flutterx doctor` anytime');
        return ExitCodes.ok;
      }
      return 15;
    },
  ),
  CommandSpec(
    name: 'cache',
    description: 'Inspect or refresh the shared store.',
    configure: (parser) => parser..addFlag('registry-only', negatable: false),
    run: (ctx) async {
      final sub = ctx.args.rest.isEmpty ? 'status' : ctx.args.rest.first;
      switch (sub) {
        case 'status':
          final status = await ctx.api.cache.status();
          if (ctx.console.json) {
            ctx.console.emitJson(
              ok: true,
              data: {
                'bareRepoBytes': status.bareRepoBytes,
                'versionBytes': status.versionBytes,
                'artifactCount': status.artifactCount,
                'artifactBytes': status.artifactBytes,
                'downloadsBytes': status.downloadsBytes,
                'totalBytes': status.totalBytes,
                'uncommittedJournalEntries': status.uncommittedJournalEntries,
              },
            );
            return ExitCodes.ok;
          }
          ctx.console.table([
            ['Shared git objects', formatBytes(status.bareRepoBytes)],
            for (final entry in status.versionBytes.entries)
              ['version ${entry.key}', formatBytes(entry.value)],
            [
              'artifacts (${status.artifactCount})',
              formatBytes(status.artifactBytes),
            ],
            ['downloads', formatBytes(status.downloadsBytes)],
            ['total', formatBytes(status.totalBytes)],
          ]);
          if (status.uncommittedJournalEntries > 0) {
            ctx.console.warn(
              '${status.uncommittedJournalEntries} interrupted operation(s)'
              ' — see `flutterx doctor`',
            );
          }
          return ExitCodes.ok;
        case 'refresh':
          final result = await ctx.api.cache.refresh(
            registryOnly: ctx.args['registry-only'] as bool,
          );
          switch (result) {
            case Err(:final failure):
              return fail(ctx.console, failure);
            case Ok(:final value):
              if (ctx.console.json) {
                ctx.console.emitJson(
                  ok: true,
                  data: {'releases': value.releases.length},
                );
              } else {
                ctx.console.success(
                  'registry refreshed — ${value.releases.length} releases '
                  'known',
                );
              }
              return ExitCodes.ok;
          }
        default:
          ctx.console.writeError(
            '✗ usage: flutterx cache <status|refresh> '
            '(gc and verify land with M2.8)',
          );
          return ExitCodes.usage;
      }
    },
  ),
  CommandSpec(
    name: 'config',
    description: 'Read or write global configuration.',
    configure: (_) {},
    run: (ctx) async {
      final rest = ctx.args.rest;
      final action = rest.isEmpty ? 'list' : rest.first;
      switch ((action, rest.length)) {
        case ('list', 1) || ('list', 0):
          final entries = await ctx.api.config.list();
          if (ctx.console.json) {
            ctx.console.emitJson(ok: true, data: entries);
          } else if (entries.isEmpty) {
            ctx.console.info('no config set');
          } else {
            ctx.console.table([
              for (final entry in entries.entries) [entry.key, entry.value],
            ]);
          }
          return ExitCodes.ok;
        case ('get', 2):
          final value = await ctx.api.config.get(rest[1]);
          if (ctx.console.json) {
            ctx.console.emitJson(ok: true, data: {rest[1]: value});
          } else {
            ctx.console.write(value ?? '(unset)');
          }
          return ExitCodes.ok;
        case ('set', 3):
          final result = await ctx.api.config.set(rest[1], rest[2]);
          if (result case Err(:final failure)) {
            return fail(ctx.console, failure);
          }
          ctx.console.success('${rest[1]} = ${rest[2]}');
          return ExitCodes.ok;
        case ('unset', 2):
          await ctx.api.config.unset(rest[1]);
          ctx.console.success('${rest[1]} unset');
          return ExitCodes.ok;
        default:
          ctx.console.writeError(
            '✗ usage: flutterx config [list | get <key> | set <key> <value> '
            '| unset <key>]',
          );
          return ExitCodes.usage;
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
      for (final warning in info.warnings) {
        ctx.console.warn('$warning');
      }
      if (!info.resolved) {
        if (info.migratedPin != null) {
          ctx.console.info(
            'pin found in ${info.migratedPin!.origin}: '
            '${info.migratedPin!.version} — run `flutterx use` to adopt it',
          );
        } else {
          ctx.console.info(
            'no SDK resolved yet — run `flutterx use <version>`',
          );
        }
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
