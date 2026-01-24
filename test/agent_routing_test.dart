import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:postgres_image_with_backup_agent/agent.dart';
import 'package:postgres_image_with_backup_agent/helpers/pgdump.dart';

void main() {
  group('routing + auth', () {
    late HttpServer server;
    late Uri base;

    setUp(() async {
      server = await serve(
        address: InternetAddress.loopbackIPv4,
        port: 0, // ephemeral
        expectedToken: 'tok',
        pgPassword: 'test',
        backupDir: Directory.systemTemp.createTempSync('pgdump-agent-test-').path,
        lockFile: File('${Directory.systemTemp.path}/pgdump-agent-test.lock'),
        pgDump: ({
          required String host,
          required String port,
          required String db,
          required String user,
          required String outfile,
          required String password,
          required Duration timeout,
        }) async {
          // fake success
          return ProcResult.named(exitCode: 0, stdout: 'ok', stderr: '', timedOut: false);
        },
      );

      base = Uri.parse('http://127.0.0.1:${server.port}');
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('GET /health returns ok', () async {
      final client = HttpClient();
      final req = await client.getUrl(base.replace(path: '/health'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      expect(res.statusCode, 200);
      expect(jsonDecode(body)['ok'], true);
      client.close();
    });

    test('POST /backup without token -> 401', () async {
      final client = HttpClient();
      final req = await client.postUrl(base.replace(path: '/backup', queryParameters: {'reason': 'adhoc'}));
      final res = await req.close();
      expect(res.statusCode, 401);
      client.close();
    });

    test('unknown route -> 404', () async {
      final client = HttpClient();
      final req = await client.getUrl(base.replace(path: '/nope'));
      final res = await req.close();
      expect(res.statusCode, 404);
      client.close();
    });
  });
}
