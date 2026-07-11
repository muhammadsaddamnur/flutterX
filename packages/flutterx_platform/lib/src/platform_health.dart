import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_platform/src/shim_installer.dart';

/// [PlatformHealthPort]: git availability, shim currency, PATH ordering
/// (docs/04 §3.7 "Platform" section).
final class PlatformHealth implements PlatformHealthPort {
  PlatformHealth({required this.shimInstaller, this.gitExecutable = 'git'});

  final ShimInstaller shimInstaller;
  final String gitExecutable;

  @override
  Future<List<Probe>> probePlatform() async {
    final probes = <Probe>[];

    // git presence + minimum version (fatal — nothing works without it).
    try {
      final result = await Process.run(gitExecutable, ['--version']);
      final match = RegExp(
        r'git version (\d+)\.(\d+)',
      ).firstMatch(result.stdout.toString());
      final major = int.tryParse(match?.group(1) ?? '') ?? 0;
      final minor = int.tryParse(match?.group(2) ?? '') ?? 0;
      final supported = major > 2 || (major == 2 && minor >= 30);
      probes.add(
        Probe(
          kind: 'git',
          subject: '$major.$minor',
          ok: supported,
          detail: supported ? '>= 2.30 required — OK' : '>= 2.30 required',
          severity: Severity.error,
        ),
      );
    } on ProcessException {
      probes.add(
        const Probe(
          kind: 'git',
          subject: 'git',
          ok: false,
          detail: 'git executable not found on PATH',
          severity: Severity.error,
        ),
      );
    }

    // Shims current + PATH ordering (FX-R07 / guidance).
    final shims = await shimInstaller.ensure();
    switch (shims) {
      case Err(:final failure):
        probes.add(
          Probe(
            kind: 'shims',
            subject: shimInstaller.binDir,
            ok: false,
            detail: failure.message,
          ),
        );
      case Ok(:final value):
        probes.add(
          Probe(
            kind: 'shims',
            subject: shimInstaller.binDir,
            ok: true,
            detail: value.written.isEmpty
                ? 'current'
                : 'reinstalled: ${value.written.join(', ')}',
          ),
        );
        probes.add(
          Probe(
            kind: 'path',
            subject: shimInstaller.binDir,
            ok: value.binDirOnPath,
            detail: value.binDirOnPath
                ? null
                : 'not on PATH — shims inactive. Fix: '
                      '${shimInstaller.pathGuidance()}',
          ),
        );
    }
    return probes;
  }
}
