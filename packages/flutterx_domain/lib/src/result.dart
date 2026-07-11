import 'package:flutterx_domain/src/failures/fx_failure.dart';

/// Success-or-expected-failure return type (docs/06 §2.1).
///
/// The docs left the shape open ("record or sealed Ok/Err"); the sealed form
/// was chosen because it gives exhaustive `switch` checking, which the
/// failure → exit-code mapping in the CLI relies on.
sealed class Result<T> {
  const Result();

  const factory Result.ok(T value) = Ok<T>;
  const factory Result.err(FxFailure failure) = Err<T>;

  bool get isOk => this is Ok<T>;

  /// The success value, or `null` when this is an [Err]. Prefer `switch`.
  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };

  /// The failure, or `null` when this is an [Ok].
  FxFailure? get failureOrNull => switch (this) {
    Ok<T>() => null,
    Err<T>(:final failure) => failure,
  };

  /// Transforms the success value, passing failures through unchanged.
  Result<U> map<U>(U Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => Result.ok(transform(value)),
    Err<T>(:final failure) => Result.err(failure),
  };

  /// Chains a result-returning operation, short-circuiting on failure.
  Result<U> flatMap<U>(Result<U> Function(T value) next) => switch (this) {
    Ok<T>(:final value) => next(value),
    Err<T>(:final failure) => Result.err(failure),
  };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;

  @override
  String toString() => 'Ok($value)';
}

final class Err<T> extends Result<T> {
  const Err(this.failure);
  final FxFailure failure;

  @override
  String toString() => 'Err($failure)';
}
