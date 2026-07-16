import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
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

PackageImpact impact(String name, {String? to}) => PackageImpact(
  name: name,
  currentVersion: SemVer.parse('1.0.0'),
  suggestedVersion: to == null ? null : SemVer.parse(to),
);

void main() {
  final advisor = StandardUpgradeAdvisor();

  UpgradeReport advise({
    List<PackageImpact> needsBump = const [],
    List<PackageImpact> blocking = const [],
    String from = '3.19.6',
    String to = '3.22.2',
  }) => advisor.advise(
    UpgradeParams(
      current: release(from, dart: '3.3.4'),
      target: release(to),
      dependencySimulation: DependencySimulation(
        unaffectedCount: 34,
        needsBump: needsBump,
        blocking: blocking,
      ),
    ),
  );

  group('verdicts (docs/03 §8.2 example semantics — noted deviation from '
      'the section pseudocode in docs/09)', () {
    test('clean simulation → SAFE', () {
      expect(advise().verdict, UpgradeVerdict.safe);
    });

    test('bumps needed → SAFE_WITH_CHANGES (the docs example scenario)', () {
      final report = advise(needsBump: [impact('freezed', to: '2.5.2')]);
      expect(report.verdict, UpgradeVerdict.safeWithChanges);
      expect(report.unaffectedCount, 34);
    });

    test('blocking packages → BLOCKED regardless of bumps', () {
      final report = advise(
        needsBump: [impact('freezed', to: '2.5.2')],
        blocking: [impact('legacy_pkg')],
      );
      expect(report.verdict, UpgradeVerdict.blocked);
    });
  });

  group('delta classification', () {
    test('patch / minor / major, order-independent', () {
      expect(
        StandardUpgradeAdvisor.classifyDelta(
          SemVer.parse('3.22.1'),
          SemVer.parse('3.22.2'),
        ),
        VersionDelta.patch,
      );
      expect(
        StandardUpgradeAdvisor.classifyDelta(
          SemVer.parse('3.19.6'),
          SemVer.parse('3.22.2'),
        ),
        VersionDelta.minor,
      );
      expect(
        StandardUpgradeAdvisor.classifyDelta(
          SemVer.parse('3.22.2'),
          SemVer.parse('2.10.0'),
        ),
        VersionDelta.major,
        reason: 'downgrades classify like the equivalent upgrade',
      );
    });
  });

  group('knowledge base (docs/03 §8.1 step 3)', () {
    final kb = KnowledgeBase.builtin();

    test('returns notes introduced in (current, target]', () {
      final notes = kb.entriesBetween(
        SemVer.parse('3.19.6'),
        SemVer.parse('3.22.2'),
      );
      expect(notes, hasLength(1));
      expect(notes.single.text, contains('3.22.0'));
      expect(notes.single.text, contains('Wasm'));
    });

    test('bounds: exclusive below, inclusive above', () {
      final notes = kb.entriesBetween(
        SemVer.parse('3.16.0'), // 3.16 note must NOT appear
        SemVer.parse('3.24.0'), // 3.24 note MUST appear
      );
      final texts = notes.map((n) => n.text).join('\n');
      expect(texts, isNot(contains('Material 3')));
      expect(texts, contains('Swift Package Manager'));
    });

    test('downgrades surface the same range (what would be lost)', () {
      final down = kb.entriesBetween(
        SemVer.parse('3.22.2'),
        SemVer.parse('3.19.6'),
      );
      expect(down.single.text, contains('Wasm'));
    });
  });
}
