import 'package:flutterx_domain/flutterx_domain.dart';

/// `flutterx config get|set|unset|list` (docs/04 §3.14). Thin by design —
/// validation and persistence live behind [ConfigPort].
final class ManageConfig {
  ManageConfig(this._config);

  final ConfigPort _config;

  Future<String?> get(String key) => _config.get(key);
  Future<Result<void>> set(String key, String value) => _config.set(key, value);
  Future<Result<void>> unset(String key) => _config.unset(key);
  Future<Map<String, String>> list() => _config.list();
}
