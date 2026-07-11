import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Channel.tryParse', () {
    test('parses all four channels', () {
      expect(Channel.tryParse('stable'), Channel.stable);
      expect(Channel.tryParse('beta'), Channel.beta);
      expect(Channel.tryParse('dev'), Channel.dev);
      expect(Channel.tryParse('master'), Channel.master);
    });

    test('is case- and whitespace-tolerant', () {
      expect(Channel.tryParse(' Stable '), Channel.stable);
      expect(Channel.tryParse('BETA'), Channel.beta);
    });

    test('returns null for unknown names', () {
      expect(Channel.tryParse('nightly'), isNull);
      expect(Channel.tryParse(''), isNull);
      expect(Channel.tryParse('3.22.2'), isNull);
    });
  });
}
