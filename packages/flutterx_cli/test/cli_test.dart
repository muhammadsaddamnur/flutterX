import 'dart:convert';

import 'package:flutterx_application/flutterx_application.dart';
import 'package:flutterx_cli/flutterx_cli.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

// ── In-memory fakes of the domain ports (docs/06 §10) ────────────────────

FlutterRelease release(
  String version, {
  String dart = '3.4.3',
  Channel channel = Channel.stable,
  bool retracted = false,
}) => FlutterRelease(
  version: SemVer.parse(version),
  channel: channel,
  gitTag: version,
  frameworkSha: 'sha-$version',
  dartVersion: SemVer.parse(dart),
  releasedAt: DateTime.utc(2026, 1, 1),
  artifacts: const {},
  retracted: retracted,
);

final class FakeSdkRepository implements SdkRepository {
  final store = <String, InstalledSdk>{};
  final refs = <String, List<String>>{};
  FxFailure? failWith;

  @override
  Future<Result<InstalledSdk>> ensureInstalled(
    FlutterRelease release, {
    InstallOptions options = const InstallOptions(),
    ProgressReporter onProgress = noProgress,
  }) async {
    if (failWith != null) return Result.err(failWith!);
    final sdk = InstalledSdk(
      release: release,
      path: '/store/versions/${release.version}',
    );
    store['${release.version}'] = sdk;
    return Result.ok(sdk);
  }

  @override
  Future<Result<void>> remove(SemVer version, {bool force = false}) async {
    final holders = refs['$version'] ?? const [];
    if (holders.isNotEmpty && !force) {
      return Result.err(
        ResourceInUse(
          message: '${holders.length} project(s) still pinned to $version',
          referencedBy: holders,
        ),
      );
    }
    store.remove('$version');
    return const Result.ok(null);
  }

  @override
  Future<List<InstalledSdk>> installed() async => store.values.toList();

  @override
  Future<Map<String, List<String>>> references() async => refs;
}

final class FakeRegistry implements RegistryPort {
  FakeRegistry(this.releases);
  final List<FlutterRelease> releases;
  bool offline = false;

  @override
  Future<Result<RegistrySnapshot>> snapshot({bool refresh = false}) async {
    if (offline) {
      return const Result.err(
        NetworkFailure(code: 'FX-REG-001', message: 'offline'),
      );
    }
    return Result.ok(
      RegistrySnapshot(
        releases: releases,
        fetchedAt: DateTime.utc(2026, 7, 11),
        source: 'fake',
      ),
    );
  }

  /// name@version → meta; misses answer FX-REG-002 (→ unverified).
  final metas = <String, PackageMeta>{};

  @override
  Future<Result<PackageMeta>> packageMeta(String name, SemVer version) async {
    final meta = metas['$name@$version'];
    return meta == null
        ? const Result.err(
            NetworkFailure(code: 'FX-REG-002', message: 'no meta'),
          )
        : Result.ok(meta);
  }
}

final class FakeProjectStore implements ProjectStore {
  Project? project;
  Resolution? lock;
  String? pinnedVersion;
  EvidenceFiles evidence = EvidenceFiles(files: const {});

  @override
  Future<Project?> findProject(String startDir) async => project;

  @override
  Future<Result<void>> writePin(
    Project project, {
    String? pinVersion,
    String? policyChannel,
  }) async {
    pinnedVersion = pinVersion ?? 'policy:$policyChannel';
    return const Result.ok(null);
  }

  @override
  Future<EvidenceFiles> readEvidence(Project project) async => evidence;

  @override
  Future<Resolution?> readLock(Project project) async => lock;

  @override
  Future<Result<void>> writeLock(Project project, Resolution resolution) async {
    lock = resolution;
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> linkSdk(Project project, InstalledSdk sdk) async =>
      const Result.ok(null);

  String? sdkPath;

  @override
  Future<String?> resolvedSdkPath(Project project) async => sdkPath;

  /// pubspec constraints "on disk" for bumpDependencies (name → constraint).
  final pubspecDeps = <String, String>{};

  @override
  Future<Result<List<String>>> bumpDependencies(
    Project project,
    Map<String, SemVer> bumps,
  ) async {
    final changed = <String>[];
    for (final bump in bumps.entries) {
      if (pubspecDeps.containsKey(bump.key)) {
        pubspecDeps[bump.key] = '^${bump.value}';
        changed.add(bump.key);
      }
    }
    return Result.ok(changed);
  }
}

final class FakeSim implements DependencySimPort {
  PubSimOutcome outcome = PubSimOutcome(unaffectedCount: 34);
  InstalledSdk? lastTarget;

  @override
  Future<Result<PubSimOutcome>> simulate({
    required Project project,
    required InstalledSdk targetSdk,
  }) async {
    lastTarget = targetSdk;
    return Result.ok(outcome);
  }
}

final class FakePlatform implements PlatformPort {
  final execCalls = <(String, List<String>, Map<String, String>?)>[];
  int exitCodeToReturn = 0;

  @override
  String get storeHome => '/store';

