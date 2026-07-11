import 'package:flutterx_domain/src/result.dart';

/// A crash-safe record of one mutating operation (docs/05 §7).
///
/// Usage contract: `begin` before acting; `step` around each ordered,
/// individually idempotent step; `commit` when done. An uncommitted entry
/// found later is diagnosis FX-R08 — `repair` rolls it forward or back per
/// the operation's recovery policy.
abstract interface class Journal {
  /// Opens a journal entry for [operation] (e.g. `install`) on [target]
  /// (e.g. `3.22.2`) with its ordered [stepIds] declared up front.
  Future<Result<JournalEntry>> begin({
    required String operation,
    required String target,
    required List<String> stepIds,
  });

  /// Entries that were begun but never committed (crash evidence).
  Future<List<JournalEntry>> uncommitted();
}

/// Handle to one open journal entry.
abstract interface class JournalEntry {
  String get operation;
  String get target;

  /// Marks [stepId] in progress, with optional progress [detail]
  /// (e.g. `2/4`).
  Future<void> stepStarted(String stepId, {String? detail});

  /// Marks [stepId] done.
  Future<void> stepDone(String stepId);

  /// Marks the whole operation complete; the entry is then eligible for
  /// pruning (30 days, docs/05 §7).
  Future<void> commit();
}
