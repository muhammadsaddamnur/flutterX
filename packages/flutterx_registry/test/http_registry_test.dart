import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_registry/flutterx_registry.dart';
import 'package:test/test.dart';

/// Freshness/offline behavior of [HttpRegistry] against a loopback index
/// server (docs/03 §1.2).
void main() {
  late Directory tmp;
  late HttpServer server;
  var requests = 0;
  var available = true;
  const currentEtag = '"etag-v1"';

  final indexBody = jsonEncode({
    'base_url': 'https://example.test/releases',
    'releases': [
      {
        'hash': 'abc',
        'channel': 'stable',
        'version': '3.22.2',
        'dart_sdk_version': '3.4.3',
        'dart_sdk_arch': 'arm64',
        'release_date': '2024-06-06T17:32:28.763450Z',
        'archive': 'stable/macos/flutter_macos_arm64_3.22.2-stable.zip',
        'sha256': 'f' * 64,
      },
    ],
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_registry_');
    requests = 0;
    available = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests++;
      final response = request.response;
      if (!available) {
        response.statusCode = HttpStatus.serviceUnavailable;
      } else if (request.headers.value(HttpHeaders.ifNoneMatchHeader) ==
          currentEtag) {
        response.statusCode = HttpStatus.notModified;
      } else {
        response.headers.set(HttpHeaders.etagHeader, currentEtag);
        response.write(indexBody);
      }
      response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  HttpRegistry registry({
    DateTime Function()? clock,
    Map<String, String> seedBodies = const {},
  }) => HttpRegistry(
    client: ReleasesClient(
      baseUrl: 'http://${server.address.host}:${server.port}',
    ),
    cache: SnapshotCache(cacheDir: tmp.path),
    os: TargetOs.macos,
    preferredArch: 'arm64',
    clock: clock,
    seedBodies: seedBodies,
  );

  test('cold start fetches, caches, and parses', () async {
    final result = await registry().snapshot();
    expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
    final snapshot = result.valueOrNull!;
    expect(
      snapshot.find(SemVer.parse('3.22.2'))!.dartVersion,
      SemVer.parse('3.4.3'),
    );
    expect(requests, 1);
  });

  test('within the TTL the cache is served without network', () async {
    final reg = registry();
    await reg.snapshot();
    final again = await reg.snapshot();
    expect(again.valueOrNull!.source, 'cache');
    expect(requests, 1, reason: 'second call never hit the server');
  });

  test('--refresh sends the etag and a 304 touches freshness only', () async {
    var now = DateTime.utc(2026, 7, 11, 0, 0);
    final reg = registry(clock: () => now);
    await reg.snapshot();

    now = DateTime.utc(2026, 7, 11, 12, 0); // past the 6h TTL
    final refreshed = await reg.snapshot(refresh: true);
    expect(requests, 2);
    expect(refreshed.isOk, isTrue);
    expect(
      refreshed.valueOrNull!.fetchedAt,
      now,
      reason: '304 updates fetchedAt without a new body',
    );

    // Immediately after the touch, the cache is fresh again.
    await reg.snapshot();
    expect(requests, 2);
  });

  test('offline with a stale cache serves it, staleness visible', () async {
    var now = DateTime.utc(2026, 7, 1);
    final reg = registry(clock: () => now);
    await reg.snapshot();

    available = false;
    now = DateTime.utc(2026, 7, 11); // TTL long expired + server down
    final result = await reg.snapshot();
    expect(result.isOk, isTrue, reason: 'honest offline behavior');
    expect(result.valueOrNull!.source, 'cache');
    expect(
      result.valueOrNull!.fetchedAt,
      DateTime.utc(2026, 7, 1),
      reason: 'true age preserved so staleness stays visible',
    );
  });

  test('cold offline start falls back to the bundled seed', () async {
    available = false;
    final result = await registry(seedBodies: {'macos': indexBody}).snapshot();
    expect(result.isOk, isTrue);
    expect(result.valueOrNull!.source, 'seed');
  });

  test('cold offline start with no seed fails with FX-REG-001', () async {
    available = false;
    final result = await registry().snapshot();
    expect(result.failureOrNull, isA<NetworkFailure>());
    expect(result.failureOrNull?.code, 'FX-REG-001');
  });
}
