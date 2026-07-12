@TestOn('!windows')
// Symlink-based: Windows junction support (and these tests'
// junction-aware equivalents) land with M1.11 (docs/09).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class FakeGitEngine implements GitEngine {
  final removedWorktrees = <String>[];
  var repacked = false;

  @override
  Future<Result<void>> ensureBareRepo(String originUrl) async =>
      const Result.ok(null);

  @override
  Future<bool> hasTag(String tag) async => true;

  @override
  Future<Result<void>> fetchTag(String tag) async => const Result.ok(null);

  @override
  Future<Result<void>> refreshRemote() async => const Result.ok(null);

  @override
  Future<Result<String>> addWorktree(String tag, String path) async =>
      Result.ok(path);

  @override
  Future<Result<void>> removeWorktree(String path) async {
    removedWorktrees.add(path);
    return const Result.ok(null);
  }

  @override
  Future<GitHealth> fsck() async => GitHealth(healthy: true);

  @override
  Future<Result<void>> repack({bool aggressive = false}) async {
    repacked = true;
    return const Result.ok(null);
  }
}

void main() {
  late Directory tmp;
  late StoreLayout layout;
  late FakeGitEngine git;
  late ArtifactStore cas;
  late StoreGc gc;
  final now = DateTime.utc(2026, 7, 13);

  Future<Result<void>> symlinkCreate({
    required String targetPath,
    required String linkPath,
  }) async {
    await Link(linkPath).create(targetPath);
    return const Result.ok(null);
  }

  /// Installs a fake version: worktree dir + manifest (+ optional live
  /// project reference).
  Future<void> installVersion(
    String version, {
    List<String> artifacts = const [],
    DateTime? installedAt,
    String? referencedBy,
  }) async {
    final dir = Directory(layout.versionDir(version));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'version')).writeAsString(version);
    await File(layout.versionManifest(version)).writeAsString(
      jsonEncode({
        'version': version,
        'artifacts': artifacts,
        'installedAt': (installedAt ?? DateTime.utc(2026, 1, 1))
            .toIso8601String(),
      }),
    );
    if (referencedBy != null) {
      final project = Directory(referencedBy)..createSync(recursive: true);
      final flutterxDir = Directory(p.join(project.path, '.flutterx'))
        ..createSync();
      await Link(p.join(flutterxDir.path, 'sdk')).create(dir.path);
      final state = (await layout.loadState()).valueOrNull!;
      await layout.saveState(
        state.withProject(ProjectRef(path: project.path, version: version)),
      );
    }
  }

  /// Puts a payload into the CAS directly and returns its sha-key.
  Future<String> casEntry(String content) async {
    final file = File(p.join(tmp.path, 'stray-$content'));
    await file.writeAsString(content);
    final adopted = await cas.adoptFile(file.path);
    final sha = adopted.valueOrNull!.sha256;
    await File(file.path).delete(); // remove the link-back; CAS keeps payload
    return sha;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_gc_');
    layout = StoreLayout(p.join(tmp.path, 'store'));
    await layout.init();
    git = FakeGitEngine();
    cas = ArtifactStore(
      layout: layout,
      downloads: DownloadManager(downloadsDir: layout.downloadsDir),
      createLink: symlinkCreate,
    );
    gc = StoreGc(
      layout: layout,
      git: git,
      artifacts: cas,
      journal: FileJournal(journalDir: layout.journalDir),
      lock: StoreLock(layout.storeLockFile),
    );
  });

  tearDown(() => tmp.delete(recursive: true));

  GcOptions options({bool dryRun = false, Set<String> keep = const {}}) =>
      GcOptions(dryRun: dryRun, keep: keep, now: now);

  test('orphans are reclaimed; referenced and kept versions survive '
      '(docs/05 §6.1–6.2)', () async {
    await installVersion(
      '3.22.2',
      referencedBy: p.join(tmp.path, 'work', 'app'),
    );
    await installVersion('3.24.1'); // orphan, old
    await installVersion('3.19.6'); // orphan but kept

    final report = (await gc.run(options(keep: {'3.19.6'}))).valueOrNull!;

    expect(report.versionBytes.keys, ['3.24.1']);
    expect(git.removedWorktrees.single, contains('3.24.1'));
    expect(Directory(layout.versionDir('3.24.1')).existsSync(), isFalse);
    expect(Directory(layout.versionDir('3.22.2')).existsSync(), isTrue);
    expect(Directory(layout.versionDir('3.19.6')).existsSync(), isTrue);
  });

  test('young orphans are protected by the grace period', () async {
    await installVersion(
      '3.24.1',
      installedAt: now.subtract(const Duration(days: 3)),
    );
    final report = (await gc.run(options())).valueOrNull!;
    expect(report.versionBytes, isEmpty);
    expect(Directory(layout.versionDir('3.24.1')).existsSync(), isTrue);
  });

  test('dry-run measures everything and deletes nothing', () async {
    await installVersion('3.24.1');
    final sha = await casEntry('unreferenced-blob');
    final report = (await gc.run(options(dryRun: true))).valueOrNull!;
    expect(report.dryRun, isTrue);
    expect(report.versionBytes.keys, ['3.24.1']);
    expect(report.artifactsRemoved, 1);
    expect(report.totalBytes, greaterThan(0));
    expect(Directory(layout.versionDir('3.24.1')).existsSync(), isTrue);
    expect(File(layout.casPayload(sha)).existsSync(), isTrue);
    expect(git.removedWorktrees, isEmpty);
  });

  test(
    'artifacts referenced by surviving manifests are kept; the rest go',
    () async {
      final liveSha = await casEntry('live-blob');
      final deadSha = await casEntry('dead-blob');
      await installVersion(
        '3.22.2',
        artifacts: [liveSha],
        referencedBy: p.join(tmp.path, 'work', 'app'),
      );

      final report = (await gc.run(options())).valueOrNull!;
      expect(report.artifactsRemoved, 1);
      expect(File(layout.casPayload(liveSha)).existsSync(), isTrue);
      expect(File(layout.casPayload(deadSha)).existsSync(), isFalse);
    },
  );

  test(
    'adoption pass returns precache strays to the CAS (docs/05 §4.3)',
    () async {
      await installVersion(
        '3.22.2',
        referencedBy: p.join(tmp.path, 'work', 'app'),
      );
      final strayDir = Directory(
        p.join(layout.versionDir('3.22.2'), 'bin', 'cache', 'artifacts'),
      )..createSync(recursive: true);
      final stray = File(p.join(strayDir.path, 'precached.bin'))
        ..writeAsStringSync('engine bits from flutter precache');

      final report = (await gc.run(options())).valueOrNull!;
      expect(report.adoptedArtifacts, 1);
      expect(
        Link(stray.path).existsSync(),
        isTrue,
        reason: 'the stray became a link into the CAS',
      );
      expect(
        report.artifactsRemoved,
        0,
        reason: 'freshly adopted payloads are live',
      );
    },
  );

  test('stale downloads are pruned; fresh ones stay', () async {
    final downloads = Directory(layout.downloadsDir)
      ..createSync(recursive: true);
    final old = File(p.join(downloads.path, 'old.partial'))
      ..writeAsStringSync('x' * 100);
    // Backdate mtime beyond the 7-day grace (portable — no `touch`).
    old.setLastModifiedSync(DateTime.utc(2026, 1, 1));
    File(p.join(downloads.path, 'fresh.partial')).writeAsStringSync('y');

    final report = (await gc.run(options())).valueOrNull!;
    expect(report.downloadBytes, 100);
    expect(File(p.join(downloads.path, 'old.partial')).existsSync(), isFalse);
    expect(File(p.join(downloads.path, 'fresh.partial')).existsSync(), isTrue);
  });

  test('--aggressive additionally repacks git objects', () async {
    await gc.run(GcOptions(aggressive: true, now: now));
    expect(git.repacked, isTrue);
  });
}
