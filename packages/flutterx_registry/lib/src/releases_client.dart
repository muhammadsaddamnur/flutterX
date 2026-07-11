import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';

/// Outcome of one conditional GET of the releases index.
sealed class FetchOutcome {
  const FetchOutcome();
}

/// Fresh body received (HTTP 200).
final class FetchedBody extends FetchOutcome {
  const FetchedBody({required this.body, this.etag});
  final String body;
  final String? etag;
}

/// The cached copy is still current (HTTP 304).
final class NotModified extends FetchOutcome {
  const NotModified();
}

/// HTTP client for the Flutter releases index (docs/03 §1.2), with etag
/// support so refreshes are cheap.
final class ReleasesClient {
  ReleasesClient({
    this.baseUrl =
        'https://storage.googleapis.com/flutter_infra_release/releases',
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final String baseUrl;
  final HttpClient _http;

  static String indexFileName(TargetOs os) => switch (os) {
    TargetOs.macos => 'releases_macos.json',
    TargetOs.linux => 'releases_linux.json',
    TargetOs.windows => 'releases_windows.json',
  };

  Future<Result<FetchOutcome>> fetch(TargetOs os, {String? etag}) async {
    final url = Uri.parse('$baseUrl/${indexFileName(os)}');
    try {
      final request = await _http.getUrl(url);
      if (etag != null) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      final response = await request.close();
      if (response.statusCode == HttpStatus.notModified) {
        await response.drain<void>();
        return const Result.ok(NotModified());
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return Result.err(
          NetworkFailure(
            code: 'FX-REG-001',
            message: 'GET $url failed with HTTP ${response.statusCode}',
            nextActions: const ['flutterx cache refresh  # retry later'],
          ),
        );
      }
      final body = await response.transform(utf8.decoder).join();
      return Result.ok(
        FetchedBody(
          body: body,
          etag: response.headers.value(HttpHeaders.etagHeader),
        ),
      );
    } on SocketException catch (e) {
      return Result.err(
        NetworkFailure(
          code: 'FX-REG-001',
          message: 'cannot reach releases index: ${e.message}',
          nextActions: const [
            'check your network connection',
            'FlutterX keeps working from the cached snapshot',
          ],
        ),
      );
    } on HttpException catch (e) {
      return Result.err(
        NetworkFailure(code: 'FX-REG-001', message: 'GET $url failed: $e'),
      );
    }
  }
}
