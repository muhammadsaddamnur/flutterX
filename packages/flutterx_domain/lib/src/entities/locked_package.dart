import 'package:flutterx_domain/src/values/sem_ver.dart';

/// One entry of a project's `pubspec.lock` (docs/03 §6.1).
///
/// Only hosted packages can be verified against pub.dev metadata; git and
/// path dependencies are structurally unverifiable in fast mode — they
/// count as `?`, never as incompatible (docs/03 §6.2).
final class LockedPackage {
  const LockedPackage({
    required this.name,
    required this.version,
    required this.hosted,
  });

  final String name;
  final SemVer version;
  final bool hosted;

  @override
  String toString() => '$name $version${hosted ? '' : ' (unhosted)'}';
}
