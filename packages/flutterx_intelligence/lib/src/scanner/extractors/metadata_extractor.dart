import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:yaml/yaml.dart';

/// `.metadata` evidence (docs/03 §2.1 source 8).
///
/// Reality check vs the design: the file records the *framework revision*
/// and channel that created the project — not a version number — plus
/// `project_type`. The revision→version join needs the registry, which the
/// pure scanner does not have; the application layer can enrich later
/// (noted in docs/09 T2.1.2). What the scanner extracts today is the
/// reliable `project_type` classification.
final class MetadataExtractor implements EvidenceExtractor {
  static const _path = '.metadata';

  @override
  String get id => 'metadata';

  @override
  bool appliesTo(EvidenceFiles files) => files.contains(_path);

  @override
  ProjectEvidence extract(EvidenceFiles files) {
    try {
      final yaml = loadYaml(files[_path]!);
      if (yaml is! YamlMap) return ProjectEvidence();
      return ProjectEvidence(kind: _kind(yaml['project_type']?.toString()));
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
    }
  }

  static ProjectKind _kind(String? projectType) => switch (projectType) {
    'app' => ProjectKind.app,
    'package' => ProjectKind.package,
    'plugin' || 'plugin_ffi' => ProjectKind.plugin,
    _ => ProjectKind.unknown,
  };
}
