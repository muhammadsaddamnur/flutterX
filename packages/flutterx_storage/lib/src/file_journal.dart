import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// File-backed [Journal] (docs/05 §7): one JSON file per mutating
/// operation under `journal/`, written before acting, committed after.
final class FileJournal implements Journal {
  FileJournal({required this.journalDir, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final String journalDir;
  final DateTime Function() _clock;

  @override
  Future<Result<JournalEntry>> begin({
    required String operation,
    required String target,
    required List<String> stepIds,
  }) async {
    await Directory(journalDir).create(recursive: true);
    final now = _clock().toUtc();
    // Filesystem-safe timestamp (no ':' — Windows, docs/05 §8). Keeps
    // microseconds so rapid same-target operations never collide.
    final stamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final safeTarget = target.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File(p.join(journalDir, '$stamp-$operation-$safeTarget.json'));
    final entry = FileJournalEntry._(
      file: file,
      operation: operation,
      target: target,
      startedAt: now,
      stepIds: stepIds,
    );
    await entry._flush();
    return Result.ok(entry);
  }

  @override
  Future<List<JournalEntry>> uncommitted() async {
    final dir = Directory(journalDir);
    if (!dir.existsSync()) return [];
    final entries = <JournalEntry>[];
    await for (final file in dir.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final entry = await FileJournalEntry.load(file);
      if (entry != null && !entry.committed) entries.add(entry);
    }
    return entries;
  }

  /// Removes committed entries older than [maxAge] (default 30 days,
  /// docs/05 §7). Uncommitted entries are never pruned — they are FX-R08
  /// evidence.
  Future<int> prune({Duration maxAge = const Duration(days: 30)}) async {
    final dir = Directory(journalDir);
    if (!dir.existsSync()) return 0;
    final cutoff = _clock().toUtc().subtract(maxAge);
    var pruned = 0;
    await for (final file in dir.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final entry = await FileJournalEntry.load(file);
      if (entry == null) continue;
      if (entry.committed && entry.startedAt.isBefore(cutoff)) {
        await file.delete();
        pruned++;
      }
    }
    return pruned;
  }
}

final class FileJournalEntry implements JournalEntry {
  FileJournalEntry._({
    required this.file,
    required this.operation,
    required this.target,
    required this.startedAt,
    required List<String> stepIds,
    Map<String, String>? stepStates,
    Map<String, String>? stepDetails,
    this.committed = false,
  }) : _stepIds = stepIds,
       _stepStates = stepStates ?? {for (final id in stepIds) id: 'pending'},
       _stepDetails = stepDetails ?? {};

  final File file;
  @override
  final String operation;
  @override
  final String target;
  final DateTime startedAt;
  final List<String> _stepIds;
  final Map<String, String> _stepStates;
  final Map<String, String> _stepDetails;
  bool committed;

  String? stateOf(String stepId) => _stepStates[stepId];

  @override
  Future<void> stepStarted(String stepId, {String? detail}) async {
    _stepStates[stepId] = 'in-progress';
    if (detail != null) _stepDetails[stepId] = detail;
    await _flush();
  }

  @override
  Future<void> stepDone(String stepId) async {
    _stepStates[stepId] = 'done';
    await _flush();
  }

  @override
  Future<void> commit() async {
    committed = true;
    await _flush();
  }

  Future<void> _flush() => file.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'op': operation,
      'target': target,
      'startedAt': startedAt.toIso8601String(),
      'steps': [
        for (final id in _stepIds)
          {
            'id': id,
            'state': _stepStates[id],
            if (_stepDetails[id] != null) 'detail': _stepDetails[id],
          },
      ],
      'committed': committed,
    }),
  );

  static Future<FileJournalEntry?> load(File file) async {
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final steps = (json['steps']! as List<Object?>)
          .cast<Map<String, Object?>>();
      return FileJournalEntry._(
        file: file,
        operation: json['op']! as String,
        target: json['target']! as String,
        startedAt: DateTime.parse(json['startedAt']! as String),
        stepIds: [for (final s in steps) s['id']! as String],
        stepStates: {
          for (final s in steps) s['id']! as String: s['state']! as String,
        },
        stepDetails: {
          for (final s in steps)
            if (s['detail'] != null) s['id']! as String: s['detail']! as String,
        },
        committed: json['committed']! as bool,
      );
    } on Exception {
      // A torn journal file is itself crash evidence; doctor surfaces it.
      return null;
    }
  }
}
