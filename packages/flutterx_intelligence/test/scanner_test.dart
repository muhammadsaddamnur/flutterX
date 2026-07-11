import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_intelligence/flutterx_intelligence.dart';
import 'package:test/test.dart';

EvidenceFiles files(Map<String, String> map) => EvidenceFiles(files: map);

void main() {
  final scanner = StandardProjectScanner();

  group('FvmExtractor', () {
    test('reads a modern .fvmrc pin', () {
      final evidence = scanner.scan(files({'.fvmrc': '{"flutter": "3.22.2"}'}));
      final pin = evidence.effectivePin!;
      expect(pin.version, SemVer.parse('3.22.2'));
      expect(pin.source, EvidenceSource.fvmConfig);
      expect(pin.origin, '.fvmrc');
    });

    test('falls back to legacy .fvm/fvm_config.json', () {
      final evidence = scanner.scan(
        files({'.fvm/fvm_config.json': '{"flutterSdkVersion": "3.19.6"}'}),
      );
      expect(evidence.effectivePin?.version, SemVer.parse('3.19.6'));
    });

    test('malformed JSON is a warning, never a crash (fail-soft)', () {
      final evidence = scanner.scan(files({'.fvmrc': '{{{not json'}));
      expect(evidence.pins, isEmpty);
      expect(evidence.warnings.single.code, 'fvm-config-unreadable');
    });
  });

  group('PuroExtractor', () {
    test('a version-named env migrates as a pin', () {
      final evidence = scanner.scan(files({'.puro.json': '{"env": "3.22.2"}'}));
      expect(evidence.effectivePin?.source, EvidenceSource.puroConfig);
    });

    test('a named env cannot migrate automatically → warning', () {
      final evidence = scanner.scan(
        files({'.puro.json': '{"env": "my-work-env"}'}),
      );
      expect(evidence.pins, isEmpty);
      expect(evidence.warnings.single.code, 'puro-env-not-a-version');
    });
  });

  group('FlutterxYamlExtractor', () {
    test('reads the flutter pin, ignoring comments', () {
      final evidence = scanner.scan(
        files({'flutterx.yaml': '# intent file\nflutter: 3.24.1\n'}),
      );
      expect(evidence.effectivePin?.source, EvidenceSource.flutterxYaml);
      expect(evidence.effectivePin?.version, SemVer.parse('3.24.1'));
    });

    test('a policy line is not a pin', () {
      final evidence = scanner.scan(files({'flutterx.yaml': 'policy: stable'}));
      expect(evidence.pins, isEmpty);
      expect(evidence.warnings, isEmpty);
    });
  });

  group('StandardProjectScanner merge', () {
    test('conflicting pins: highest-priority source wins, always warned '
        '(docs/03 §2.3)', () {
      final evidence = scanner.scan(
        files({
          'flutterx.yaml': 'flutter: 3.22.2',
          '.fvmrc': '{"flutter": "3.19.0"}',
        }),
      );
      expect(evidence.effectivePin?.version, SemVer.parse('3.22.2'));
      expect(evidence.effectivePin?.origin, 'flutterx.yaml');
      final conflict = evidence.warnings.singleWhere(
        (w) => w.code == 'conflicting-pins',
      );
      expect('$conflict', contains('.fvmrc says 3.19.0'));
    });

    test('agreeing pins produce no conflict warning', () {
      final evidence = scanner.scan(
        files({
          'flutterx.yaml': 'flutter: 3.22.2',
          '.fvmrc': '{"flutter": "3.22.2"}',
        }),
      );
      expect(evidence.warnings, isEmpty);
    });

    test('empty project yields empty evidence', () {
      final evidence = scanner.scan(files({}));
      expect(evidence.pins, isEmpty);
      expect(evidence.warnings, isEmpty);
    });
  });
}
