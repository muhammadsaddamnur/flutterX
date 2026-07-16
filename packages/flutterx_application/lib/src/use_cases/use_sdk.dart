import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutterx_domain/flutterx_domain.dart';

/// `flutterx use [version]` (docs/04 §3.3): the manual counterpart of
/// `resolve` — pin explicitly, provision, write intent + lock + link.
///
/// Without a version argument, adopts the project's existing pin (own
/// `flutterx.yaml`, or migrated from FVM/Puro — docs/03 §2.1 sources 2–4).
final class UseSdk {
  UseSdk(
    this._sdks,
    this._registry,
    this._projects,
    this._scanner,
    this._clock,
  );

  final SdkRepository _sdks;
  final RegistryPort _registry;
  final ProjectStore _projects;
  final ProjectScanner _scanner;
  final DateTime Function() _clock;

  Future<Result<Resolution>> execute(
    String projectDir,
    String? specifier, {
    String? policyChannel,
    bool noInstall = false,
    ProgressReporter onProgress = noProgress,
  }) async {
    final project = await _projects.findProject(projectDir);
    if (project == null) {
      return Result.err(
        StorageFailure(
          code: 'FX-STORE-005',
          message:
              'no Dart/Flutter project found at or above $projectDir '
              '(looked for pubspec.yaml / flutterx.yaml)',
          nextActions: const ['cd into the project, or create pubspec.yaml'],
        ),
      );
    }

    // No explicit version → adopt the highest-priority existing pin
    // (migration path, T1.10.2).
    PinEvidence? adoptedPin;
    final scanWarnings = <ScanWarning>[];
    if (specifier == null) {
      final evidence = _scanner.scan(await _projects.readEvidence(project));
      scanWarnings.addAll(evidence.warnings);
      adoptedPin = evidence.effectivePin;
      if (adoptedPin == null) {
        return Result.err(
          StorageFailure(
            code: 'FX-STORE-009',
            message:
                'no version given and no existing pin found '
                '(flutterx.yaml / .fvmrc / .puro.json)',
            nextActions: const ['flutterx use <version>'],
          ),
        );
      }
      specifier = adoptedPin.version.toString();
    }

    onProgress(
      const ProgressEvent(
        phase: 'registry',
        message: 'Fetching release registry…',
      ),
    );
    final snapshot = await _registry.snapshot();
    if (snapshot case Err(:final failure)) return Result.err(failure);
    final release = snapshot.valueOrNull!.resolveSpecifier(specifier);
    if (release == null) {
      return Result.err(VersionNotFound(requested: specifier));
    }

    InstalledSdk? installed;
    if (!noInstall) {
      final result = await _sdks.ensureInstalled(
        release,
        onProgress: onProgress,
      );
      if (result case Err(:final failure)) return Result.err(failure);
      installed = result.valueOrNull;
    }

    final pinned = await _projects.writePin(
      project,
      pinVersion: policyChannel == null ? release.version.toString() : null,
      policyChannel: policyChannel,
    );
    if (pinned case Err(:final failure)) return Result.err(failure);

    final resolution = Resolution(
      chosen: release,
      confidence: Confidence.high, // explicit pin — user intent
      reasons: [
        Reason(
          text: adoptedPin != null
              ? 'pin adopted from ${adoptedPin.origin}'
              : policyChannel == null
              ? 'pinned explicitly via `flutterx use $specifier`'
              : 'policy $policyChannel via `flutterx use`',
        ),
        for (final warning in scanWarnings) Reason(text: 'warning: $warning'),
      ],
      evidenceHash: await evidenceHash(_projects, project),
      resolvedBy: adoptedPin != null ? ResolvedBy.migrate : ResolvedBy.use,
      resolvedAt: _clock().toUtc(),
    );
    final locked = await _projects.writeLock(project, resolution);
    if (locked case Err(:final failure)) return Result.err(failure);

    if (installed != null) {
      final linked = await _projects.linkSdk(project, installed);
      if (linked case Err(:final failure)) return Result.err(failure);
    }
    return Result.ok(resolution);
  }
}

/// sha256 over the evidence file map — the lock's staleness detector
/// (docs/03 §7). Deterministic: entries are hashed in path order.
Future<String> evidenceHash(ProjectStore projects, Project project) async {
  final evidence = await projects.readEvidence(project);
  final paths = evidence.files.keys.toList()..sort();
  final digest = sha256.convert(
    utf8.encode([for (final p in paths) '$p\x00${evidence.files[p]}'].join()),
  );
  return 'sha256:$digest';
}
