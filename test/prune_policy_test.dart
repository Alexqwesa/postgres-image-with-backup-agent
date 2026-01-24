import 'dart:io';

import 'package:postgres_image_with_backup_agent/agent.dart';
import 'package:postgres_image_with_backup_agent/helpers/pgdump.dart';
import 'package:test/test.dart';

void main() {
  test('daily policy calls prune()', () async {
    var pruned = false;

    final tempDir = Directory.systemTemp.createTempSync('pgdump-agent-test-');
    final server = await serve(
      address: InternetAddress.loopbackIPv4,
      port: 0,
      expectedToken: 'tok',
      pgPassword: 'test',
      backupDir: tempDir.path,
      lockFile: File('${tempDir.path}/lock'),
      pgDump:
          ({
            required String host,
            required String port,
            required String db,
            required String user,
            required String outfile,
            required String password,
            required Duration timeout,
          }) async {
            await File(outfile).writeAsString('dummy');
            return ProcResult.named(exitCode: 0, stdout: 'ok', stderr: '', timedOut: false);
          },
      prune: (dir, policy, keep) async {
        pruned = (policy == 'daily' && keep > 0);
      },
    );

    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final client = HttpClient();

    final req = await client.postUrl(
      base.replace(path: '/backup', queryParameters: {'reason': 'daily'}),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer tok');
    final res = await req.close();

    expect(res.statusCode, 200);
    expect(pruned, true);

    client.close();
    await server.close(force: true);
    tempDir.deleteSync(recursive: true);
  });
}
