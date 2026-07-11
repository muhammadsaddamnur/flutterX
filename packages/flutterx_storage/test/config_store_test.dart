import 'dart:io';

import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late FileConfigStore config;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_config_');
    config = FileConfigStore(configFilePath: p.join(tmp.path, 'config.yaml'));
  });

  tearDown(() => tmp.delete(recursive: true));

  test('set / get / list / unset round-trip through the file', () async {
    expect((await config.set('channel.default', 'stable')).isOk, isTrue);
    expect((await config.set('gc.keepOrphansDays', '14')).isOk, isTrue);
    expect(await config.get('channel.default'), 'stable');
    expect(await config.list(), {
      'channel.default': 'stable',
      'gc.keepOrphansDays': '14',
    });
    expect((await config.unset('channel.default')).isOk, isTrue);
    expect(await config.get('channel.default'), isNull);

    // The file itself is valid, hand-editable YAML with sorted keys.
    final raw = File(p.join(tmp.path, 'config.yaml')).readAsStringSync();
    expect(raw, contains('gc.keepOrphansDays: 14'));
  });

  test('invalid keys are rejected with FX-CONF-001', () async {
    final result = await config.set('bad key', 'x');
    expect(result.failureOrNull?.code, 'FX-CONF-001');
  });

  test('missing or torn config behaves as empty', () async {
    expect(await config.list(), isEmpty);
    File(p.join(tmp.path, 'config.yaml')).writeAsStringSync('{{{{');
    expect(await config.list(), isEmpty);
    expect(
      (await config.set('a.b', 'c')).isOk,
      isTrue,
      reason: 'set rewrites cleanly over a torn file',
    );
  });
}
