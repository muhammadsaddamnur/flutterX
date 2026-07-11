import 'dart:io';

/// Advisory exclusive lock serializing store mutations (docs/02 §7.1,
/// docs/05 §3). Read paths never take it.
///
/// Semantics are per-process (flock/LockFileEx): two `flutterx` invocations
/// serialize; within one process the lock is not reentrant — callers must
/// not nest [withExclusive].
final class StoreLock {
  StoreLock(this.lockFilePath);

  final String lockFilePath;

  Future<T> withExclusive<T>(Future<T> Function() body) async {
    final file = File(lockFilePath);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    await raf.lock(FileLock.blockingExclusive);
    try {
      return await body();
    } finally {
      await raf.unlock();
      await raf.close();
    }
  }
}
