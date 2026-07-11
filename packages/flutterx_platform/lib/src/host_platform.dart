import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';

/// [PlatformPort] over the host OS (docs/06 §8).
///
/// `exec` runs the child with inherited stdio: it shares the terminal, so
/// hot-reload keys work and Ctrl-C reaches the whole process group — the
/// behavior contract of the proxy commands (docs/04 §3.13).
final class HostPlatform implements PlatformPort {
  HostPlatform({required this.storeHome, LinkMode? linkMode})
    : linkMode =
          linkMode ??
          (Platform.isWindows ? LinkMode.junction : LinkMode.symlink);

  @override
  final String storeHome;

  @override
  final LinkMode linkMode;

  @override
  TargetOs get os {
    if (Platform.isMacOS) return TargetOs.macos;
    if (Platform.isLinux) return TargetOs.linux;
    return TargetOs.windows;
  }

  @override
  Future<int> exec(
    String executable,
    List<String> args, {
    bool inheritStdio = true,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    try {
      final process = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
        mode: inheritStdio
            ? ProcessStartMode.inheritStdio
            : ProcessStartMode.normal,
      );
      return await process.exitCode;
    } on ProcessException catch (e) {
      stderr.writeln('flutterx: cannot run $executable: ${e.message}');
      return 127;
    }
  }

  @override
  Future<Result<void>> createLink({
    required String targetPath,
    required String linkPath,
  }) async {
    try {
      // Dart's Link.create issues junctions for directory links on
      // Windows automatically; hardlink probing lands with M1.11.
      await Link(linkPath).create(targetPath, recursive: true);
      return const Result.ok(null);
    } on FileSystemException catch (e) {
      return Result.err(
        StorageFailure(
          code: 'FX-STORE-006',
          message: 'cannot link $linkPath → $targetPath: ${e.message}',
        ),
      );
    }
  }
}
