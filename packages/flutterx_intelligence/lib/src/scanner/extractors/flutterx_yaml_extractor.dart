import 'package:flutterx_domain/flutterx_domain.dart';

/// FlutterX's own intent file (docs/03 §2.1 source 2): `flutterx.yaml`
/// with either `flutter: <version>` (exact pin) or `policy: <channel>`.
///
/// The file is flat by contract (written by `flutterx use`, docs/04 §3.3),
/// so it is parsed line-wise — no YAML dependency needed.
final class FlutterxYamlExtractor implements EvidenceExtractor {
  @override
  String get id => 'flutterx-yaml';

  @override
  bool appliesTo(EvidenceFiles files) => files.contains('flutterx.yaml');

  @override
  ProjectEvidence extract(EvidenceFiles files) {
    const path = 'flutterx.yaml';
    for (final line in files[path]!.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#') || trimmed.isEmpty) continue;
      final match = RegExp(r'^flutter:\s*(\S+)$').firstMatch(trimmed);
      if (match == null) continue;
      try {
        return ProjectEvidence(
          pins: [
            PinEvidence(
              source: EvidenceSource.flutterxYaml,
              version: SemVer.parse(match.group(1)!),
              origin: path,
            ),
          ],
        );
      } on FormatException {
        return ProjectEvidence(
          warnings: [
            ScanWarning(
              code: 'flutterx-yaml-unreadable',
              message: '"${match.group(1)}" is not a version',
              origin: path,
            ),
          ],
        );
      }
    }
    // A policy line (or nothing recognizable) is not a pin — the policy
    // path belongs to resolve (M2.3+).
    return ProjectEvidence();
  }
}
