import 'package:flutterx_git/flutterx_git.dart';
import 'package:test/test.dart';

void main() {
  group('parseGitProgressLine', () {
    test('parses "Receiving objects" with byte/rate tail', () {
      final event = parseGitProgressLine(
        'Receiving objects:  45% (5000/11000), 12.50 MiB | 3.20 MiB/s',
        phase: 'download',
      )!;
      expect(event.phase, 'download');
      expect(event.fraction, closeTo(0.45, 1e-9));
      expect(event.message, contains('downloading'));
      expect(event.message, contains('12.50 MiB'));
    });

    test('parses "Resolving deltas" without a tail', () {
      final event = parseGitProgressLine(
        'Resolving deltas:  80% (6400/8000)',
        phase: 'download',
      )!;
      expect(event.fraction, closeTo(0.80, 1e-9));
      expect(event.message, 'resolving 80%');
    });

    test('parses checkout "Updating files"', () {
      final event = parseGitProgressLine(
        'Updating files:  60% (300/500)',
        phase: 'checkout',
      )!;
      expect(event.phase, 'checkout');
      expect(event.message, contains('checking out'));
    });

    test('handles a trailing carriage return / whitespace', () {
      expect(
        parseGitProgressLine('Counting objects: 100% (123/123)\r', phase: 'x'),
        isNotNull,
      );
    });

    test('returns null for non-progress lines', () {
      for (final line in [
        'remote: Enumerating objects: 123, done.',
        'From https://github.com/flutter/flutter',
        ' * [new tag]  3.22.2  -> 3.22.2',
        '',
      ]) {
        expect(parseGitProgressLine(line, phase: 'x'), isNull, reason: line);
      }
    });
  });
}
