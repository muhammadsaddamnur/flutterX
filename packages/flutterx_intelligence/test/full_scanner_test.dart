import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

/// Full-pipeline scanner tests over real-world shaped fixtures
/// (T2.1.2–T2.1.4, docs/03 §2).
void main() {
  final scanner = StandardProjectScanner();

  String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

  EvidenceFiles project({Map<String, String> extra = const {}}) =>
      EvidenceFiles(
        files: {
          'pubspec.yaml': fixture('pubspec.yaml'),
          'pubspec.lock': fixture('pubspec.lock'),
          '.metadata': fixture('metadata'),
          '.github/workflows/build.yml': fixture('build.yml'),
          'lib/main.dart': '',
          ...extra,
        },
      );

  group('the cross-engine example project (docs/03 §10 shape)', () {
    late ProjectEvidence evidence;
    setUpAll(() => evidence = scanner.scan(project()));

    test('no pins — nothing pinned in a freshly cloned repo', () {
      expect(evidence.pins, isEmpty);
    });

    test('hard constraints: pubspec sdk + lockfile aggregate sdks.dart', () {
      expect(evidence.hard, hasLength(2));
      final pubspec = evidence.hard.singleWhere(
        (c) => c.source == EvidenceSource.pubspecSdkConstraint,
      );
      expect(pubspec.kind, ConstraintKind.dart);
      expect(pubspec.constraint.allows(SemVer.parse('3.3.0')), isTrue);
      expect(pubspec.constraint.allows(SemVer.parse('4.0.0')), isFalse);

      final lock = evidence.hard.singleWhere(
        (c) => c.source == EvidenceSource.pubspecLock,
      );
      expect(
        lock.constraint.allows(SemVer.parse('3.3.3')),
        isFalse,
        reason: 'lockfile narrowed the floor to 3.3.4',
      );
    });

    test('CI hint: exact 3.19.6 from the GitHub workflow', () {
      final hint = evidence.hints.single;
      expect(hint.source, EvidenceSource.ciWorkflow);
      expect(hint.version, SemVer.parse('3.19.6'));
      expect(hint.exactPatch, isTrue);
      expect(hint.origin, '.github/workflows/build.yml');
    });

    test('classified as an app (.metadata project_type wins)', () {
      expect(evidence.kind, ProjectKind.app);
    });

    test('scan is clean — no warnings on well-formed input', () {
      expect(evidence.warnings, isEmpty);
    });
  });

  group('classification without .metadata (pubspec heuristic)', () {
    test('flutter dep + lib/main.dart → app', () {
      final evidence = scanner.scan(
        EvidenceFiles(
          files: {'pubspec.yaml': fixture('pubspec.yaml'), 'lib/main.dart': ''},
        ),
      );
      expect(evidence.kind, ProjectKind.app);
    });

    test('flutter dep without an entry point → package', () {
      final evidence = scanner.scan(
        EvidenceFiles(files: {'pubspec.yaml': fixture('pubspec.yaml')}),
      );
      expect(evidence.kind, ProjectKind.package);
    });

    test('flutter.plugin section → plugin', () {
      final evidence = scanner.scan(
        EvidenceFiles(
          files: {
            'pubspec.yaml':
                'name: my_plugin\n'
                'environment:\n  sdk: ^3.4.0\n'
                'dependencies:\n  flutter:\n    sdk: flutter\n'
                'flutter:\n  plugin:\n    platforms:\n      android:\n',
          },
        ),
      );
      expect(evidence.kind, ProjectKind.plugin);
    });

    test('no flutter dependency → pure Dart package', () {
      final evidence = scanner.scan(
        EvidenceFiles(
          files: {'pubspec.yaml': 'name: tool\nenvironment:\n  sdk: ^3.4.0\n'},
        ),
      );
      expect(evidence.kind, ProjectKind.package);
    });
  });

  group('edge cases (docs/03 §2.3)', () {
    test('resolution.lock is the strongest pin', () {
      final evidence = scanner.scan(
        project(
          extra: {
            '.flutterx/resolution.lock': 'flutterx: 1\nflutter: 3.22.2\n',
            '.fvmrc': '{"flutter": "3.19.0"}',
          },
        ),
      );
      expect(evidence.effectivePin?.source, EvidenceSource.resolutionLock);
      expect(evidence.effectivePin?.version, SemVer.parse('3.22.2'));
      expect(
        evidence.warnings.any((w) => w.code == 'conflicting-pins'),
        isTrue,
      );
    });

    test('malformed pubspec YAML warns and the pipeline continues', () {
      final evidence = scanner.scan(
        project(extra: {'pubspec.yaml': 'environment:\n  sdk: [broken'}),
      );
      expect(evidence.warnings.any((w) => w.code == 'malformed-yaml'), isTrue);
      // Other extractors still contributed.
      expect(evidence.hints, isNotEmpty);
      expect(evidence.hard, isNotEmpty, reason: 'lockfile still parsed');
    });

    test('`any` sdk constraint contributes nothing', () {
      final evidence = scanner.scan(
        EvidenceFiles(
          files: {'pubspec.yaml': 'name: x\nenvironment:\n  sdk: any\n'},
        ),
      );
      expect(evidence.hard, isEmpty);
    });

    test('codemagic flutter: version is a hint; channel names are not', () {
      final evidence = scanner.scan(
        EvidenceFiles(
          files: {
            'codemagic.yaml':
                'workflows:\n  default:\n    environment:\n'
                '      flutter: 3.22.1\n',
          },
        ),
      );
      expect(evidence.hints.single.version, SemVer.parse('3.22.1'));

      final channelOnly = scanner.scan(
        EvidenceFiles(
          files: {
            'codemagic.yaml':
                'workflows:\n  default:\n    environment:\n'
                '      flutter: stable\n',
          },
        ),
      );
      expect(channelOnly.hints, isEmpty);
    });
  });
}
