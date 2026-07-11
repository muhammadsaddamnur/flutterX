import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

void main() {
  const failure = StorageFailure(code: 'FX-STORE-002', message: 'disk full');

  group('Result construction and inspection', () {
    test('Ok exposes its value', () {
      const result = Result<int>.ok(42);
      expect(result.isOk, isTrue);
      expect(result.valueOrNull, 42);
      expect(result.failureOrNull, isNull);
    });

    test('Err exposes its failure', () {
      const result = Result<int>.err(failure);
      expect(result.isOk, isFalse);
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull, failure);
    });
  });

  group('Result.map', () {
    test('transforms Ok', () {
      expect(const Result<int>.ok(2).map((v) => v * 3).valueOrNull, 6);
    });

    test('passes Err through untouched', () {
      final mapped = const Result<int>.err(failure).map((v) => v * 3);
      expect(mapped.failureOrNull, failure);
    });
  });

  group('Result.flatMap', () {
    Result<int> half(int v) => v.isEven
        ? Result.ok(v ~/ 2)
        : const Result.err(
            StorageFailure(code: 'FX-STORE-099', message: 'odd'),
          );

    test('chains on Ok', () {
      expect(const Result<int>.ok(4).flatMap(half).valueOrNull, 2);
    });

    test('short-circuits the chain on the first Err', () {
      final result = const Result<int>.ok(
        3,
      ).flatMap(half).flatMap((v) => Result.ok(v * 100));
      expect(result.failureOrNull?.code, 'FX-STORE-099');
    });
  });

  test('exhaustive switch over Ok/Err compiles and matches', () {
    String describe(Result<int> r) => switch (r) {
      Ok<int>(:final value) => 'ok:$value',
      Err<int>(:final failure) => 'err:${failure.code}',
    };
    expect(describe(const Result.ok(1)), 'ok:1');
    expect(describe(const Result.err(failure)), 'err:FX-STORE-002');
  });
}
