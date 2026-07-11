import 'package:flutterx_domain/flutterx_domain.dart';

/// The strongest evidence source (docs/03 §2.1 source 1): FlutterX's own
/// prior decision in `.flutterx/resolution.lock`. Flat contract format
/// (docs/03 §7) — line-parsed.
final class ResolutionLockExtractor implements EvidenceExtractor {
  static const _path = '.flutterx/resolution.lock';

  @override
  String get id => 'resolution-lock';

  @override
  bool appliesTo(EvidenceFiles files) => files.contains(_path);

  @override
  ProjectEvidence extract(EvidenceFiles files) {
    for (final line in files[_path]!.split('\n')) {
      final match = RegExp(r'^flutter:\s*(\S+)$').firstMatch(line.trim());
      if (match == null) continue;
      try {
        return ProjectEvidence(
          pins: [
            PinEvidence(
              source: EvidenceSource.resolutionLock,
              version: SemVer.parse(match.group(1)!),
              origin: _path,
            ),
          ],
        );
      } on FormatException {
        break;
      }
    }
    return ProjectEvidence(
      warnings: const [
        ScanWarning(
          code: 'lock-unreadable',
          message: 'no parseable flutter version — treat as unresolved',
          origin: _path,
        ),
      ],
    );
  }
}
