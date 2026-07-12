import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:yaml/yaml.dart';

/// Parses `pubspec.lock` into locked packages (docs/03 §6.1). Pure and
/// fail-soft: unparseable content yields an empty list. Packages provided
/// by the SDK itself (`sdk` source: flutter, sky_engine, …) are skipped —
/// they ship with whichever SDK is chosen.
List<LockedPackage> parseLockedPackages(String pubspecLockContent) {
  final Object? yaml;
  try {
    yaml = loadYaml(pubspecLockContent);
  } on YamlException {
    return const [];
  }
  if (yaml is! YamlMap) return const [];
  final packages = yaml['packages'];
  if (packages is! YamlMap) return const [];

  final locked = <LockedPackage>[];
  for (final entry in packages.entries) {
    final value = entry.value;
    if (value is! YamlMap) continue;
    final source = value['source']?.toString();
    if (source == 'sdk') continue;
    final SemVer version;
    try {
      version = SemVer.parse(value['version'].toString());
    } on FormatException {
      continue;
    }
    locked.add(
      LockedPackage(
        name: entry.key.toString(),
        version: version,
        hosted: source == 'hosted',
      ),
    );
  }
  return locked;
}

/// Fast-mode compatibility of one candidate SDK against the locked
/// packages (docs/03 §6.1 pseudocode). [metaFor] supplies cached pub.dev
/// metadata; `null` (git/path deps, cache misses) marks the package
/// unverified — reducing confidence in the score, never blocking.
DependencyCompatibility checkCompatibility(
  FlutterRelease release,
  List<LockedPackage> packages,
  PackageMeta? Function(LockedPackage) metaFor,
) {
  final incompatible = <String>[];
  final unverified = <String>[];
  var verified = 0;

  for (final package in packages) {
    final meta = package.hosted ? metaFor(package) : null;
    if (meta == null) {
      unverified.add(package.name);
      continue;
    }
    final dartOk = meta.dartConstraint.allows(release.dartVersion);
    final flutterOk = meta.flutterConstraint?.allows(release.version) ?? true;
    if (dartOk && flutterOk) {
      verified++;
    } else {
      incompatible.add(package.name);
    }
  }

  return DependencyCompatibility(
    verified: verified,
    total: packages.length,
    incompatible: incompatible,
    unverified: unverified,
  );
}

/// Per-package status for the `--matrix` view (docs/03 §6.2).
enum PackageCompatibility { compatible, incompatible, unknown }

/// The package × candidate compatibility matrix (docs/03 §6.2).
final class CompatibilityMatrix {
  CompatibilityMatrix({
    required List<SemVer> candidates,
    required Map<String, List<PackageCompatibility>> rows,
  }) : candidates = List.unmodifiable(candidates),
       rows = Map.unmodifiable(rows);

  /// Column order.
  final List<SemVer> candidates;

  /// Package name → status per candidate, in [candidates] order.
  final Map<String, List<PackageCompatibility>> rows;
}

CompatibilityMatrix buildCompatibilityMatrix(
  List<FlutterRelease> candidates,
  List<LockedPackage> packages,
  PackageMeta? Function(LockedPackage) metaFor,
) {
  final rows = <String, List<PackageCompatibility>>{};
  for (final package in packages) {
    rows[package.name] = [
      for (final release in candidates)
        switch (package.hosted ? metaFor(package) : null) {
          null => PackageCompatibility.unknown,
          final meta =>
            meta.dartConstraint.allows(release.dartVersion) &&
                    (meta.flutterConstraint?.allows(release.version) ?? true)
                ? PackageCompatibility.compatible
                : PackageCompatibility.incompatible,
        },
    ];
  }
  return CompatibilityMatrix(
    candidates: [for (final release in candidates) release.version],
    rows: rows,
  );
}
