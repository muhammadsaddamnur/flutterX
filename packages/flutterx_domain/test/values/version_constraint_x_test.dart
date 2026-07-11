import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

void main() {
  group('VersionConstraintX.allows', () {
    test('range constraint bounds are honored', () {
      final constraint = VersionConstraintX.parse('>=3.4.0 <4.0.0');
      expect(constraint.allows(SemVer.parse('3.4.0')), isTrue);
      expect(constraint.allows(SemVer.parse('3.9.9')), isTrue);
      expect(constraint.allows(SemVer.parse('4.0.0')), isFalse);
      expect(constraint.allows(SemVer.parse('3.3.9')), isFalse);
    });

    test('caret syntax matches pub semantics', () {
      final constraint = VersionConstraintX.parse('^3.4.0');
      expect(constraint.allows(SemVer.parse('3.4.3')), isTrue);
      expect(constraint.allows(SemVer.parse('4.0.0')), isFalse);
    });

    test('pre-release lower bound admits pre-releases (docs/03 §3.2)', () {
      final constraint = VersionConstraintX.parse('>=3.4.0-0');
      expect(constraint.allows(SemVer.parse('3.4.0-1.2.pre')), isTrue);
      expect(constraint.allows(SemVer.parse('3.4.0')), isTrue);
    });
  });

  group('VersionConstraintX.any', () {
    test('allows everything and reports isAny', () {
      expect(VersionConstraintX.any.isAny, isTrue);
      expect(VersionConstraintX.any.allows(SemVer.parse('0.0.1')), isTrue);
      expect(VersionConstraintX.parse('any').isAny, isTrue);
    });
  });

  group('VersionConstraintX.intersect', () {
    test('overlapping ranges narrow', () {
      final a = VersionConstraintX.parse('>=3.0.0 <4.0.0');
      final b = VersionConstraintX.parse('>=3.4.0');
      final both = a.intersect(b);
      expect(both.allows(SemVer.parse('3.4.0')), isTrue);
      expect(both.allows(SemVer.parse('3.3.0')), isFalse);
      expect(both.allows(SemVer.parse('4.0.0')), isFalse);
    });

    test('disjoint ranges intersect to empty', () {
      final a = VersionConstraintX.parse('<3.0.0');
      final b = VersionConstraintX.parse('>=3.4.0');
      expect(a.intersect(b).isEmpty, isTrue);
    });

    test('intersecting with any is identity', () {
      final a = VersionConstraintX.parse('^3.4.0');
      expect(a.intersect(VersionConstraintX.any), a);
    });
  });

  test('rejects invalid syntax with FormatException', () {
    expect(() => VersionConstraintX.parse('><nope'), throwsFormatException);
  });
}
