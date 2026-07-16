/// Which way FX-R08 resolves an interrupted operation (docs/05 §7).
enum RecoveryDirection {
  /// Finish the remaining steps — the operation's steps are individually
  /// idempotent, so completing is always safe.
  rollForward,

  /// Undo what was started — restore the pre-operation state.
  rollBack,
}

/// The explicit per-operation recovery policy table (docs/05 §7): repair
/// rolls **forward** for `install`/`gc` (finish the steps) and **backward**
/// for `remove` gone wrong (restore what was being deleted).
///
/// Unknown operations default to roll-forward — every journaled operation
/// is built from idempotent steps, so completing is the safe direction.
RecoveryDirection recoveryDirectionFor(String operation) => switch (operation) {
  'remove' => RecoveryDirection.rollBack,
  _ => RecoveryDirection.rollForward,
};
