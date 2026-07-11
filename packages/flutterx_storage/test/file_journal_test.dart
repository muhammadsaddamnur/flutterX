import 'dart:io';

import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late FileJournal journal;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_journal_');
    journal = FileJournal(journalDir: tmp.path);
  });

  tearDown(() => tmp.delete(recursive: true));

  test('begin → steps → commit lifecycle round-trips through disk', () async {
    final begun = await journal.begin(
      operation: 'install',
      target: '3.22.2',
      stepIds: const ['fetch-tag', 'artifacts'],
    );
    final entry = begun.valueOrNull! as FileJournalEntry;

    expect(await journal.uncommitted(), hasLength(1));
    await entry.stepStarted('fetch-tag');
    await entry.stepDone('fetch-tag');
    await entry.stepStarted('artifacts', detail: '2/4');
    await entry.stepDone('artifacts');
    await entry.commit();

    expect(await journal.uncommitted(), isEmpty);
    final reloaded = await FileJournalEntry.load(entry.file);
    expect(reloaded!.committed, isTrue);
    expect(reloaded.stateOf('artifacts'), 'done');
  });

  test(
    'an uncommitted entry survives as crash evidence (FX-R08 input)',
    () async {
      final begun = await journal.begin(
        operation: 'install',
        target: '3.19.6',
        stepIds: const ['fetch-tag'],
      );
      final entry = begun.valueOrNull! as FileJournalEntry;
      await entry.stepStarted('fetch-tag');
      // No commit — simulated crash.

      final found = await journal.uncommitted();
      expect(found, hasLength(1));
      expect(found.single.operation, 'install');
      expect(found.single.target, '3.19.6');
    },
  );

  test('rapid same-target operations get distinct journal files', () async {
    final a = await journal.begin(
      operation: 'install',
      target: '3.22.2',
      stepIds: const ['s'],
    );
    final b = await journal.begin(
      operation: 'install',
      target: '3.22.2',
      stepIds: const ['s'],
    );
    expect(
      (a.valueOrNull! as FileJournalEntry).file.path,
      isNot((b.valueOrNull! as FileJournalEntry).file.path),
    );
  });

  test('prune removes only old committed entries (docs/05 §7)', () async {
    var now = DateTime.utc(2026, 6, 1);
    final aged = FileJournal(journalDir: tmp.path, clock: () => now);

    final oldDone =
        (await aged.begin(
              operation: 'install',
              target: 'old-done',
              stepIds: const ['s'],
            )).valueOrNull!
            as FileJournalEntry;
    await oldDone.commit();
    final oldCrash = (await aged.begin(
      operation: 'install',
      target: 'old-crash',
      stepIds: const ['s'],
    )).valueOrNull!;

    now = DateTime.utc(2026, 7, 11); // 40 days later
    final fresh =
        (await aged.begin(
              operation: 'install',
              target: 'fresh',
              stepIds: const ['s'],
            )).valueOrNull!
            as FileJournalEntry;
    await fresh.commit();

    final pruned = await aged.prune();
    expect(pruned, 1, reason: 'only the old committed entry');
    final remaining = await aged.uncommitted();
    expect(
      remaining.single.target,
      oldCrash.target,
      reason: 'uncommitted entries are never pruned',
    );
    expect(File(fresh.file.path).existsSync(), isTrue);
  });
}
