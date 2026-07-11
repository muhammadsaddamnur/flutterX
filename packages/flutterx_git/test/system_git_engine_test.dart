import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_git/flutterx_git.dart';
import 'package:test/test.dart';

/// Scripted fake for the process seam: matches invocations by substring
/// over the joined args and returns canned results, recording every call.
final class FakeGit {
  FakeGit({this.version = 'git version 2.51.0'});

  final String version;
  final calls = <List<String>>[];
  final _rules = <({String contains, int exitCode, String stderr})>[];

  void failWhen(String contains, {int exitCode = 128, String stderr = ''}) =>
      _rules.add((contains: contains, exitCode: exitCode, stderr: stderr));

  /// Fails only the first [times] matching calls, then succeeds.
  void failFirst(String contains, {required int times, String stderr = ''}) {
    var remaining = times;
    _dynamicRules.add((args) {
      if (!args.join(' ').contains(contains) || remaining <= 0) return null;
      remaining--;
      return ProcessResult(0, 128, '', stderr);
    });
  }

  final _dynamicRules = <ProcessResult? Function(List<String>)>[];

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add(args);
    final joined = args.join(' ');
    if (joined == '--version') return ProcessResult(0, 0, version, '');
    for (final dynamic_ in _dynamicRules) {
      final result = dynamic_(args);
      if (result != null) return result;
    }
    for (final rule in _rules) {
      if (joined.contains(rule.contains)) {
        return ProcessResult(0, rule.exitCode, '', rule.stderr);
      }
    }
    // Default: succeed; rev-parse checks report an existing bare repo.
    if (joined.contains('--is-bare-repository')) {
      return ProcessResult(0, 0, 'true\n', '');
    }
    return ProcessResult(0, 0, '', '');
  }
}

SystemGitEngine engine(FakeGit fake) => SystemGitEngine(
  bareRepoPath: '/store/cache/git/flutter.git',
  runProcess: fake.call,
  retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
);

