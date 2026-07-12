import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:path/path.dart' as p;

/// pub.dev metadata client with a forever-cache (docs/03 §6.1,
/// docs/05 §3 `cache/registry/pub/`).
///
/// A published (name, version) is immutable, so a cache hit never
/// revalidates — Dependency Intelligence fast mode stays offline-capable
/// after the first resolve.
final class PubMetaClient {
  PubMetaClient({
    required this.cacheDir,
    this.baseUrl = 'https://pub.dev/api',
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  /// `<store>/cache/registry/pub`.
  final String cacheDir;
  final String baseUrl;
  final HttpClient _http;

  Future<Result<PackageMeta>> fetch(String name, SemVer version) async {
    final cacheFile = File(p.join(cacheDir, name, '$version.json'));
    if (cacheFile.existsSync()) {
      try {
        return Result.ok(
          _parse(
            name,
            version,
            jsonDecode(await cacheFile.readAsString()) as Map<String, Object?>,
          ),
        );
      } on Exception {
        // Torn cache entry — refetch below.
      }
    }

    final url = Uri.parse('$baseUrl/packages/$name/versions/$version');
    try {
      final request = await _http.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return Result.err(
          NetworkFailure(
            code: 'FX-REG-002',
            message:
                'pub.dev returned HTTP ${response.statusCode} for '
                '$name $version',
          ),
        );
      }
      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, Object?>;
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsString(body);
      return Result.ok(_parse(name, version, json));
    } on SocketException catch (e) {
      return Result.err(
        NetworkFailure(
          code: 'FX-REG-002',
          message: 'cannot reach pub.dev for $name $version: ${e.message}',
          nextActions: const [
            'unverified packages reduce the score but never block',
          ],
        ),
      );
    } on Exception catch (e) {
      return Result.err(
        NetworkFailure(
          code: 'FX-REG-002',
          message: 'pub metadata for $name $version unreadable: $e',
        ),
      );
    }
  }

  static PackageMeta _parse(
    String name,
    SemVer version,
    Map<String, Object?> json,
  ) {
    final pubspec = json['pubspec'] as Map<String, Object?>? ?? const {};
    final environment =
        pubspec['environment'] as Map<String, Object?>? ?? const {};
    VersionConstraintX constraint(Object? raw) {
      if (raw == null) return VersionConstraintX.any;
      try {
        return VersionConstraintX.parse(raw.toString());
      } on FormatException {
        return VersionConstraintX.any; // tolerant: unknown syntax ≈ any
      }
    }

    final flutterRaw = environment['flutter'];
    return PackageMeta(
      name: name,
      version: version,
      dartConstraint: constraint(environment['sdk']),
      flutterConstraint: flutterRaw == null ? null : constraint(flutterRaw),
    );
  }
}