  @override
  TargetOs get os => TargetOs.macos;

  @override
  LinkMode get linkMode => LinkMode.symlink;

  @override
  Future<int> exec(
    String executable,
    List<String> args, {
    bool inheritStdio = true,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    execCalls.add((executable, args, environment));
    return exitCodeToReturn;
  }

  @override
  Future<Result<void>> createLink({
    required String targetPath,
    required String linkPath,
  }) async => const Result.ok(null);
}

final class FakeHealth implements StoreHealthPort, PlatformHealthPort {
  var storeProbes = <Probe>[
    const Probe(kind: 'store-state', subject: 'state.json', ok: true),
  ];
  var platformProbes = <Probe>[
    const Probe(kind: 'git', subject: '2.51', ok: true),
  ];
  var projectProbes = <Probe>[
    const Probe(kind: 'project-lock', subject: 'lock', ok: true),
  ];

  @override
  Future<List<Probe>> probeStore() async => storeProbes;

  @override
  Future<List<Probe>> probeProject(Project project) async => projectProbes;

  @override
  Future<List<Probe>> probePlatform() async => platformProbes;
}

final class FakeCacheOps implements CacheOps {
  @override
  Future<CacheStatus> status() async => CacheStatus(
    bareRepoBytes: 1024 * 1024 * 1900,
    versionBytes: const {'3.22.2': 214 * 1024 * 1024},
    artifactCount: 3,
    artifactBytes: 305 * 1024 * 1024,
    downloadsBytes: 0,
    uncommittedJournalEntries: 0,
  );

  @override
  Future<Result<void>> refreshGitObjects({
    ProgressReporter onProgress = noProgress,
  }) async => const Result.ok(null);

  GcOptions? lastGcOptions;
  var gcReport = GcReport(
    versionBytes: const {'3.24.1': 231 * 1024 * 1024},
    artifactsRemoved: 2,
    artifactBytes: 305 * 1024 * 1024,
    downloadBytes: 76 * 1024 * 1024,
    dryRun: true,
  );

  @override
  Future<Result<GcReport>> gc(
    GcOptions options, {
    ProgressReporter onProgress = noProgress,
  }) async {
    lastGcOptions = options;
    return Result.ok(
      GcReport(
        versionBytes: gcReport.versionBytes,
        artifactsRemoved: gcReport.artifactsRemoved,
        artifactBytes: gcReport.artifactBytes,
        downloadBytes: gcReport.downloadBytes,
        adoptedArtifacts: gcReport.adoptedArtifacts,
        dryRun: options.dryRun,
      ),
    );
  }

  @override
  Future<CacheVerifyReport> verify({
    ProgressReporter onProgress = noProgress,
  }) async => CacheVerifyReport(checkedArtifacts: 3, gitHealthy: true);
}

final class FakeConfig implements ConfigPort {
  final entries = <String, String>{};

  @override
  Future<String?> get(String key) async => entries[key];

  @override
  Future<Result<void>> set(String key, String value) async {
    if (key.contains(' ')) {
      return const Result.err(
        StorageFailure(code: 'FX-CONF-001', message: 'invalid key'),
      );
    }
    entries[key] = value;
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> unset(String key) async {
    entries.remove(key);
    return const Result.ok(null);
  }

  @override
  Future<Map<String, String>> list() async => Map.of(entries);
}

// ── Harness ──────────────────────────────────────────────────────────────

final class Harness {
  Harness({List<FlutterRelease>? releases})
    : sdks = FakeSdkRepository(),
      registry = FakeRegistry(
        releases ?? [release('3.24.1', dart: '3.5.1'), release('3.22.2')],
      ),
      projects = FakeProjectStore();

  final FakeSdkRepository sdks;
  final FakeRegistry registry;
  final FakeProjectStore projects;
  final health = FakeHealth();
  final config = FakeConfig();
  final cacheOps = FakeCacheOps();
  final platform = FakePlatform();
  final sim = FakeSim();
  final out = <String>[];
  final err = <String>[];
  var interactive = false;
  final promptAnswers = <String>[];

  /// Raw progress sink; events render as plain phase lines only when
  /// [withProgress] is set (mirrors piped-stderr output).
  final progressRaw = <String>[];
  var withProgress = false;

  FlutterXCli cli() => FlutterXCli(
    api: FlutterXApi(
      sdkRepository: sdks,
      registry: registry,
      projectStore: projects,
      storeHealth: health,
      platformHealth: health,
      cacheOps: cacheOps,
      config: config,
      platform: platform,
      dependencySim: sim,
      clock: () => DateTime.utc(2026, 7, 11),
    ),
    out: out.add,
    err: err.add,
    workingDirectory: '/work/app',
    environment: const {'SHELL': '/bin/zsh', 'PATH': '/usr/bin:/bin'},
    interactive: interactive,
    promptLine: () => promptAnswers.isEmpty ? null : promptAnswers.removeAt(0),
    errRaw: withProgress ? progressRaw.add : null,
  );

  Future<int> run(List<String> args) => cli().run([...args, '--no-color']);

