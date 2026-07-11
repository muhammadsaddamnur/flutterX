import 'package:flutterx_domain/src/result.dart';

/// Global user configuration, dot-notation keys over
/// `~/.flutterx/config.yaml` (docs/04 §3.14) — implemented in
/// `flutterx_storage`.
abstract interface class ConfigPort {
  Future<String?> get(String key);
  Future<Result<void>> set(String key, String value);
  Future<Result<void>> unset(String key);

  /// All keys, sorted.
  Future<Map<String, String>> list();
}
