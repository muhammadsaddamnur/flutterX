import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

/// A semantic version (docs/06 §2.1).
///
/// Wraps `pub_semver`'s [semver.Version] so the rest of the codebase never
/// depends on the third-party API directly. Total ordering follows semver
/// precedence rules (pre-releases sort below their release).
final class SemVer implements Comparable<SemVer> {
  SemVer._(this._inner);

  /// Parses a version like `3.22.2` or `3.22.0-1.2.pre`.
  ///
  /// Throws [FormatException] on invalid input — parsing user input into a
  /// failure instead of an exception is the caller's job.
  factory SemVer.parse(String input) => SemVer._(semver.Version.parse(input));

  factory SemVer(int major, int minor, int patch, {String? pre}) =>
      SemVer._(semver.Version(major, minor, patch, pre: pre));

  final semver.Version _inner;

  int get major => _inner.major;
  int get minor => _inner.minor;
  int get patch => _inner.patch;
  bool get isPreRelease => _inner.isPreRelease;

  /// `true` when [other] has the same major and minor (e.g. 3.22.1 ↔ 3.22.9).
  bool sameMinorAs(SemVer other) =>
      major == other.major && minor == other.minor;

  @override
  int compareTo(SemVer other) => _inner.compareTo(other._inner);

  bool operator <(SemVer other) => compareTo(other) < 0;
  bool operator <=(SemVer other) => compareTo(other) <= 0;
  bool operator >(SemVer other) => compareTo(other) > 0;
  bool operator >=(SemVer other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) => other is SemVer && _inner == other._inner;

  @override
  int get hashCode => _inner.hashCode;

  @override
  String toString() => _inner.toString();

  /// Escape hatch for [VersionConstraintX] only — do not use elsewhere.
  @internal
  semver.Version get inner => _inner;
}
