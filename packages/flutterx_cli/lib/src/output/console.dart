import 'dart:convert';

import 'package:flutterx_domain/flutterx_domain.dart';

/// Where command output goes. The CLI writes through this seam so tests
/// capture output verbatim (golden tests, docs/06 §10).
final class Console {
  Console({
    required this.write,
    required this.writeError,
    this.color = true,
    this.json = false,
  });

  final void Function(String line) write;
  final void Function(String line) writeError;
  final bool color;

  /// `--json` mode: [emitJson] is the only output (docs/06 §9 envelope).
  final bool json;

  String _paint(String code, String text) =>
      color ? '\x1B[${code}m$text\x1B[0m' : text;

  void success(String message) => write('${_paint('32', '✓')} $message');
  void info(String message) => write('${_paint('36', 'ℹ')} $message');
  void warn(String message) => write('${_paint('33', '⚠')} $message');
  void step(String message) => write('${_paint('90', '→')} $message');

  /// The documented error format (docs/04 §1.3): stable code, one-line
  /// cause, concrete next actions.
  void failure(FxFailure failure) {
    writeError('${_paint('31', '✗')} ${failure.code}: ${failure.message}');
    for (final detail in failure.details) {
      writeError('    $detail');
    }
    for (final action in failure.nextActions) {
      writeError('  → $action');
    }
  }

  /// Versioned machine-readable envelope (docs/06 §9) — a public contract
  /// for CI scripts.
  void emitJson({required bool ok, Object? data, FxFailure? error}) {
    write(
      jsonEncode({
        'apiVersion': 1,
        'ok': ok,
        'data': ?data,
        if (error != null)
          'error': {
            'code': error.code,
            'message': error.message,
            'details': error.details,
            'nextActions': error.nextActions,
          },
      }),
    );
  }

  /// Left-aligned column layout for `list`-style output.
  void table(List<List<String>> rows) {
    if (rows.isEmpty) return;
    final widths = List<int>.filled(rows.first.length, 0);
    for (final row in rows) {
      for (var i = 0; i < row.length; i++) {
        if (row[i].length > widths[i]) widths[i] = row[i].length;
      }
    }
    for (final row in rows) {
      write(
        [
          for (var i = 0; i < row.length; i++) row[i].padRight(widths[i]),
        ].join('  ').trimRight(),
      );
    }
  }
}
