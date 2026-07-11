import 'package:flutterx_domain/src/entities/flutter_release.dart';
import 'package:flutterx_domain/src/values/channel.dart';
import 'package:flutterx_domain/src/values/sem_ver.dart';

/// A point-in-time view of every known Flutter release (docs/03 §1.1).
///
/// Engines receive a snapshot and never refetch — same snapshot in, same
/// decision out (docs/03 shared principles). Snapshot age is part of any
/// explanation the engines produce.
final class RegistrySnapshot {
  /// [releases] are stored sorted by version descending regardless of input
  /// order, so "first match" always means "newest match".
  RegistrySnapshot({
    required List<FlutterRelease> releases,
    required this.fetchedAt,
    required this.source,
  }) : releases = List.unmodifiable(
         List<FlutterRelease>.of(releases)
           ..sort((a, b) => b.version.compareTo(a.version)),
       );

  /// All known releases, newest first.
  final List<FlutterRelease> releases;

  final DateTime fetchedAt;

  /// Where the snapshot came from: a URL, `cache`, or `seed`.
  final String source;

  /// Exact-version lookup.
  FlutterRelease? find(SemVer version) {
    for (final release in releases) {
      if (release.version == version) return release;
    }
    return null;
  }

  /// Resolves a user-facing specifier (docs/04 §1.1): exact (`3.22.2`),
  /// partial (`3.22` → latest patch), channel name, or `latest`.
  /// Retracted releases are skipped for non-exact specifiers.
  FlutterRelease? resolveSpecifier(String specifier) {
    final trimmed = specifier.trim();

    if (trimmed == 'latest') {
      return _newestWhere((r) => r.channel == Channel.stable && !r.retracted);
    }

    final channel = Channel.tryParse(trimmed);
    if (channel != null) {
      return _newestWhere((r) => r.channel == channel && !r.retracted);
    }

    final parts = trimmed.split('.');
    if (parts.length == 3) {
      try {
        return find(SemVer.parse(trimmed));
      } on FormatException {
        return null;
      }
    }
    if (parts.length == 2) {
      final major = int.tryParse(parts[0]);
      final minor = int.tryParse(parts[1]);
      if (major == null || minor == null) return null;
      return _newestWhere(
        (r) =>
            r.version.major == major &&
            r.version.minor == minor &&
            !r.retracted &&
            !r.version.isPreRelease,
      );
    }
    return null;
  }

  FlutterRelease? _newestWhere(bool Function(FlutterRelease) test) {
    for (final release in releases) {
      if (test(release)) return release;
    }
    return null;
  }
}
