import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutterx_domain/flutterx_domain.dart';
import 'package:flutterx_storage/flutterx_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Loopback file server with Range support (resume) and a togglable outage.
final class TestServer {
  TestServer(this.server, this.files);

  final HttpServer server;
  final Map<String, List<int>> files;
  bool available = true;

  static Future<TestServer> start(Map<String, List<int>> files) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final wrapper = TestServer(server, files);
    server.listen((request) {
      final response = request.response;
      final body = wrapper.available ? files[request.uri.path] : null;
      if (body == null) {
        response.statusCode = HttpStatus.notFound;
        response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
        );
        response.statusCode = HttpStatus.partialContent;
        response.add(body.sublist(start));
      } else {
        response.add(body);
      }
      response.close();
    });
    return wrapper;
  }

  Uri url(String path) =>
      Uri.parse('http://${server.address.host}:${server.port}$path');

  Future<void> close() => server.close(force: true);
}

String shaOf(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory tmp;
  late StoreLayout layout;
  late DownloadManager downloads;
  late ArtifactStore cas;
  late TestServer server;

  final engineBytes = utf8.encode('engine artifact payload ' * 100);
  final engineSha = shaOf(engineBytes);

  // Portable link stand-in: symlink on POSIX, copy on Windows — copy is a
  // legitimate LinkMode fallback (docs/05 §5.1), and these tests assert
  // content, not mechanism.
  Future<Result<void>> symlinkCreate({
    required String targetPath,
    required String linkPath,
  }) async {
    if (Platform.isWindows) {
      await File(targetPath).copy(linkPath);
    } else {
      await Link(linkPath).create(targetPath);
    }
    return const Result.ok(null);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('flutterx_cas_');
    layout = StoreLayout(tmp.path);
    await layout.init();
    downloads = DownloadManager(downloadsDir: layout.downloadsDir);
    cas = ArtifactStore(
      layout: layout,
      downloads: downloads,
      createLink: symlinkCreate,
    );
    server = await TestServer.start({'/engine.zip': engineBytes});
  });

  tearDown(() async {
    await server.close();
    await tmp.delete(recursive: true);
  });

  group('DownloadManager', () {
    test('downloads, verifies, and atomically completes', () async {
      final result = await downloads.fetch(
        server.url('/engine.zip'),
        engineSha,
      );
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      expect(result.valueOrNull!.readAsBytesSync(), engineBytes);
      expect(
        Directory(
          layout.downloadsDir,
        ).listSync().any((f) => f.path.endsWith('.partial')),
        isFalse,
      );
    });

    test('resumes an interrupted download via Range (docs/05 §5.1)', () async {
      final half = engineBytes.length ~/ 2;
      File(
        p.join(layout.downloadsDir, '$engineSha.partial'),
      ).writeAsBytesSync(engineBytes.sublist(0, half));

      var sawResume = false;
      final result = await downloads.fetch(
        server.url('/engine.zip'),
        engineSha,
        onProgress: (received, total) {
          if (received > half && received <= engineBytes.length) {
            sawResume = true;
          }
        },
      );
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      expect(result.valueOrNull!.readAsBytesSync(), engineBytes);
      expect(sawResume, isTrue, reason: 'continued from the partial');
    });

    test(
      'checksum mismatch discards the poisoned partial (FX-STORE-004)',
      () async {
        const wrongSha =
            '0000000000000000000000000000000000000000000000000000000000000000';
        final result = await downloads.fetch(
          server.url('/engine.zip'),
          wrongSha,
        );
        expect(result.failureOrNull?.code, 'FX-STORE-004');
        expect(
          File(p.join(layout.downloadsDir, '$wrongSha.partial')).existsSync(),
          isFalse,
        );
      },
    );

    test('HTTP 404 is a network-class failure (exit 10)', () async {
      final result = await downloads.fetch(
        server.url('/missing.zip'),
        engineSha,
      );
      expect(result.failureOrNull, isA<NetworkFailure>());
    });
  });

  group('ArtifactStore (CAS)', () {
    ArtifactRef ref() =>
        ArtifactRef(url: server.url('/engine.zip'), sha256: engineSha);

    test('ensure commits payload + meta at the sharded address', () async {
      final result = await cas.ensure(ref());
      expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
      final entry = result.valueOrNull!;
      expect(File(entry.payloadPath).readAsBytesSync(), engineBytes);
      expect(
        File(p.join(layout.casEntryDir(engineSha), 'meta.json')).existsSync(),
        isTrue,
      );
    });

    test('ensure is idempotent — second call touches no network', () async {
      await cas.ensure(ref());
      server.available = false;
      final again = await cas.ensure(ref());
      expect(again.isOk, isTrue, reason: 'served from the CAS, not the net');
    });

    test('linkInto links the payload and is idempotent', () async {
      final entry = (await cas.ensure(ref())).valueOrNull!;
      final target = p.join(tmp.path, 'versions', '3.22.2', 'engine.zip');
      expect((await cas.linkInto(entry, target)).isOk, isTrue);
      expect(File(target).readAsBytesSync(), engineBytes);
      expect((await cas.linkInto(entry, target)).isOk, isTrue);
    });

    test('verify detects a corrupted payload (write-once violated)', () async {
      final entry = (await cas.ensure(ref())).valueOrNull!;
      expect((await cas.verify()).healthy, isTrue);
      File(entry.payloadPath).writeAsStringSync('tampered');
      final report = await cas.verify();
      expect(report.checked, 1);
      expect(report.corrupt, [engineSha]);
    });

    test('unreferenced + delete implement the GC contract', () async {
      await cas.ensure(ref());
      expect(await cas.unreferenced({engineSha}), isEmpty);
      final orphans = await cas.unreferenced(const {});
      expect(orphans, {engineSha});
      await cas.delete(engineSha);
      expect(await cas.unreferenced(const {}), isEmpty);
    });
  });

  test('StoreLock serializes and releases', () async {
    final lock = StoreLock(layout.storeLockFile);
    final order = <int>[];
    await lock.withExclusive(() async => order.add(1));
    await lock.withExclusive(() async => order.add(2));
    expect(order, [1, 2]);
  });
}
