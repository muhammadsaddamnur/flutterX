/// A downloadable artifact belonging to a release: archive URL plus content
/// hash (docs/03 §1.1, docs/05 §5).
///
/// The sha256 doubles as the artifact's address in the content-addressed
/// store — integrity verification is free (docs/02 ADR-3).
final class ArtifactRef {
  const ArtifactRef({required this.url, required this.sha256});

  final Uri url;

  /// Lowercase hex sha256 of the archive content.
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is ArtifactRef && url == other.url && sha256 == other.sha256;

  @override
  int get hashCode => Object.hash(url, sha256);

  @override
  String toString() =>
      'ArtifactRef(${url.pathSegments.lastOrNull}, '
      '${sha256.substring(0, 8)}…)';
}