  /// Raw proxy commands must receive argv verbatim — no injected flags.
  Future<int> runRaw(List<String> args) => cli().run(args);
}

void main() {
  group('install', () {
    test('installs an exact version', () async {
      final h = Harness();
      expect(await h.run(['install', '3.22.2']), 0);
      expect(h.out.single, contains('Flutter 3.22.2 (Dart 3.4.3) installed'));
    });

    test('resolves channel specifiers to the newest release', () async {
      final h = Harness();
      expect(await h.run(['install', 'stable']), 0);
      expect(h.sdks.store.keys, contains('3.24.1'));
    });

    test('unknown version → exit 14 with suggestions', () async {
      final h = Harness();
      expect(await h.run(['install', '3.22.9']), 14);
      expect(h.err.first, contains('FX-SOLVE-001'));
      expect(h.err.join('\n'), contains('did you mean: 3.22.2'));
    });

    test('offline registry → exit 10', () async {
      final h = Harness()..registry.offline = true;
      expect(await h.run(['install', '3.22.2']), 10);
      expect(h.err.first, contains('FX-REG-001'));
    });

    test('--json emits the versioned envelope', () async {
      final h = Harness();
      expect(await h.run(['install', '3.22.2', '--json']), 0);
      final envelope = jsonDecode(h.out.single) as Map<String, Object?>;
      expect(envelope['apiVersion'], 1);
      expect(envelope['ok'], isTrue);
      expect((envelope['data']! as Map)['version'], '3.22.2');
    });

    test('--json error envelope carries code and next actions', () async {
      final h = Harness()..registry.offline = true;
      expect(await h.run(['install', '3.22.2', '--json']), 10);
      final envelope = jsonDecode(h.out.single) as Map<String, Object?>;
      expect(envelope['ok'], isFalse);
      expect((envelope['error']! as Map)['code'], 'FX-REG-001');
    });
  });

  group('remove', () {
    test('removes an installed version', () async {
      final h = Harness();
      await h.run(['install', '3.22.2']);
      h.out.clear();
      expect(await h.run(['remove', '3.22.2']), 0);
      expect(h.sdks.store, isEmpty);
    });

    test('still-referenced version → exit 17 listing holders', () async {
      final h = Harness();
      await h.run(['install', '3.22.2']);
      h.sdks.refs['3.22.2'] = ['/work/app-legacy'];
      expect(await h.run(['remove', '3.22.2']), 17);
      expect(h.err.join('\n'), contains('/work/app-legacy'));
    });

    test('not installed → exit 14', () async {
      final h = Harness();
      expect(await h.run(['remove', '3.19.6']), 14);
    });
  });

  group('list', () {
    test('empty store prints a hint', () async {
      final h = Harness();
      expect(await h.run(['list']), 0);
      expect(h.out.single, contains('no SDKs installed'));
    });

    test('installed table includes USED BY', () async {
      final h = Harness();
      await h.run(['install', '3.22.2']);
      h.sdks.refs['3.22.2'] = ['/work/shop-app'];
      h.out.clear();
      expect(await h.run(['list']), 0);
      expect(h.out.first, contains('VERSION'));
      expect(h.out.join('\n'), contains('shop-app'));
    });

    test('--remote filters releases', () async {
      final h = Harness();
      expect(await h.run(['list', '--remote', '3.22']), 0);
      final body = h.out.join('\n');
      expect(body, contains('3.22.2'));
      expect(body, isNot(contains('3.24.1')));
    });
  });

  group('use', () {
    test('pins, locks, and reports', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      expect(await h.run(['use', '3.22.2']), 0);
      expect(h.projects.pinnedVersion, '3.22.2');
      expect(h.projects.lock!.resolvedBy, ResolvedBy.use);
      expect(h.out.join('\n'), contains('pinned to Flutter 3.22.2'));
    });

    test('outside a project → exit 15 with guidance', () async {
      final h = Harness();
      expect(await h.run(['use', '3.22.2']), 15);
      expect(h.err.first, contains('FX-STORE-005'));
    });

    test('bare `use` adopts an FVM pin (migration, T1.10.2)', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      h.projects.evidence = EvidenceFiles(
        files: const {'.fvmrc': '{"flutter": "3.22.2"}'},
      );
      expect(await h.run(['use']), 0);
      expect(h.projects.pinnedVersion, '3.22.2');
      expect(h.projects.lock!.resolvedBy, ResolvedBy.migrate);
      expect(
        h.projects.lock!.reasons.first.text,
        contains('pin adopted from .fvmrc'),
      );
    });

    test('bare `use` without any pin → FX-STORE-009', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      expect(await h.run(['use']), 15);
      expect(h.err.first, contains('FX-STORE-009'));
    });
  });

