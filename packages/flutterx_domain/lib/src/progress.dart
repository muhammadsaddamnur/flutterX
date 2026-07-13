/// One update from a long-running store operation (docs/04 §3.1 example
/// output: "Fetching tag…", "Linking artifacts…").
///
/// Emitted by the application/infrastructure layers, rendered by the
/// presentation layer. Keeping it a plain value keeps the engines
/// unaware of how progress is displayed.
final class ProgressEvent {
  const ProgressEvent({
    required this.phase,
    required this.message,
    this.fraction,
    this.done = false,
  }) : assert(
         fraction == null || (fraction >= 0 && fraction <= 1),
         'fraction is a 0..1 ratio',
       );

  /// Stable phase id: `fetch`, `checkout`, `download`, `link`, `stamp`,
  /// `manifest`. Lets the renderer group and label consistently.
  final String phase;

  /// Human-readable status line.
  final String message;

  /// Completion ratio in `[0, 1]` when measurable; `null` for
  /// indeterminate work (a spinner, not a bar).
  final double? fraction;

  /// Marks the phase finished — the renderer can tick it off.
  final bool done;
}

/// Sink the store operations report progress into (docs/06 §2.1). Injected
/// from the composition root; a no-op default keeps non-interactive and
/// test call sites clean.
typedef ProgressReporter = void Function(ProgressEvent event);

/// The shared no-op reporter — the default everywhere a reporter is
/// optional.
void noProgress(ProgressEvent _) {}
