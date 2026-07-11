import 'package:flutterx_domain/src/values/sem_ver.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

/// A version constraint such as `>=3.4.0 <4.0.0`, `^3.4.0`, or `any`
/// (docs/06 §2.1).
///
/// Wraps `pub_semver`'s [semver.VersionConstraint]; pre-release semantics
/// (`>=3.4.0-0`) follow pub's rules exactly (docs/03 §3.2 edge cases).
final class VersionConstraintX {
  VersionConstraintX._(this._inner);

  /// Parses pub-style constraint syntax. Throws [FormatException] on invalid
  /// input.
  factory VersionConstraintX.parse(String input) =>
      VersionConstraintX._(semver.VersionConstraint.parse(input));

  /// The constraint that allows every version.
  static final VersionConstraintX any = VersionConstraintX._(
    semver.VersionConstraint.any,
  );

  final semver.VersionConstraint _inner;

  bool allows(SemVer version) => _inner.allows(version.inner);

  /// `true` when this constraint allows every version (contributes nothing to
  /// solving — noted in the provenance trace, docs/03 §3.2).
  bool get isAny => _inner.isAny;

  bool get isEmpty => _inner.isEmpty;

  /// The intersection of two constraints; may be empty.
  VersionConstraintX intersect(VersionConstraintX other) =>
      VersionConstraintX._(_inner.intersect(other._inner));

  @override
  bool operator ==(Object other) =>
      other is VersionConstraintX && _inner == other._inner;

  @override
  int get hashCode => _inner.hashCode;

  @override
  String toString() => _inner.toString();
}
