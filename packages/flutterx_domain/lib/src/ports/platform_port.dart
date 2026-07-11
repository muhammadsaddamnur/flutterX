import 'package:flutterx_domain/src/result.dart';
import 'package:flutterx_domain/src/values/target_os.dart';

/// How the store links artifacts into versions on this filesystem,
/// probed once at store init and recorded in state.json (docs/05 §5.1, §8).
enum LinkMode { hardlink, symlink, junction, copy }

/// OS abstraction port (docs/06 §2.1, §8) — implemented in
/// `flutterx_platform`, the only package allowed to branch on the host OS.
abstract interface class PlatformPort {
  /// The store root (`~/.flutterx` or `FLUTTERX_HOME`, docs/05 §3).
  String get storeHome;

  TargetOs get os;

  /// The link strategy probed for this store's filesystem.
  LinkMode get linkMode;

  /// Runs [executable] with [args], optionally inheriting stdio (proxy
  /// commands, docs/04 §3.13) and forwarding signals. Returns the exit code.
  Future<int> exec(
    String executable,
    List<String> args, {
    bool inheritStdio = true,
    String? workingDirectory,
    Map<String, String>? environment,
  });

  /// Creates a link at [linkPath] pointing to [targetPath] using the
  /// appropriate mechanism for [linkMode].
  Future<Result<void>> createLink({
    required String targetPath,
    required String linkPath,
  });
}
