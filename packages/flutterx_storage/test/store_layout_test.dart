import 'dart:convert';
import 'dart:io';

import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late StoreLayout layout;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_layout_');
    layout = StoreLayout(tmp.path);
  });

  tearDown(() => tmp.delete(recursive: true));

  test('init creates the documented skeleton and a fresh state.json', () async {
    final result = await layout.init();
    expect(result.isOk, isTrue);
    for (final dir in [
      layout.binDir,
      layout.downloadsDir,
      layout.versionsDir,
      layout.artifactsDir,
      layout.locksDir,
      layout.journalDir,
      layout.logsDir,
    ]) {
      expect(Directory(dir).existsSync(), isTrue, reason: dir);
    }
    expect(result.valueOrNull!.schemaVersion, storeSchemaVersion);
    expect(File(layout.stateFile).existsSync(), isTrue);
  });

  test('init is idempotent and preserves existing state', () async {
    await layout.init();
    await layout.saveState(
      StoreState(
        projects: const [ProjectRef(path: '/work/app', version: '3.22.2')],
      ),
    );
    final again = await layout.init();
    expect(again.valueOrNull!.projects, hasLength(1));
  });

  test('refuses a store written by a newer FlutterX (docs/05 §10)', () async {
    await layout.init();
    await File(layout.stateFile).writeAsString(
      jsonEncode({
        'schemaVersion': storeSchemaVersion + 1,
        'projects': <Object?>[],
      }),
    );
    final result = await layout.loadState();
    expect(result.failureOrNull?.code, 'FX-STORE-003');
    expect(result.failureOrNull?.nextActions, contains('upgrade FlutterX'));
  });

  test('withProject upserts by path', () async {
    final state = StoreState()
        .withProject(const ProjectRef(path: '/a', version: '3.19.6'))
        .withProject(const ProjectRef(path: '/b', version: '3.22.2'))
        .withProject(const ProjectRef(path: '/a', version: '3.22.2'));
    expect(state.projects, hasLength(2));
    expect(state.projects.firstWhere((r) => r.path == '/a').version, '3.22.2');
  });

  test('CAS paths shard by lowercase prefix (docs/05 §8)', () {
    const sha =
        'ABCDEF1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
    // Separator-agnostic (Windows CI runs this too).
    expect(layout.casEntryDir(sha), contains(p.join('ab', sha.toLowerCase())));
    expect(layout.casPayload(sha), endsWith('payload'));
  });
}
