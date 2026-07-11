import 'dart:convert';

import 'package:flutterx_domain/flutterx_domain.dart';

/// FVM pin migration (docs/03 §2.1 source 3): reads `.fvmrc` (modern FVM,
/// JSON `{"flutter": "3.22.2"}`) and the legacy `.fvm/fvm_config.json`
/// (`{"flutterSdkVersion": "3.22.2"}`).
final class FvmExtractor implements EvidenceExtractor {
  @override
  String get id => 'fvm';

  @override
  bool appliesTo(EvidenceFiles files) =>
      files.contains('.fvmrc') || files.contains('.fvm/fvm_config.json');

  @override
  ProjectEvidence extract(EvidenceFiles files) {
    final pins = <PinEvidence>[];
    final warnings = <ScanWarning>[];

    void tryParse(String path, String versionKey) {
      final content = files[path];
      if (content == null) return;
      try {
        final json = jsonDecode(content) as Map<String, Object?>;
        final raw = json[versionKey];
        if (raw is! String) {
          warnings.add(
            ScanWarning(
              code: 'fvm-config-unreadable',
              message: 'no "$versionKey" entry found',
              origin: path,
            ),
          );
          return;
        }
        pins.add(
          PinEvidence(
            source: EvidenceSource.fvmConfig,
            version: SemVer.parse(raw),
            origin: path,
          ),
        );
      } on FormatException catch (e) {
        // Fail soft (docs/03 §2.3): a broken config is a warning, never a
        // crash.
        warnings.add(
          ScanWarning(
            code: 'fvm-config-unreadable',
            message: e.message,
            origin: path,
          ),
        );
      }
    }

    tryParse('.fvmrc', 'flutter');
    if (pins.isEmpty) {
      tryParse('.fvm/fvm_config.json', 'flutterSdkVersion');
    }
    return ProjectEvidence(pins: pins, warnings: warnings);
  }
}
