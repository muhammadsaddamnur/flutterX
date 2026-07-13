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
