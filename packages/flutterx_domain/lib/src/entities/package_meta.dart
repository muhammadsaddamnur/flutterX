import 'package:flutterx_domain/src/values/sem_ver.dart';
import 'package:flutterx_domain/src/values/version_constraint_x.dart';

/// SDK requirements of one pub package version, as published on pub.dev
/// (docs/03 §6.1).
///
/// Consumed by Dependency Intelligence fast mode to check a locked package
/// against a candidate SDK without running the real resolver.
final class PackageMeta {
  const PackageMeta({
    required this.name,
    required this.version,
    required this.dartConstraint,
    this.flutterConstraint,
  });

  final String name;
  final SemVer version;

  /// The package's `environment: sdk:` constraint.
  final VersionConstraintX dartConstraint;

  /// The package's `environment: flutter:` constraint, when declared.
  final VersionConstraintX? flutterConstraint;

  @override
  String toString() => 'PackageMeta($name $version)';
}
