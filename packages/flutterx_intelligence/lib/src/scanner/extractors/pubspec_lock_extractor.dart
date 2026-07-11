import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:yaml/yaml.dart';

/// pubspec.lock evidence (docs/03 §2.1 source 7): the aggregate
/// `sdks.dart` constraint pub computed across the whole dependency graph —
/// a hard constraint reflecting what the locked packages actually demand.
/// Per-package compatibility beyond this is Dependency Intelligence
/// (M2.6).
final class PubspecLockExtractor implements EvidenceExtractor {
  static const _path = 'pubspec.lock';

  @override
  String get id => 'pubspec-lock';

  @override
  bool appliesTo(EvidenceFiles files) => files.contains(_path);

  @override
  ProjectEvidence extract(EvidenceFiles files) {
    try {
      final yaml = loadYaml(files[_path]!);
      if (yaml is! YamlMap) return ProjectEvidence();
      final sdks = yaml['sdks'];
      final dart = sdks is YamlMap ? sdks['dart'] : null;
      if (dart == null) return ProjectEvidence();
      final constraint = VersionConstraintX.parse(dart.toString());
      if (constraint.isAny) return ProjectEvidence();
      return ProjectEvidence(
        hard: [
          ConstraintEvidence(
            source: EvidenceSource.pubspecLock,
            kind: ConstraintKind.dart,
            constraint: constraint,
            origin: '$_path sdks.dart',
          ),
        ],
      );
    } on YamlException catch (e) {
      return ProjectEvidence(
        warnings: [
          ScanWarning(
            code: 'malformed-yaml',
            message: e.message,
            origin: _path,
          ),
        ],
      );
    } on FormatException catch (e) {
      return ProjectEvidence(
        warnings: [
          ScanWarning(
            code: 'bad-constraint',
            message: 'sdks.dart: ${e.message}',
            origin: _path,
          ),
        ],
      );
    }
  }
}
