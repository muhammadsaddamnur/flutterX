import 'dart:convert';
import 'dart:io';

import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_registry/flutterx_registry.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  var requests = 0;

  final body = jsonEncode({
    'version': '2.5.1',
    'pubspec': {
      'name': 'riverpod',
      'environment': {'sdk': '>=3.0.0 <4.0.0', 'flutter': '>=3.10.0'},
    },
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_pubmeta_');
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests++;
      if (request.uri.path == '/packages/riverpod/versions/2.5.1') {
        request.response.write(body);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  PubMetaClient client() => PubMetaClient(
    cacheDir: tmp.path,
    baseUrl: 'http://${server.address.host}:${server.port}',
  );

  test('fetches and parses pub.dev metadata', () async {
    final result = await client().fetch('riverpod', SemVer.parse('2.5.1'));
    final meta = result.valueOrNull!;
    expect(meta.dartConstraint.allows(SemVer.parse('3.4.3')), isTrue);
    expect(meta.flutterConstraint!.allows(SemVer.parse('3.9.0')), isFalse);
  });

  test('caches forever — the second fetch never hits the network', () async {
    await client().fetch('riverpod', SemVer.parse('2.5.1'));
    final again = await client().fetch('riverpod', SemVer.parse('2.5.1'));
    expect(again.isOk, isTrue);
    expect(requests, 1);
    expect(
      File('${tmp.path}/riverpod/2.5.1.json').existsSync(),
      isTrue,
      reason: 'cache/registry/pub/<pkg>/<version>.json (docs/05 §3)',
    );
  });

  test('unknown package → FX-REG-002, never a crash', () async {
    final result = await client().fetch('nope', SemVer.parse('1.0.0'));
    expect(result.failureOrNull?.code, 'FX-REG-002');
  });
}
