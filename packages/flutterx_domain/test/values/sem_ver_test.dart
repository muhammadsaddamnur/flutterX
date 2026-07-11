import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

void main() {
  group('SemVer ordering laws', () {
    final v1 = SemVer.parse('3.19.6');
    final v2 = SemVer.parse('3.22.2');
    final v3 = SemVer.parse('3.24.1');

    test('is transitive', () {
      expect(v1 < v2, isTrue);
      expect(v2 < v3, isTrue);
      expect(v1 < v3, isTrue);
    });

    test('is antisymmetric', () {
      expect(v1 < v2, isTrue);
      expect(v2 < v1, isFalse);
    });

    test('equal versions compare as equal, not less', () {
      final a = SemVer.parse('3.22.2');
      final b = SemVer.parse('3.22.2');
      expect(a.compareTo(b), 0);
      expect(a < b, isFalse);
      expect(a >= b, isTrue);
    });

    test('pre-release sorts below its release', () {
      final pre = SemVer.parse('3.22.0-1.2.pre');
      final release = SemVer.parse('3.22.0');
      expect(pre < release, isTrue);
      expect(pre.isPreRelease, isTrue);
      expect(release.isPreRelease, isFalse);
    });
  });

  group('SemVer equality', () {
    test('parsed and constructed versions are equal', () {
      expect(SemVer(3, 22, 2), SemVer.parse('3.22.2'));
      expect(SemVer(3, 22, 2).hashCode, SemVer.parse('3.22.2').hashCode);
    });

    test('different versions are not equal', () {
      expect(SemVer.parse('3.22.2'), isNot(SemVer.parse('3.22.1')));
    });
  });

  group('SemVer parsing', () {
    test('round-trips through toString', () {
      for (final input in ['3.22.2', '0.1.0', '3.22.0-1.2.pre']) {
        expect(SemVer.parse(input).toString(), input);
      }
    });

    test('rejects invalid input with FormatException', () {
      expect(() => SemVer.parse('not-a-version'), throwsFormatException);
      expect(() => SemVer.parse(''), throwsFormatException);
    });
  });

  group('SemVer.sameMinorAs', () {
    test('true across patches of one minor', () {
      expect(
        SemVer.parse('3.22.0').sameMinorAs(SemVer.parse('3.22.9')),
        isTrue,
      );
    });

    test('false across minors and majors', () {
      expect(
        SemVer.parse('3.22.2').sameMinorAs(SemVer.parse('3.24.2')),
        isFalse,
      );
      expect(
        SemVer.parse('3.22.2').sameMinorAs(SemVer.parse('4.22.2')),
        isFalse,
      );
    });
  });
}
