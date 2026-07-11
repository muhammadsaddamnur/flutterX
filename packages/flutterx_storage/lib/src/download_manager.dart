import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// Resumable, integrity-verified downloads into `cache/downloads`
/// (docs/05 §3, §5.1).
///
/// Protocol: bytes stream into `<sha256>.partial`; an interrupted download
/// resumes with a Range request; on completion the hash is verified and the
/// file atomically renamed to `<sha256>` — so a completed file in the
/// downloads dir is always verified, and two concurrent downloaders of the
/// same artifact converge safely.
final class DownloadManager {
  DownloadManager({required this.downloadsDir, HttpClient? httpClient})
    : _http = httpClient ?? HttpClient();

  final String downloadsDir;
  final HttpClient _http;

  /// Downloads [url], verifies it hashes to [sha256], and returns the
  /// completed file. Progress reports `(receivedBytes, totalBytes?)`.
  Future<Result<File>> fetch(
    Uri url,
    String sha256, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final lower = sha256.toLowerCase();
    final completed = File(p.join(downloadsDir, lower));
    if (completed.existsSync()) return Result.ok(completed);

    final partial = File(p.join(downloadsDir, '$lower.partial'));
    await partial.parent.create(recursive: true);

    try {
      final resumeFrom = partial.existsSync() ? partial.lengthSync() : 0;
      final request = await _http.getUrl(url);
      if (resumeFrom > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
      }
      final response = await request.close();

      final resuming =
          resumeFrom > 0 && response.statusCode == HttpStatus.partialContent;
      if (response.statusCode != HttpStatus.ok && !resuming) {
        await response.drain<void>();
        return Result.err(
          NetworkFailure(
            code: 'FX-NET-001',
            message: 'GET $url failed with HTTP ${response.statusCode}',
            nextActions: const ['re-run — downloads resume automatically'],
          ),
        );
      }

      final sink = partial.openWrite(
        mode: resuming ? FileMode.append : FileMode.write,
      );
      var received = resuming ? resumeFrom : 0;
      final total = response.contentLength > 0
          ? response.contentLength + (resuming ? resumeFrom : 0)
          : null;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
    } on SocketException catch (e) {
      return Result.err(
        NetworkFailure(
          code: 'FX-NET-001',
          message: 'download of $url interrupted: ${e.message}',
          nextActions: const ['re-run — downloads resume automatically'],
        ),
      );
    } on HttpException catch (e) {
      return Result.err(
        NetworkFailure(code: 'FX-NET-001', message: 'GET $url failed: $e'),
      );
    }

    final actual = await _hashFile(partial);
    if (actual != lower) {
      // A poisoned partial would fail forever — delete so the next attempt
      // starts clean.
      await partial.delete();
      return Result.err(
        StorageFailure(
          code: 'FX-STORE-004',
          message: 'checksum mismatch for $url: expected $lower, got $actual',
          nextActions: const [
            're-run — the corrupt partial download was discarded',
            'flutterx cache refresh  # the registry may list stale hashes',
          ],
        ),
      );
    }

    await partial.rename(completed.path);
    return Result.ok(completed);
  }

  static Future<String> _hashFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
