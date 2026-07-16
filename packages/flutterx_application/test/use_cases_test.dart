import 'package:flutterx_application/flutterx_application.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

FlutterRelease release(String version, {String dart = '3.4.3'}) =>
    FlutterRelease(
      version: SemVer.parse(version),
      channel: Channel.stable,
      gitTag: version,
      frameworkSha: 'sha',
      dartVersion: SemVer.parse(dart),
      releasedAt: DateTime.utc(2026, 1, 1),
      artifacts: const {},
    );

RegistrySnapshot snapshot(List<FlutterRelease> releases) => RegistrySnapshot(
  releases: releases,
  fetchedAt: DateTime.utc(2026, 7, 11),
  source: 'test',
);

final class StubProjects implements ProjectStore {
  StubProjects(this.evidence);
  EvidenceFiles evidence;

  @override
  Future<Project?> findProject(String startDir) async =>
      const Project(rootPath: '/work/app');

  @override
  Future<EvidenceFiles> readEvidence(Project project) async => evidence;

  @override
  Future<Result<void>> writePin(
    Project project, {
    String? pinVersion,
    String? policyChannel,
  }) async => const Result.ok(null);

  @override
  Future<Resolution?> readLock(Project project) async => null;

  @override
  Future<Result<void>> writeLock(Project p, Resolution r) async =>
      const Result.ok(null);

  @override
  Future<Result<void>> linkSdk(Project p, InstalledSdk s) async =>
      const Result.ok(null);

  @override
  Future<String?> resolvedSdkPath(Project project) async => null;

  @override
  Future<Result<List<String>>> bumpDependencies(
    Project project,
    Map<String, SemVer> bumps,
  ) async => const Result.ok([]);
}

void main() {
  group('InstallSdk.suggestionsFor', () {
    final snap = snapshot([
      release('3.22.3'),
      release('3.22.2'),
      release('3.22.1'),
      release('3.22.0'),
      release('3.19.6'),
    ]);

    test('suggests same-minor releases, newest first, capped at 3', () {
      expect(InstallSdk.suggestionsFor('3.22.9', snap), [
        '3.22.3',
        '3.22.2',
        '3.22.1',
      ]);
    });

    test('no shared prefix → empty suggestions', () {
      expect(InstallSdk.suggestionsFor('9.9.9', snap), isEmpty);
    });
  });

  group('evidenceHash (docs/03 §7 staleness detector)', () {
    final projects = StubProjects(
      EvidenceFiles(files: const {'pubspec.yaml': 'name: app'}),
    );
    const project = Project(rootPath: '/work/app');

    test('is deterministic and prefixed', () async {
      final a = await evidenceHash(projects, project);
      final b = await evidenceHash(projects, project);
      expect(a, b);
      expect(a, startsWith('sha256:'));
    });

    test('changes when any evidence file changes', () async {
      final before = await evidenceHash(projects, project);
      projects.evidence = EvidenceFiles(
        files: const {'pubspec.yaml': 'name: app2'},
      );
      expect(await evidenceHash(projects, project), isNot(before));
    });

    test('is independent of map insertion order', () async {
      projects.evidence = EvidenceFiles(
        files: const {'a.yaml': '1', 'b.yaml': '2'},
      );
      final ab = await evidenceHash(projects, project);
      projects.evidence = EvidenceFiles(
        files: const {'b.yaml': '2', 'a.yaml': '1'},
      );
      expect(await evidenceHash(projects, project), ab);
    });
  });
}
