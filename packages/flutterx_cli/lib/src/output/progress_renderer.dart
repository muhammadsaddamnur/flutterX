import 'dart:async';

import 'package:flutterx_domain/flutterx_domain.dart';

/// Renders [ProgressEvent]s as a live status line (docs/04 §3.1 spinner
/// output). Writes to stderr so stdout / `--json` stays clean.
///
/// On a TTY: a single line, updated in place (spinner + message + bar).
/// The spinner keeps animating between events on a timer, so long silent
/// operations (network fetches, hashing, `pub get --dry-run`) never look
/// stuck. Non-interactive (piped/CI): one plain line per phase transition
/// — no carriage-return spam in logs.
final class ProgressRenderer {
  ProgressRenderer({
    required this.writeRaw,
    required this.interactive,
    this.color = true,
  });

  /// Raw stderr writer — no trailing newline (the renderer controls
  /// line breaks and carriage returns itself).
  final void Function(String text) writeRaw;
  final bool interactive;
  final bool color;

  static const _spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  var _tick = 0;
  var _lastPhase = '';
  var _active = false;
  ProgressEvent? _current;
  Timer? _timer;

  /// The [ProgressReporter] to hand to the use case.
  void call(ProgressEvent event) {
    if (!interactive) {
      // Only announce phase changes; skip the noisy per-percent updates.
      if (event.phase != _lastPhase && !event.done) {
        writeRaw('  ${event.message}\n');
        _lastPhase = event.phase;
      }
      return;
    }

    // A done event clears the line — used before handing the terminal to
    // a child process (pub get, shells) so outputs don't collide.
    if (event.done) {
      finish();
      return;
    }

    _current = event;
    _render();
    // Keep the spinner alive between events; cancelled by [finish].
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _render(),
    );
  }

  void _render() {
    final event = _current;
    if (event == null) return;
    _active = true;
    final spin = _dim(_spinner[_tick++ % _spinner.length]);
    final bar = event.fraction == null
        ? ''
        : ' ${_bar(event.fraction!)} ${(event.fraction! * 100).round()}%';
    // CR + clear-to-end-of-line, then the fresh status.
    writeRaw('\r\x1B[2K$spin ${event.message}$bar');
  }

  /// Clears the live line and stops the animation timer — call once the
  /// operation finishes, before printing the final result. Idempotent.
  void finish() {
    _timer?.cancel();
    _timer = null;
    _current = null;
    if (_active && interactive) writeRaw('\r\x1B[2K');
    _active = false;
  }

  String _bar(double fraction) {
    const width = 20;
    final filled = (fraction.clamp(0, 1) * width).round();
    return '[${'█' * filled}${'░' * (width - filled)}]';
  }

  String _dim(String text) => color ? '\x1B[90m$text\x1B[0m' : text;
}
