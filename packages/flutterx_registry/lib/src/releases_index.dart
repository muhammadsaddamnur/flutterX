import 'dart:convert';

import 'package:flutterx_domain/flutterx_domain.dart';

/// Parses a Flutter `releases_<os>.json` index into a [RegistrySnapshot]
/// (docs/03 §1.1).
///
/// Tolerant parsing rules (docs/07 risk: "tolerant parsers"), derived from
/// the real index contents:
/// - Versions may carry a leading `v` (`v1.12.13+hotfix.9`) — stripped.
/// - Beta/dev `dart_sdk_version` values look like
///   `3.13.0 (build 3.13.0-167.1.beta)` — the precise build version wins.
/// - Entries without `dart_sdk_version` (pre-2020 history) are skipped:
///   without the Dart mapping they cannot participate in solving.
/// - Entries appear once per CPU arch — deduped preferring [preferredArch],
///   falling back to whichever appeared first.
/// - Unparseable entries are skipped, never fatal.
/// - `retracted` has no upstream source yet; a curated list can overlay
///   later.
/// `"3.13.0 (build 3.13.0-167.1.beta)"` → `3.13.0-167.1.beta`;
/// plain versions pass through.
String _normalizeDartVersion(String raw) {
  final build = RegExp(r'\(build ([^)]+)\)').firstMatch(raw);
  return build?.group(1) ?? raw.split(' ').first;
}

RegistrySnapshot parseReleasesIndex(
  String jsonBody, {
  required TargetOs os,
  required String preferredArch,
  required DateTime fetchedAt,
  required String source,
}) {
  final root = jsonDecode(jsonBody) as Map<String, Object?>;
  final baseUrl = root['base_url']! as String;
  final byKey = <String, ({FlutterRelease release, String arch})>{};

  for (final raw in root['releases']! as List<Object?>) {
    final entry = raw! as Map<String, Object?>;
    final dartVersion = entry['dart_sdk_version'] as String?;
    if (dartVersion == null) continue;

    final SemVer version;
    final SemVer dart;
    try {
      final rawVersion = entry['version']! as String;
      version = SemVer.parse(
        rawVersion.startsWith('v') ? rawVersion.substring(1) : rawVersion,
      );
      dart = SemVer.parse(_normalizeDartVersion(dartVersion));
    } on FormatException {
      continue;
    }
    final channel = Channel.tryParse(entry['channel']! as String);
    if (channel == null) continue;

    final sha256 = entry['sha256'] as String?;
    final archive = entry['archive'] as String?;
    final release = FlutterRelease(
      version: version,
      channel: channel,
      gitTag: entry['version']! as String,
      frameworkSha: entry['hash']! as String,
      dartVersion: dart,
      releasedAt:
          DateTime.tryParse(entry['release_date'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      artifacts: {
        if (sha256 != null && archive != null)
          os: ArtifactRef(url: Uri.parse('$baseUrl/$archive'), sha256: sha256),
      },
    );

    final key = '${version}_${channel.name}';
    final arch = entry['dart_sdk_arch'] as String? ?? '';
    final existing = byKey[key];
    if (existing == null || arch == preferredArch) {
      byKey[key] = (release: release, arch: arch);
    }
  }

  return RegistrySnapshot(
    releases: [for (final v in byKey.values) v.release],
    fetchedAt: fetchedAt,
    source: source,
  );
}
