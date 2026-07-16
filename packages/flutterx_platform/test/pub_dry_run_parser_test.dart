import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_platform/flutterx_platform.dart';
import 'package:test/test.dart';

/// Recorded shapes of `dart pub get --dry-run` output (T3.1.1).
void main() {
  group('parsePubDryRun — success', () {
    test('parses changed and unchanged dependency lines', () {
      final outcome = parsePubDryRun(
        exitCode: 0,
        output: '''
Resolving dependencies...
> freezed 2.5.2 (was 2.4.7)
  collection 1.19.0
> build_runner 2.4.11 (was 2.4.8)
  meta 1.16.0
  path 1.9.0
Would change 2 dependencies.
''',
      );
      expect(outcome.resolvable, isTrue);
      expect(outcome.needsBump, hasLength(2));
      final freezed = outcome.needsBump.first;
      expect(freezed.name, 'freezed');
      expect(freezed.currentVersion, SemVer.parse('2.4.7'));
      expect(freezed.suggestedVersion, SemVer.parse('2.5.2'));
      expect(outcome.unaffectedCount, 3);
      expect(outcome.blocking, isEmpty);
    });

    test('no changes → clean outcome', () {
      final outcome = parsePubDryRun(
        exitCode: 0,
        output: '''
Resolving dependencies...
  collection 1.19.0
  meta 1.16.0
Got dependencies!
''',
      );
      expect(outcome.needsBump, isEmpty);
      expect(outcome.unaffectedCount, 2);
    });
  });

  group('parsePubDryRun — failure', () {
    test('version solving failure → blocking with heuristic names', () {
      final outcome = parsePubDryRun(
        exitCode: 1,
        output: '''
Resolving dependencies...
Because my_app depends on legacy_pkg >=1.0.0 which requires SDK version
 >=2.12.0 <3.0.0, version solving failed.
''',
      );
      expect(outcome.resolvable, isFalse);
      expect(outcome.blocking.map((b) => b.name), contains('legacy_pkg'));
      expect(outcome.solverOutput, contains('version solving failed'));
    });

    test('unparseable failure still blocks with the raw output attached', () {
      final outcome = parsePubDryRun(
        exitCode: 69,
        output: 'something exploded',
      );
      expect(outcome.resolvable, isFalse);
      expect(outcome.blocking.single.name, 'dependencies');
      expect(outcome.solverOutput, 'something exploded');
    });
  });
}
