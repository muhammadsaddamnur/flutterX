/// Releases-index and pub.dev metadata clients with snapshot caching
/// (docs/03 §1, docs/06 §7).
///
/// This barrel is the package's only public entry point; everything under
/// `src/` is private (docs/06 §1).
library;

export 'src/http_registry.dart';
export 'src/releases_client.dart';
export 'src/releases_index.dart';
export 'src/snapshot_cache.dart';