  group('current', () {
    test('outside a project', () async {
      final h = Harness();
      expect(await h.run(['current']), 0);
      expect(h.out.single, contains('not inside a Dart/Flutter project'));
    });

    test('resolved project reports version and lock freshness', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      await h.run(['use', '3.22.2']);
      h.out.clear();
      expect(await h.run(['current']), 0);
      final body = h.out.join('\n');
      expect(body, contains('Flutter : 3.22.2 (stable) — via use'));
      expect(body, contains('Lock    : fresh'));
    });

    test('unresolved project with an FVM pin advertises adoption', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      h.projects.evidence = EvidenceFiles(
        files: const {'.fvmrc': '{"flutter": "3.22.2"}'},
      );
      expect(await h.run(['current']), 0);
      expect(
        h.out.join('\n'),
        contains('pin found in .fvmrc: 3.22.2 — run `flutterx use`'),
      );
    });

    test('conflicting pins are always warned (docs/03 §2.3)', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      h.projects.evidence = EvidenceFiles(
        files: const {
          'flutterx.yaml': 'flutter: 3.24.1',
          '.fvmrc': '{"flutter": "3.19.0"}',
        },
      );
      expect(await h.run(['current']), 0);
      final body = h.out.join('\n');
      expect(body, contains('conflicting-pins'));
      expect(body, contains('pin found in flutterx.yaml: 3.24.1'));
    });

    test('evidence drift flips the lock to stale', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      await h.run(['use', '3.22.2']);
      h.projects.evidence = EvidenceFiles(
        files: const {'pubspec.yaml': 'changed!'},
      );
      h.out.clear();
      expect(await h.run(['current']), 0);
      expect(h.out.join('\n'), contains('stale'));
    });
  });

  group('resolve / recommend (docs/04 §3.4 — the flagship flow)', () {
    // Real evidence in, real pipeline through scanner→solver→rules→rank.
    Harness projectWith(Map<String, String> files) {
      final h = Harness(
        releases: [
          release('3.24.1', dart: '3.5.1'),
          release('3.22.2'),
          release('3.22.1', dart: '3.4.1'),
        ],
      );
      h.projects.project = const Project(rootPath: '/work/app');
      h.projects.evidence = EvidenceFiles(files: files);
      return h;
    }

    const pubspec = 'name: app\nenvironment:\n  sdk: ">=3.4.0 <3.5.0"\n';

    test('resolves from hard evidence, applies, writes the lock', () async {
      final h = projectWith(const {'pubspec.yaml': pubspec});
      expect(await h.run(['resolve']), 0);
      final body = h.out.join('\n');
      expect(body, contains('solved 2 candidate(s) → policy → 2'));
      expect(
        body,
        contains('Resolved Flutter 3.22.2 (Dart 3.4.3) — confidence:'),
      );
      expect(h.projects.lock!.resolvedBy, ResolvedBy.resolve);
      expect(h.sdks.store.keys, contains('3.22.2'), reason: 'provisioned');
    });

    test('recommend reports without applying', () async {
      final h = projectWith(const {'pubspec.yaml': pubspec});
      expect(await h.run(['recommend']), 0);
      expect(h.projects.lock, isNull);
      expect(h.sdks.store, isEmpty);
      expect(h.out.join('\n'), contains('Recommended Flutter 3.22.2'));
    });

    test('--explain prints the score breakdown', () async {
      final h = projectWith(const {'pubspec.yaml': pubspec});
      expect(await h.run(['resolve', '--explain']), 0);
      final body = h.out.join('\n');
      expect(body, contains('latest patch of its minor'));
      expect(body, contains('total'));
    });

    test('conflicting constraints → exit 11 with the minimal pair', () async {
      final h = projectWith(const {
        'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ">=3.9.0"\n',
      });
      expect(await h.run(['resolve']), 11);
      expect(h.err.first, contains('FX-SOLVE-002'));
      expect(h.err.join('\n'), contains('cache refresh'));
    });

    test('soft evidence only → exit 12 when non-interactive', () async {
      final h = projectWith(const {'.metadata': 'project_type: app\n'});
      expect(await h.run(['resolve']), 12);
      expect(h.err.first, contains('FX-RESOLVE-001'));
    });

    test('--accept-low overrides the gate in CI', () async {
      final h = projectWith(const {'.metadata': 'project_type: app\n'});
      expect(await h.run(['resolve', '--accept-low']), 0);
      expect(h.projects.lock, isNotNull);
    });

    test('a TTY prompt accepting low confidence proceeds', () async {
      final h = projectWith(const {'.metadata': 'project_type: app\n'});
      h.interactive = true;
      h.promptAnswers.add('y');
      expect(await h.run(['resolve']), 0);
      expect(h.out.join('\n'), contains('Proceed anyway?'));
      expect(h.projects.lock, isNotNull);
    });

    test('lockfile compatibility feeds the score; --matrix renders the grid '
        '(M2.6)', () async {
      const lockfile = '''
packages:
  freezed:
    dependency: "direct main"
    description:
      name: freezed
      url: "https://pub.dev"
    source: hosted
    version: "2.4.7"
sdks:
  dart: ">=3.3.0 <4.0.0"
''';
      final h = projectWith(const {
        'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ">=3.3.0 <4.0.0"\n',
        'pubspec.lock': lockfile,
      });
      // freezed needs Dart <3.5 → incompatible with 3.24.1 (Dart 3.5.1).
      h.registry.metas['freezed@2.4.7'] = PackageMeta(
        name: 'freezed',
        version: SemVer.parse('2.4.7'),
        dartConstraint: VersionConstraintX.parse('>=3.0.0 <3.5.0'),
      );

      expect(await h.run(['recommend', '--matrix']), 0);
      final body = h.out.join('\n');
      expect(
        body,
        contains('Recommended Flutter 3.22.2'),
        reason: 'compatibility (+40) pulls the older-but-compatible ahead',
      );
      expect(body, contains('PACKAGE'));
      expect(body, contains('freezed'));
      expect(body, contains('✓'));
      expect(body, contains('✗'));
    });

    test('an existing pin decides with high confidence', () async {
      final h = projectWith(const {
        'pubspec.yaml': pubspec,
        '.fvmrc': '{"flutter": "3.24.1"}',
      });
      expect(await h.run(['resolve']), 0);
      expect(h.projects.lock!.chosen.version, SemVer.parse('3.24.1'));
      expect(h.out.join('\n'), contains('confidence: high'));
    });
  });

  group('doctor', () {
    test('healthy environment → sections rendered, exit 0', () async {
      final h = Harness();
      expect(await h.run(['doctor']), 0);
      final body = h.out.join('\n');
      expect(body, contains(' Store'));
      expect(body, contains(' Platform'));
      expect(body, contains('0 warning(s), 0 error(s).'));
    });

    test('warnings keep exit 0; errors make it 15 (docs/04 §3.7)', () async {
      final h = Harness();
      h.health.storeProbes = [
        const Probe(
          kind: 'orphan-version',
          subject: '3.24.1',
          ok: false,
          detail: 'no project references it',
        ),
      ];
      expect(await h.run(['doctor']), 0);
      expect(h.out.join('\n'), contains('1 warning(s), 0 error(s).'));

      h.health.storeProbes = [
        const Probe(
          kind: 'bare-repo',
          subject: 'repo',
          ok: false,
          detail: 'fsck errors',
          severity: Severity.error,
        ),
      ];
      h.out.clear();
      expect(await h.run(['doctor']), 15);
    });

    test('--path-fix prints only the snippet', () async {
      final h = Harness();
      h.health.platformProbes = [
        const Probe(
          kind: 'path',
          subject: '/store/bin',
          ok: false,
          detail:
              'not on PATH — shims inactive. Fix: '
              'export PATH="/store/bin:\$PATH"',
        ),
      ];
      expect(await h.run(['doctor', '--path-fix']), 0);
      expect(h.out.single, 'export PATH="/store/bin:\$PATH"');
    });
  });

  group('repair (docs/04 §3.8)', () {
    test('healthy environment → no issues, exit 0', () async {
      final h = Harness();
      expect(await h.run(['repair']), 0);
      expect(h.out.single, contains('no issues found'));
    });

    test('--dry-run lists the plan without fixing', () async {
      final h = Harness();
      h.health.storeProbes = [
        const Probe(kind: 'worktree', subject: '3.22.2', ok: false),
      ];
      expect(await h.run(['repair', '--dry-run']), 0);
      expect(h.out.join('\n'), contains('[FX-R03] corrupt worktree 3.22.2'));
      expect(h.sdks.store, isEmpty, reason: 'nothing executed');
    });

    test('non-interactive without --yes refuses politely', () async {
      final h = Harness();
      h.health.storeProbes = [
        const Probe(kind: 'worktree', subject: '3.22.2', ok: false),
      ];
      expect(await h.run(['repair']), 2);
      expect(h.err.first, contains('--yes'));
    });

    test('--yes recreates a corrupt worktree (FX-R03)', () async {
      final h = Harness();
      h.health.storeProbes = [
        const Probe(kind: 'worktree', subject: '3.22.2', ok: false),
      ];
      expect(await h.run(['repair', '--yes']), 0);
      expect(h.out.join('\n'), contains('FX-R03: worktree recreated'));
      expect(h.sdks.store.keys, contains('3.22.2'), reason: 're-provisioned');
    });

    test('FX-R01 re-links from the lock', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      await h.run(['use', '3.22.2']);
      h.out.clear();
      h.health.projectProbes = [
        const Probe(
          kind: 'project-link',
          subject: '/work/app/.flutterx/sdk',
          ok: false,
        ),
      ];
      expect(await h.run(['repair', '--yes']), 0);
      expect(h.out.join('\n'), contains('FX-R01: re-linked to 3.22.2'));
    });

    test('--only filters diagnoses', () async {
      final h = Harness();
      h.health.storeProbes = [
        const Probe(kind: 'worktree', subject: '3.22.2', ok: false),
        const Probe(kind: 'artifacts', subject: '3.24.1', ok: false),
      ];
      expect(await h.run(['repair', '--yes', '--only', 'FX-R05']), 0);
      final body = h.out.join('\n');
      expect(body, contains('skipped FX-R03'));
      expect(body, contains('FX-R05: artifacts re-downloaded'));
    });

    test('a failing fix reports and exits 15', () async {
      final h = Harness();
      h.registry.offline = true;
      h.health.storeProbes = [
        const Probe(kind: 'worktree', subject: '3.22.2', ok: false),
      ];
      expect(await h.run(['repair', '--yes']), 15);
      expect(h.err.join('\n'), contains('FX-R03'));
    });
  });

  group('upgrade', () {
    /// A project resolved to 3.22.2 — 3.24.1 is the newest stable above it.
    Future<Harness> resolvedAt3222() async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      await h.run(['use', '3.22.2']);
      h.out.clear();
      h.err.clear();
      return h;
    }

    test('unresolved project → FX-STORE-008', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      expect(await h.run(['upgrade', '--advise']), 15);
      expect(h.err.join('\n'), contains('FX-STORE-008'));
    });

    test('already on the newest stable → exit 0, nothing simulated', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      await h.run(['use', '3.24.1']);
      h.out.clear();
      expect(await h.run(['upgrade', '--advise']), 0);
      expect(h.out.single, contains('already the newest'));
      expect(h.sim.lastTarget, isNull);
    });

    test(
      '--advise renders the docs/03 §8.2 report and applies nothing',
      () async {
        final h = await resolvedAt3222();
        h.sim.outcome = PubSimOutcome(
          unaffectedCount: 34,
          needsBump: [
            PackageImpact(
              name: 'freezed',
              currentVersion: SemVer.parse('2.4.7'),
              suggestedVersion: SemVer.parse('2.5.2'),
            ),
          ],
        );
        expect(await h.run(['upgrade', '--advise']), 0);
        final body = h.out.join('\n');
        expect(
          body,
          contains('Upgrade plan: 3.22.2 → 3.24.1 (minor, Dart 3.4.3 → 3.5.1)'),
        );
        expect(body, contains('34 packages unaffected'));
        expect(body, contains('freezed'));
        expect(body, contains('2.4.7 → 2.5.2'));
        expect(body, contains('Swift Package Manager'), reason: 'KB note');
        expect(body, contains('Verdict: SAFE WITH CHANGES.'));
        expect(body, contains('flutterx upgrade --to 3.24.1 --bump-deps'));
        expect(h.sim.lastTarget?.release.version, SemVer.parse('3.24.1'));
        expect(h.projects.pinnedVersion, '3.22.2', reason: 'advise-only');
      },
    );

    test('blocking package → BLOCKED, exit 16', () async {
      final h = await resolvedAt3222();
      h.sim.outcome = PubSimOutcome(
        resolvable: false,
        blocking: [
          PackageImpact(
            name: 'legacy_pkg',
            currentVersion: SemVer.parse('1.0.0'),
            note: 'version solving failed',
          ),
        ],
      );
      expect(await h.run(['upgrade', '--advise']), 16);
      final body = h.out.join('\n');
      expect(body, contains('Verdict: BLOCKED.'));
      expect(body, contains('remediation: review legacy_pkg'));
      expect(h.err.join('\n'), contains('legacy_pkg'));
    });

    test('--yes applies: pin + lock + bump + pub get on the new SDK', () async {
      final h = await resolvedAt3222();
      h.projects.pubspecDeps['freezed'] = '^2.4.0';
      h.sim.outcome = PubSimOutcome(
        unaffectedCount: 34,
        needsBump: [
          PackageImpact(
            name: 'freezed',
            currentVersion: SemVer.parse('2.4.7'),
            suggestedVersion: SemVer.parse('2.5.2'),
          ),
        ],
      );
      expect(await h.run(['upgrade', '--yes', '--bump-deps']), 0);
      final body = h.out.join('\n');
      expect(body, contains('upgraded to Flutter 3.24.1 — lock written'));
      expect(body, contains('pubspec.yaml bumped: freezed'));
      expect(body, contains('post-upgrade checklist'));
      expect(h.projects.pinnedVersion, '3.24.1');
      expect(h.projects.lock?.chosen.version, SemVer.parse('3.24.1'));
      expect(h.projects.lock?.resolvedBy, ResolvedBy.use);
      expect(h.projects.pubspecDeps['freezed'], '^2.5.2');
      final (exe, args, env) = h.platform.execCalls.single;
      expect(exe, '/store/versions/3.24.1/bin/dart');
      expect(args, ['pub', 'get']);
      expect(env?['FLUTTER_ROOT'], '/store/versions/3.24.1');
    });

    test('non-interactive without --yes refuses with exit 2', () async {
      final h = await resolvedAt3222();
      expect(await h.run(['upgrade']), 2);
      expect(h.err.join('\n'), contains('--yes'));
      expect(h.projects.pinnedVersion, '3.22.2', reason: 'unchanged');
    });

    test('interactive "n" at the confirm prompt changes nothing', () async {
      final h = await resolvedAt3222();
      h.interactive = true;
      h.promptAnswers.add('n');
      expect(await h.run(['upgrade']), 0);
      expect(h.out.join('\n'), contains('nothing changed'));
      expect(h.projects.pinnedVersion, '3.22.2', reason: 'unchanged');
    });

    test('--to below current warns DOWNGRADE', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      await h.run(['use', '3.24.1']);
      h.out.clear();
      expect(await h.run(['upgrade', '--advise', '--to', '3.22.2']), 0);
      expect(h.out.join('\n'), contains('DOWNGRADE'));
    });

    test('--to violating a hard constraint → conflict, exit 11', () async {
      final h = await resolvedAt3222();
      h.projects.evidence = EvidenceFiles(
        files: const {
          'pubspec.yaml': 'environment:\n  sdk: ">=3.0.0 <3.5.0"\n',
        },
      );
      expect(await h.run(['upgrade', '--advise', '--to', '3.24.1']), 11);
      expect(h.err.join('\n'), contains('violates'));
    });

    test('--to unknown version → exit 14', () async {
      final h = await resolvedAt3222();
      expect(await h.run(['upgrade', '--advise', '--to', '9.9.9']), 14);
    });

    test('--json emits the machine report', () async {
      final h = await resolvedAt3222();
      expect(await h.run(['upgrade', '--advise', '--json']), 0);
      final json = jsonDecode(h.out.single) as Map<String, dynamic>;
      expect(json['ok'], isTrue);
      final data = json['data'] as Map<String, dynamic>;
      expect(data['from'], '3.22.2');
      expect(data['to'], '3.24.1');
      expect(data['verdict'], 'safe');
    });
  });

  group('progress lines (loading feedback on every slow command)', () {
    Harness withProgress() => Harness()..withProgress = true;

    test('use announces the registry fetch', () async {
      final h = withProgress();
      h.projects.project = const Project(rootPath: '/work/app');
      expect(await h.run(['use', '3.22.2']), 0);
      expect(h.progressRaw.join(), contains('Fetching release registry…'));
    });

    test('resolve announces registry + per-package compatibility', () async {
      final h = withProgress();
      h.projects.project = const Project(rootPath: '/work/app');
      h.projects.evidence = EvidenceFiles(
        files: const {
          'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ">=3.4.0 <3.5.0"\n',
          'pubspec.lock':
              'packages:\n'
              '  collection:\n'
              '    source: hosted\n'
              '    version: "1.19.0"\n',
        },
      );
      expect(await h.run(['resolve']), 0);
      final body = h.progressRaw.join();
      expect(body, contains('Fetching release registry…'));
      expect(body, contains('Checking package compatibility (1/1'));
    });

    test('upgrade announces the dependency simulation', () async {
      final h = withProgress();
      h.projects.project = const Project(rootPath: '/work/app');
      await h.run(['use', '3.22.2']);
      h.progressRaw.clear();
      expect(await h.run(['upgrade', '--advise']), 0);
      expect(
        h.progressRaw.join(),
        contains('Simulating dependency resolution on Flutter 3.24.1'),
      );
    });

    test('list --remote and remove announce their slow steps', () async {
      final h = withProgress();
      expect(await h.run(['list', '--remote']), 0);
      expect(h.progressRaw.join(), contains('Fetching release registry…'));

      h.progressRaw.clear();
      await h.run(['install', '3.22.2']);
      h.progressRaw.clear();
      expect(await h.run(['remove', '3.22.2']), 0);
      expect(h.progressRaw.join(), contains('Removing Flutter 3.22.2…'));
    });

    test('cache verify and repair announce their phases', () async {
      final h = withProgress();
      expect(await h.run(['cache', 'verify']), 0);
      // FakeCacheOps returns instantly; the phases come from the real
      // impl — here we only assert repair's per-diagnosis line.
      h.progressRaw.clear();
      h.health.storeProbes = [
        const Probe(kind: 'worktree', subject: '3.22.2', ok: false),
      ];
      expect(await h.run(['repair', '--yes']), 0);
      expect(h.progressRaw.join(), contains('Fixing FX-R03'));
    });

    test('--json stays clean: no progress lines at all', () async {
      final h = withProgress();
      h.projects.project = const Project(rootPath: '/work/app');
      expect(await h.run(['use', '3.22.2', '--json']), 0);
      expect(h.progressRaw, isEmpty);
    });
  });

  group('cache', () {
    test('status renders the size table', () async {
      final h = Harness();
      expect(await h.run(['cache', 'status']), 0);
      final body = h.out.join('\n');
      expect(body, contains('Shared git objects'));
      expect(body, contains('1.9 GB'));
      expect(body, contains('version 3.22.2'));
    });

    test('refresh reports the refreshed registry', () async {
      final h = Harness();
      expect(await h.run(['cache', 'refresh']), 0);
      expect(h.out.single, contains('registry refreshed — 2 releases'));
    });

    test('unknown subcommand → usage', () async {
      final h = Harness();
      expect(await h.run(['cache', 'explode']), 2);
    });

    test('gc --dry-run renders the reclaim table (docs/04 §3.10)', () async {
      final h = Harness();
      expect(await h.run(['cache', 'gc', '--dry-run', '--keep', '3.19.6']), 0);
      final body = h.out.join('\n');
      expect(body, contains('Would reclaim'));
      expect(body, contains('version 3.24.1'));
      expect(body, contains('2 unreferenced artifact(s)'));
      expect(body, contains('run without --dry-run to apply'));
      expect(h.cacheOps.lastGcOptions!.dryRun, isTrue);
      expect(h.cacheOps.lastGcOptions!.keep, {'3.19.6'});
    });

    test('verify healthy → exit 0; summary line rendered', () async {
      final h = Harness();
      expect(await h.run(['cache', 'verify']), 0);
      expect(h.out.single, contains('3 artifact(s) checked, 0 corrupt'));
    });
  });

  group('auto-hygiene (docs/05 §6.3)', () {
    test(
      'suggests gc after install when gc.auto=true and above threshold',
      () async {
        final h = Harness();
        h.config.entries['gc.auto'] = 'true';
        expect(await h.run(['install', '3.22.2']), 0);
        expect(
          h.out.join('\n'),
          contains('reclaimable — run `flutterx cache gc`'),
        );
      },
    );

    test('stays silent when gc.auto is unset', () async {
      final h = Harness();
      expect(await h.run(['install', '3.22.2']), 0);
      expect(h.out.join('\n'), isNot(contains('reclaimable')));
    });
  });

  group('config', () {
    test('set / get / list / unset round-trip', () async {
      final h = Harness();
      expect(await h.run(['config', 'set', 'channel.default', 'stable']), 0);
      h.out.clear();
      expect(await h.run(['config', 'get', 'channel.default']), 0);
      expect(h.out.single, 'stable');
      h.out.clear();
      expect(await h.run(['config', 'list']), 0);
      expect(h.out.single, contains('channel.default  stable'));
      h.out.clear();
      expect(await h.run(['config', 'unset', 'channel.default']), 0);
      h.out.clear();
      expect(await h.run(['config', 'get', 'channel.default']), 0);
      expect(h.out.single, '(unset)');
    });

    test('bad arity → usage', () async {
      final h = Harness();
      expect(await h.run(['config', 'set', 'only-key']), 2);
    });
  });

  group('proxy commands (docs/04 §3.13)', () {
    Harness resolved() {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      h.projects.sdkPath = '/store/versions/3.22.2';
      return h;
    }

    test('run passes argv through verbatim, exit code verbatim', () async {
      final h = resolved();
      h.platform.exitCodeToReturn = 42;
      expect(await h.runRaw(['run', '--release', '-d', 'chrome']), 42);
      final (exe, args, _) = h.platform.execCalls.single;
      expect(exe, '/store/versions/3.22.2/bin/flutter');
      expect(args, ['run', '--release', '-d', 'chrome']);
    });

    test('pub maps to flutter pub', () async {
      final h = resolved();
      expect(await h.runRaw(['pub', 'get', '--offline']), 0);
      expect(h.platform.execCalls.single.$2, ['pub', 'get', '--offline']);
    });

    test('build and test proxy the same way', () async {
      final h = resolved();
      await h.runRaw(['build', 'apk']);
      await h.runRaw(['test', 'test/foo_test.dart']);
      expect(h.platform.execCalls[0].$2, ['build', 'apk']);
      expect(h.platform.execCalls[1].$2, ['test', 'test/foo_test.dart']);
    });

    test('unresolved project → FX-STORE-008, exit 15, no exec', () async {
      final h = Harness();
      h.projects.project = const Project(rootPath: '/work/app');
      expect(await h.runRaw(['run']), 15);
      expect(h.err.first, contains('FX-STORE-008'));
      expect(h.platform.execCalls, isEmpty);
    });
  });

  group('shell (docs/04 §3.11)', () {
    test('one-shot command runs with the SDK first on PATH', () async {
      final h = Harness();
      await h.run(['install', '3.22.2']);
      h.platform.execCalls.clear();
      h.platform.exitCodeToReturn = 7;
      expect(
        await h.runRaw(['shell', '3.22.2', '--', 'flutter', 'test']),
        7,
        reason: 'exit code passthrough (contract class 20)',
      );
      final (exe, args, env) = h.platform.execCalls.single;
      expect(exe, 'flutter');
      expect(args, ['test']);
      expect(env!['PATH'], startsWith('/store/versions/3.22.2/bin:'));
    });

    test('no command → interactive \$SHELL subshell', () async {
      final h = Harness();
      await h.run(['install', '3.22.2']);
      h.platform.execCalls.clear();
      expect(await h.runRaw(['shell', '3.22.2']), 0);
      expect(h.platform.execCalls.single.$1, '/bin/zsh');
    });

    test('version not installed → exit 14', () async {
      final h = Harness();
      expect(await h.runRaw(['shell', '3.19.6']), 14);
    });
  });

  group('runner', () {
    test('no command → usage, exit 2', () async {
      final h = Harness();
      expect(await h.run([]), 2);
    });

    test('--version', () async {
      final h = Harness();
      expect(await h.run(['--version']), 0);
      expect(h.out.single, startsWith('flutterx '));
    });

    test('unknown command → usage error, exit 2', () async {
      final h = Harness();
      expect(await h.run(['frobnicate']), 2);
    });
  });
}
