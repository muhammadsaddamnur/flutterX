import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:yaml/yaml.dart';

/// pubspec evidence (docs/03 §2.1 sources 5–6): the `environment.sdk`
/// Dart constraint (the workhorse of solving) and the rare
/// `environment.flutter` constraint. Also classifies the project kind
/// (docs/03 §2.3): flutter dependency + `lib/main.dart` → app; flutter
/// dependency without an entry point → package; `flutter.plugin` → plugin.
final class PubspecExtractor implements EvidenceExtractor {
  static const _path = 'pubspec.yaml';

  @override
  String get id => 'pubspec';

  @override
  bool appliesTo(EvidenceFiles files) => files.contains(_path);

  @override
  ProjectEvidence extract(EvidenceFiles files) {
    final Object? yaml;
    try {
      yaml = loadYaml(files[_path]!);
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
    if (yaml is! YamlMap) return ProjectEvidence();

    final hard = <ConstraintEvidence>[];
    final warnings = <ScanWarning>[];
    final environment = yaml['environment'];
    if (environment is YamlMap) {
      void constraint(String key, ConstraintKind kind) {
        final raw = environment[key];
        if (raw == null) return;
        try {
          final parsed = VersionConstraintX.parse(raw.toString());
          // `any` contributes nothing — noted, not added (docs/03 §3.2).
          if (!parsed.isAny) {
            hard.add(
              ConstraintEvidence(
                source: kind == ConstraintKind.dart
                    ? EvidenceSource.pubspecSdkConstraint
                    : EvidenceSource.pubspecFlutterConstraint,
                kind: kind,
                constraint: parsed,
                origin: '$_path environment.$key',
              ),
            );
          }
        } on FormatException catch (e) {
          warnings.add(
            ScanWarning(
              code: 'bad-constraint',
              message: 'environment.$key: ${e.message}',
              origin: _path,
            ),
          );
        }
      }

      constraint('sdk', ConstraintKind.dart);
      constraint('flutter', ConstraintKind.flutter);
    }

    return ProjectEvidence(
      hard: hard,
      warnings: warnings,
      kind: _classify(yaml, files),
    );
  }

  static ProjectKind _classify(YamlMap pubspec, EvidenceFiles files) {
    final flutterSection = pubspec['flutter'];
    if (flutterSection is YamlMap && flutterSection.containsKey('plugin')) {
      return ProjectKind.plugin;
    }
    final dependencies = pubspec['dependencies'];
    final usesFlutter =
        dependencies is YamlMap && dependencies.containsKey('flutter');
    if (!usesFlutter) return ProjectKind.package;
    return files.contains('lib/main.dart')
        ? ProjectKind.app
        : ProjectKind.package;
  }
}
