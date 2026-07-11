import 'package:flutterx_domain/src/entities/artifact_ref.dart';
import 'package:flutterx_domain/src/values/channel.dart';
import 'package:flutterx_domain/src/values/sem_ver.dart';
import 'package:flutterx_domain/src/values/target_os.dart';

/// A known Flutter release and its properties (docs/03 §1.1).
///
/// The [dartVersion] mapping is the single most important fact here: pubspec
/// constraints are written against Dart, users think in Flutter versions,
/// and the solver translates through this field.
final class FlutterRelease {
  const FlutterRelease({
    required this.version,
    required this.channel,
    required this.gitTag,
    required this.frameworkSha,
    required this.dartVersion,
    required this.releasedAt,
    required this.artifacts,
    this.retracted = false,
    this.retractionReason,
  });

  final SemVer version;
  final Channel channel;

  /// The git tag in flutter/flutter (usually the version string).
  final String gitTag;

  /// Framework commit hash the tag points at.
  final String frameworkSha;

  /// The Dart SDK bundled with this release.
  final SemVer dartVersion;

  final DateTime releasedAt;

  /// Per-OS artifact archives (engine/Dart) with content hashes.
  final Map<TargetOs, ArtifactRef> artifacts;

  /// Known-bad release: excluded by the default `deny-retracted` rule,
  /// installable only with `--force` (docs/03 §1.2).
  final bool retracted;

  /// Why the release was retracted, when known — shown by the deny
  /// explanation.
  final String? retractionReason;

  @override
  bool operator ==(Object other) =>
      other is FlutterRelease &&
      version == other.version &&
      channel == other.channel;

  @override
  int get hashCode => Object.hash(version, channel);

  @override
  String toString() => 'Flutter $version ($channel, Dart $dartVersion)';
}
