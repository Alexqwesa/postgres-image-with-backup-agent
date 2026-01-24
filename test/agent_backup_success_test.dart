import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:postgres_image_with_backup_agent/agent.dart';
import 'package:postgres_image_with_backup_agent/helpers/pgdump.dart';

void main() {
  test('POST /backup with token returns 200 and file path', () async {
    final tempDir = Directory.systemTemp.createTempSync('pgdump-agent-test-');
    final server = await serve(
      address: InternetAddress.loopbackIPv4,
      port: 0,
      expectedToken: 'tok',
      pgPassword: 'test',
      backupDir: tempDir.path,
      lockFile: File('${tempDir.path}/lock'),
      pgDump: ({
        required String host,
        required String port,
        required String db,
        required String user,
        required String outfile,
        required String password,
        required Duration timeout,
      }) async {
        // simulate dump file created
        await File(outfile).writeAsString('dummy');
        return ProcResult.named(exitCode: 0, stdout: 'ok', stderr: '', timedOut: false);
      },
    );

    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final client = HttpClient();

    final req = await client.postUrl(base.replace(path: '/backup', queryParameters: {'reason': 'adhoc'}));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer tok');
    // Provide password via env fallback not used here; easiest: set allowAnyDb and header.
    // But our serve() reads env. So set env before test runs or just set POSTGRES_PASSWORD in process env.
    // For test simplicity, rely on POSTGRES_PASSWORD being present:
    //   dart test --define=... is not supported for env, so set PGPASSWORD in your test environment.
    //
    // If you prefer no env reliance, we can extend serve() to accept pg password directly.

    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    final json = jsonDecode(body);

    expect(res.statusCode, 200, reason: body);
    expect(json['ok'], true);
    expect((json['file'] as String).contains(tempDir.path), true);

    client.close();
    await server.close(force: true);
    tempDir.deleteSync(recursive: true);
  });
}
