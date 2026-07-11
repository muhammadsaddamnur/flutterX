import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:test/test.dart';

/// Compile-time proof the hierarchy is sealed and exhaustively switchable —
/// the CLI's failure → exit-code mapping relies on this (docs/06 §2.1).
int exitCodeFor(FxFailure failure) => switch (failure) {
  NetworkFailure() => 10,
  ResolutionConflict() => 11,
  LowConfidenceRefused() => 12,
  PolicyDenied() => 13,
  VersionNotFound() => 14,
  StorageFailure() => 15,
  GitFailure() => 15,
  UpgradeBlocked() => 16,
  ResourceInUse() => 17,
};

void main() {
  final samples = <FxFailure>[
    const NetworkFailure(code: 'FX-NET-001', message: 'download failed'),
    const ResolutionConflict(
      message: 'no release satisfies all constraints',
      conflictingSourceA: 'pubspec.yaml',
      conflictingSourceB: 'ci workflow',
    ),
    const LowConfidenceRefused(message: 'confidence low in CI'),
    const PolicyDenied(message: 'all candidates denied', denials: []),
    const VersionNotFound(requested: '3.21.9', suggestions: ['3.21.0']),
    const StorageFailure(code: 'FX-STORE-002', message: 'disk full'),
    const GitFailure(code: 'FX-GIT-003', message: 'partial fetch failed'),
    const UpgradeBlocked(
      message: '1 package cannot resolve',
      remediations: ['bump go_router to ^14.0.0'],
    ),
    const ResourceInUse(
      message: '2 projects still pinned',
      referencedBy: ['~/work/a', '~/work/b'],
    ),
  ];

  test('every failure code matches the stable FX-<AREA>-<NNN> format', () {
    final pattern = RegExp(r'^FX-[A-Z]+-\d{3}$');
    for (final failure in samples) {
      expect(
        failure.code,
        matches(pattern),
        reason: '${failure.runtimeType} has malformed code ${failure.code}',
      );
    }
  });

  test('every failure maps to a documented exit code (docs/04 §1.2)', () {
    const validCodes = {10, 11, 12, 13, 14, 15, 16, 17};
    for (final failure in samples) {
      expect(validCodes, contains(exitCodeFor(failure)));
    }
  });

  test('toString is code-prefixed for logs and issues', () {
    expect(
      const StorageFailure(
        code: 'FX-STORE-002',
        message: 'disk full',
      ).toString(),
      'FX-STORE-002: disk full',
    );
  });

  test('VersionNotFound carries actionable suggestions', () {
    const failure = VersionNotFound(requested: '3.21.9', suggestions: []);
    expect(failure.nextActions, isNotEmpty);
  });
}
