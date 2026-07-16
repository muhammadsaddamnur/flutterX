import 'package:flutterx_cli/flutterx_cli.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

void main() {
  group('ProgressRenderer (interactive TTY)', () {
    late List<String> raw;
    late ProgressRenderer renderer;

    setUp(() {
      raw = [];
      renderer = ProgressRenderer(
        writeRaw: raw.add,
        interactive: true,
        color: false,
      );
    });

    // Every event starts the idle-animation timer; never leak it.
    tearDown(() => renderer.finish());

    test('renders a spinner + message, overwriting in place with CR', () {
      renderer(const ProgressEvent(phase: 'download', message: 'fetching…'));
      expect(raw.single, startsWith('\r\x1B[2K'));
      expect(raw.single, contains('fetching…'));
    });

    test('draws a bar and percentage when a fraction is known', () {
      renderer(
        const ProgressEvent(
          phase: 'download',
          message: 'downloading',
          fraction: 0.5,
        ),
      );
      expect(raw.single, contains('50%'));
      expect(raw.single, contains('█'));
      expect(raw.single, contains('░'));
    });

    test('finish clears the live line', () {
      renderer(const ProgressEvent(phase: 'x', message: 'work'));
      renderer.finish();
      expect(raw.last, '\r\x1B[2K');
    });

    test('the spinner keeps animating between events (idle timer)', () async {
      renderer(const ProgressEvent(phase: 'fetch', message: 'fetching…'));
      final framesAtEvent = raw.length;
      // No further events — the timer alone must keep redrawing so a
      // long silent operation never looks stuck. Deadline-based rather
      // than a fixed window: CI runners stall unpredictably.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (raw.length < framesAtEvent + 2 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      renderer.finish();
      expect(
        raw.length,
        greaterThanOrEqualTo(framesAtEvent + 2),
        reason: 'idle timer never redrew',
      );
      expect(raw[framesAtEvent], contains('fetching…'));
      // And the animation stops with finish.
      final framesAtFinish = raw.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(raw.length, framesAtFinish);
    });

    test('a done event clears the line (terminal handoff)', () {
      renderer(const ProgressEvent(phase: 'link', message: 'linking…'));
      renderer(const ProgressEvent(phase: 'pub-get', message: '', done: true));
      expect(raw.last, '\r\x1B[2K');
    });

    test('finish is idempotent', () {
      renderer(const ProgressEvent(phase: 'x', message: 'work'));
      renderer.finish();
      final frames = raw.length;
      renderer.finish();
      expect(raw.length, frames, reason: 'second finish writes nothing');
    });
  });

  group('ProgressRenderer (non-interactive)', () {
    test('emits one plain line per phase change, no CR spam', () {
      final raw = <String>[];
      final renderer = ProgressRenderer(writeRaw: raw.add, interactive: false);
      renderer(const ProgressEvent(phase: 'download', message: 'fetching…'));
      renderer(
        const ProgressEvent(
          phase: 'download',
          message: 'downloading 40%',
          fraction: 0.4,
        ),
      );
      renderer(const ProgressEvent(phase: 'checkout', message: 'checking out'));

      expect(raw, ['  fetching…\n', '  checking out\n']);
      expect(raw.every((line) => !line.contains('\r')), isTrue);
    });
  });
}
