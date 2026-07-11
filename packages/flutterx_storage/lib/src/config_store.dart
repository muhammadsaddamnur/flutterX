import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:yaml/yaml.dart';

/// [ConfigPort] over `~/.flutterx/config.yaml` (docs/04 §3.14).
///
/// The file is a flat map of dot-notation keys to scalar values — trivially
/// hand-editable, order-stable (keys sorted on write).
final class FileConfigStore implements ConfigPort {
  FileConfigStore({required this.configFilePath});

  final String configFilePath;

  @override
  Future<String?> get(String key) async => (await list())[key];

  @override
  Future<Result<void>> set(String key, String value) async {
    if (key.isEmpty || key.contains(RegExp(r'[\s:]'))) {
      return Result.err(
        StorageFailure(
          code: 'FX-CONF-001',
          message: 'invalid config key "$key" (dot notation, no spaces)',
          nextActions: const [
            'example: flutterx config set channel.default stable',
          ],
        ),
      );
    }
    final entries = await list();
    entries[key] = value;
    await _write(entries);
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> unset(String key) async {
    final entries = await list();
    entries.remove(key);
    await _write(entries);
    return const Result.ok(null);
  }

  @override
  Future<Map<String, String>> list() async {
    final file = File(configFilePath);
    if (!file.existsSync()) return {};
    try {
      final yaml = loadYaml(await file.readAsString());
      if (yaml is! YamlMap) return {};
      return {
        for (final entry in yaml.entries)
          entry.key.toString(): entry.value.toString(),
      };
    } on Exception {
      return {}; // torn config → behave as empty; set() rewrites cleanly
    }
  }

  Future<void> _write(Map<String, String> entries) async {
    final file = File(configFilePath);
    await file.parent.create(recursive: true);
    final keys = entries.keys.toList()..sort();
    final buffer = StringBuffer()
      ..writeln(
        '# FlutterX global config — flat dot-notation keys '
        '(docs/04 §3.14).',
      );
    for (final key in keys) {
      buffer.writeln('$key: ${entries[key]}');
    }
    await file.writeAsString(buffer.toString());
  }
}
