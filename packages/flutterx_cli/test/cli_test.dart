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

  @override
  Future<Result<PackageMeta>> packageMeta(String name, SemVer version) =>
      throw UnimplementedError();
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
}

final class FakeHealth implements StoreHealthPort, PlatformHealthPort {
  var storeProbes = <Probe>[
    const Probe(kind: 'store-state', subject: 'state.json', ok: true),
  ];
  var platformProbes = <Probe>[
    const Probe(kind: 'git', subject: '2.51', ok: true),
  ];

  @override
  Future<List<Probe>> probeStore() async => storeProbes;

  @override
  Future<List<Probe>> probeProject(Project project) async => const [
    Probe(kind: 'project-lock', subject: 'lock', ok: true),
  ];

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
  Future<Result<void>> refreshGitObjects() async => const Result.ok(null);
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
  final out = <String>[];
  final err = <String>[];

  Future<int> run(List<String> args) => FlutterXCli(
    api: FlutterXApi(
      sdkRepository: sdks,
      registry: registry,
      projectStore: projects,
      storeHealth: health,
      platformHealth: health,
      cacheOps: FakeCacheOps(),
      config: config,
      clock: () => DateTime.utc(2026, 7, 11),
    ),
    out: out.add,
    err: err.add,
    workingDirectory: '/work/app',
  ).run([...args, '--no-color']);
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
