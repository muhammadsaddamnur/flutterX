import 'package:flutterx_domain/flutterx_domain.dart';

/// CI configuration hints (docs/03 §2.1 source 9): exact Flutter versions
/// pinned in GitHub Actions (`flutter-version: '3.19.6'`, e.g.
/// subosito/flutter-action) and Codemagic (`flutter: 3.19.6`).
///
/// Pattern-based over the YAML text: CI files are arbitrarily shaped, and
/// hints are soft — a missed match costs a hint, never correctness.
/// Channel values (`flutter: stable`) are not version hints and are
/// skipped.
final class CiWorkflowExtractor implements EvidenceExtractor {
  static final _patterns = [
    RegExp(r'''flutter[-_]version:\s*['"]?v?(\d+\.\d+\.\d+[^\s'"]*)'''),
    RegExp(r'''\bflutter:\s*['"]?v?(\d+\.\d+\.\d+[^\s'"]*)'''),
  ];

  @override
  String get id => 'ci-workflow';

  bool _isCiFile(String path) =>
      path.startsWith('.github/workflows/') || path == 'codemagic.yaml';

  @override
  bool appliesTo(EvidenceFiles files) => files.files.keys.any(_isCiFile);

  @override
  ProjectEvidence extract(EvidenceFiles files) {
    final hints = <HintEvidence>[];
    final seen = <String>{};
    for (final entry in files.files.entries) {
      if (!_isCiFile(entry.key)) continue;
      for (final pattern in _patterns) {
        for (final match in pattern.allMatches(entry.value)) {
          final raw = match.group(1)!;
          final SemVer version;
          try {
            version = SemVer.parse(raw);
          } on FormatException {
            continue; // soft source — skip, never warn on odd matches
          }
          if (!seen.add('$version@${entry.key}')) continue;
          hints.add(
            HintEvidence(
              source: EvidenceSource.ciWorkflow,
              version: version,
              origin: entry.key,
              exactPatch: true,
            ),
          );
        }
      }
    }
    return ProjectEvidence(hints: hints);
  }
}