void main() {
  group('git version gate (FX-GIT-001)', () {
    test('rejects git older than 2.30', () async {
      final fake = FakeGit(version: 'git version 2.25.1');
      final result = await engine(fake).fetchTag('3.22.2');
      expect(result.failureOrNull?.code, 'FX-GIT-001');
    });

    test('accepts 2.30 and newer, checks version only once', () async {
      final fake = FakeGit(version: 'git version 2.30.0');
      final git = engine(fake);
      expect((await git.fetchTag('3.22.2')).isOk, isTrue);
      expect((await git.fetchTag('3.19.6')).isOk, isTrue);
      final versionCalls = fake.calls.where((c) => c.contains('--version'));
      expect(versionCalls.length, 1);
    });
  });

  group('ensureBareRepo', () {
    test('existing bare repo is a no-op', () async {
      final fake = FakeGit();
      final result = await engine(fake).ensureBareRepo('https://x/f.git');
      expect(result.isOk, isTrue);
      expect(fake.calls.any((c) => c.contains('init')), isFalse);
    });

    test(
      'missing repo → init + promisor/partial-clone config, no clone',
      () async {
        final fake = FakeGit();
        fake.failWhen('--is-bare-repository', exitCode: 128);
        final result = await engine(fake).ensureBareRepo('https://x/f.git');
        expect(result.isOk, isTrue);
        final joined = fake.calls.map((c) => c.join(' ')).toList();
        expect(joined.any((c) => c.contains('init --bare')), isTrue);
        expect(
          joined.any((c) => c.contains('remote.origin.promisor true')),
          isTrue,
        );
        expect(
          joined.any(
            (c) => c.contains('remote.origin.partialclonefilter blob:none'),
          ),
          isTrue,
        );
        // 'clone' as an exact git subcommand — 'partialclonefilter' config
        // keys legitimately contain the substring.
        expect(fake.calls.any((c) => c.contains('clone')), isFalse);
      },
    );
  });

  group('fetchTag strategy (docs/05 §4.1)', () {
    test('uses partial clone, never shallow', () async {
      final fake = FakeGit();
      await engine(fake).fetchTag('3.22.2');
      final fetch = fake.calls.firstWhere((c) => c.contains('fetch'));
      expect(fetch, contains('--filter=blob:none'));
      expect(fetch.join(' '), isNot(contains('--depth')));
      expect(fetch, containsAllInOrder(['origin', 'tag', '3.22.2']));
    });

    test('falls back to full fetch when the server rejects filters', () async {
      final fake = FakeGit();
      fake.failWhen(
        '--filter=blob:none',
        stderr: 'fatal: filtering not recognized by server',
      );
      final result = await engine(fake).fetchTag('3.22.2');
      expect(result.isOk, isTrue);
      final fetches = fake.calls.where((c) => c.contains('fetch')).toList();
      expect(fetches, hasLength(2));
      expect(fetches.last.join(' '), isNot(contains('--filter')));
    });

    test(
      'retries transient network errors 3 times then fails FX-GIT-002',
      () async {
        final fake = FakeGit();
        fake.failWhen(
          'fetch',
          stderr: 'fatal: Could not resolve host: github.com',
        );
        final result = await engine(fake).fetchTag('3.22.2');
        expect(result.failureOrNull, isA<NetworkFailure>());
        expect(result.failureOrNull?.code, 'FX-GIT-002');
        expect(
          fake.calls.where((c) => c.contains('fetch')).length,
          4,
          reason: '1 attempt + 3 retries',
        );
      },
    );

    test('recovers when a retry succeeds', () async {
      final fake = FakeGit();
      fake.failFirst(
        'fetch',
        times: 2,
        stderr: 'fatal: unable to access: timeout',
      );
      final result = await engine(fake).fetchTag('3.22.2');
      expect(result.isOk, isTrue);
      expect(fake.calls.where((c) => c.contains('fetch')).length, 3);
    });

    test('missing remote ref fails fast with FX-GIT-004, no retries', () async {
      final fake = FakeGit();
      fake.failWhen(
        'fetch',
        stderr: "fatal: couldn't find remote ref refs/tags/9.9.9",
      );
      final result = await engine(fake).fetchTag('9.9.9');
      expect(result.failureOrNull?.code, 'FX-GIT-004');
      expect(fake.calls.where((c) => c.contains('fetch')).length, 1);
    });
  });

  group('worktrees', () {
    test(
      'addWorktree checks out the tag detached and returns the path',
      () async {
        final fake = FakeGit();
        final result = await engine(
          fake,
        ).addWorktree('3.22.2', '/store/versions/3.22.2');
        expect(result.valueOrNull, '/store/versions/3.22.2');
        final call = fake.calls.firstWhere((c) => c.contains('worktree'));
        expect(
          call.join(' '),
          contains(
            'worktree add --detach /store/versions/3.22.2 '
            'refs/tags/3.22.2',
          ),
        );
      },
    );

    test(
      'removeWorktree falls back to prune when the dir is already gone',
      () async {
        final fake = FakeGit();
        fake.failWhen('worktree remove', stderr: 'fatal: not a working tree');
        final result = await engine(
          fake,
        ).removeWorktree('/store/versions/3.22.2');
        expect(result.isOk, isTrue);
        expect(
          fake.calls.any((c) => c.join(' ').contains('worktree prune')),
          isTrue,
        );
      },
    );
  });

  group('fsck', () {
    test('healthy repo', () async {
      final health = await engine(FakeGit()).fsck();
      expect(health.healthy, isTrue);
      expect(health.issues, isEmpty);
    });

    test('unhealthy repo reports issues', () async {
      final fake = FakeGit();
      fake.failWhen('fsck', stderr: 'missing blob abc123\nbroken link def456');
      final health = await engine(fake).fsck();
      expect(health.healthy, isFalse);
      expect(health.issues, hasLength(2));
    });
  });

  test('repack --aggressive prunes', () async {
    final fake = FakeGit();
    await engine(fake).repack(aggressive: true);
    final call = fake.calls.firstWhere((c) => c.contains('gc'));
    expect(call, containsAll(['--aggressive', '--prune=now']));
  });
}
