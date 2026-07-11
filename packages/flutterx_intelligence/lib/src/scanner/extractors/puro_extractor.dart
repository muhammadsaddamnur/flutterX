import 'dart:convert';

import 'package:flutterx_domain/flutterx_domain.dart';

/// Puro pin migration (docs/03 §2.1 source 4): `.puro.json` references an
/// environment by name (`{"env": "3.22.2"}`). Envs are commonly named
/// after their Flutter version; a non-version env name cannot be migrated
/// automatically and becomes a warning instead.
final class PuroExtractor implements EvidenceExtractor {
  @override
  String get id => 'puro';

  @override
  bool appliesTo(EvidenceFiles files) => files.contains('.puro.json');

  @override
  ProjectEvidence extract(EvidenceFiles files) {
    const path = '.puro.json';
    try {
      final json = jsonDecode(files[path]!) as Map<String, Object?>;
      final env = json['env'];
      if (env is! String || env.isEmpty) {
        return ProjectEvidence(
          warnings: const [
            ScanWarning(
              code: 'puro-config-unreadable',
              message: 'no "env" entry found',
              origin: path,
            ),
          ],
        );
      }
      try {
        return ProjectEvidence(
          pins: [
            PinEvidence(
              source: EvidenceSource.puroConfig,
              version: SemVer.parse(env),
              origin: path,
            ),
          ],
        );
      } on FormatException {
        return ProjectEvidence(
          warnings: [
            ScanWarning(
              code: 'puro-env-not-a-version',
              message:
                  'puro env "$env" is not a version — '
                  'pin manually with `flutterx use <version>`',
              origin: path,
            ),
          ],
        );
      }
    } on FormatException catch (e) {
      return ProjectEvidence(
        warnings: [
          ScanWarning(
            code: 'puro-config-unreadable',
            message: e.message,
            origin: path,
          ),
        ],
      );
    }
  }
}
