@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutterx_git/flutterx_git.dart';
import 'package:test/test.dart';

/// Integration coverage against the real git binary (docs/06 §10): a local
/// fixture repository with tags acts as the remote over file:// transport.
void main() {
  late Directory tmp;
  late String remotePath;
  late SystemGitEngine git;

  Future<void> sh(String exe, List<String> args, {String? cwd}) async {
    final result = await Process.run(exe, args, workingDirectory: cwd);
    if (result.exitCode != 0) {
      fail('$exe ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_git_test_');
    remotePath = '${tmp.path}/remote';

    // Fixture "flutter/flutter": two tagged commits.
    await Directory(remotePath).create(recursive: true);
    await sh('git', ['init', '-b', 'master', remotePath]);
    await sh('git', ['-C', remotePath, 'config', 'user.email', 't@t.t']);
    await sh('git', ['-C', remotePath, 'config', 'user.name', 'test']);
    // file:// remotes reject --filter unless explicitly allowed — enabling
    // it exercises the partial-clone happy path; the fallback path is
    // covered by unit tests.
    await sh('git', [
      '-C',
      remotePath,
      'config',
      'uploadpack.allowFilter',
      'true',
    ]);
    File('$remotePath/version').writeAsStringSync('3.19.6');
    await sh('git', ['-C', remotePath, 'add', '.']);
    await sh('git', ['-C', remotePath, 'commit', '-m', 'release 3.19.6']);
    await sh('git', ['-C', remotePath, 'tag', '3.19.6']);
    File('$remotePath/version').writeAsStringSync('3.22.2');
    await sh('git', ['-C', remotePath, 'add', '.']);
    await sh('git', ['-C', remotePath, 'commit', '-m', 'release 3.22.2']);
    await sh('git', ['-C', remotePath, 'tag', '3.22.2']);

    git = SystemGitEngine(
      bareRepoPath: '${tmp.path}/store/flutter.git',
      retryDelays: const [Duration.zero],
    );
  });

  tearDownAll(() async {
    await tmp.delete(recursive: true);
  });

  test('ensureBareRepo creates a configured bare repo, idempotently', () async {
    expect((await git.ensureBareRepo('file://$remotePath')).isOk, isTrue);
    expect((await git.ensureBareRepo('file://$remotePath')).isOk, isTrue);
    final config = File(
      '${tmp.path}/store/flutter.git/config',
    ).readAsStringSync();
    expect(config, contains('promisor = true'));
  });

  test('fetchTag brings the tag in; hasTag flips false → true', () async {
    expect(await git.hasTag('3.22.2'), isFalse);
    final result = await git.fetchTag('3.22.2');
    expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
    expect(await git.hasTag('3.22.2'), isTrue);
    // Note: git tag auto-following may also bring ancestor tags whose
    // objects came along (here 3.19.6 is an ancestor of 3.22.2). That is
    // harmless under partial clone — blobs stay lazy — so we don't assert
    // exclusivity.
  });

  test('fetching a nonexistent tag fails with FX-GIT-004', () async {
    final result = await git.fetchTag('9.9.9');
    expect(result.failureOrNull?.code, 'FX-GIT-004');
  });

  test('addWorktree materializes the tagged tree', () async {
    final path = '${tmp.path}/store/versions/3.22.2';
    final result = await git.addWorktree('3.22.2', path);
    expect(result.valueOrNull, path);
    expect(File('$path/version').readAsStringSync(), '3.22.2');
    expect(
      File('$path/.git').existsSync(),
      isTrue,
      reason: 'worktree keeps a valid .git link (docs/05 §4.3)',
    );
  });

  test('a second worktree shares objects (no duplicate store)', () async {
    expect((await git.fetchTag('3.19.6')).isOk, isTrue);
    final path = '${tmp.path}/store/versions/3.19.6';
    expect((await git.addWorktree('3.19.6', path)).isOk, isTrue);
    expect(File('$path/version').readAsStringSync(), '3.19.6');
    expect(
      Directory('$path/.git').existsSync(),
      isFalse,
      reason: 'worktrees carry a .git file pointer, not an object store',
    );
  });

  test('fsck reports healthy after fetches and checkouts', () async {
    final health = await git.fsck();
    expect(health.healthy, isTrue, reason: health.issues.join('\n'));
  });

  test('removeWorktree removes cleanly and is idempotent via prune', () async {
    final path = '${tmp.path}/store/versions/3.19.6';
    expect((await git.removeWorktree(path)).isOk, isTrue);
    expect(Directory(path).existsSync(), isFalse);
    expect(
      (await git.removeWorktree(path)).isOk,
      isTrue,
      reason: 'second removal reconciles via worktree prune',
    );
  });

  test('repack succeeds on the live store', () async {
    expect((await git.repack(aggressive: true)).isOk, isTrue);
  });
}
