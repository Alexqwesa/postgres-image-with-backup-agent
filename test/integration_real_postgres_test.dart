import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

import 'helpers/helpers_for_integration.dart';
import 'helpers/wait_until.dart';

var BACKUP_AGENT_PORT = 1804;

void main() {
  test(
    'integration: agent dumps a real postgres into mounted backups dir',
    () async {
      // Skip if Docker is not available
      if (!await _hasDocker()) {
        print('SKIP: docker not available');
        return;
      }

      final rnd = Random().nextInt(1 << 31);
      final net = 'pgdump_test_net_$rnd';
      final dbName = 'pgdump_test_db_$rnd';
      final agentName = 'pgdump_test_agent_$rnd';
      final imageTag = 'pgdump-agent-test-img:$rnd';

      final backupsDir = Directory.systemTemp.createTempSync('pgdump-backups-$rnd-');
      final hostPort = await pickFreePort();

      try {
        // 1) Create isolated docker network
        await _docker(['network', 'create', net]);

        // 2) Start Postgres (default user=postgres, password=postgres, db=postgres)
        await _docker([
          'run',
          '-d',
          '--rm',
          '--name',
          dbName,
          '--network',
          net,
          '-e',
          'POSTGRES_PASSWORD=postgres',
          '-e',
          'POSTGRES_DB=postgres',
          'postgres:16.3',
        ]);

        // 3) Wait until Postgres is ready
        await waitPgReady(container: dbName, timeout: const Duration(seconds: 160));

        // 4) Build YOUR image under test (repo root as context)
        await _docker(['build', '-t', imageTag, '.']);

        // 5) Run agent-only container from your image, connect to db container, mount backups
        await _docker([
          'run',
          '-d',
          '--rm',
          '--name',
          agentName,
          '--network',
          net,
          '-p',
          '$hostPort:$BACKUP_AGENT_PORT',
          '-v',
          '${backupsDir.path}:/backups',
          '-e',
          'BACKUP_AGENT_PORT=$BACKUP_AGENT_PORT',
          '-e',
          'BACKUP_AGENT_TOKEN=tok',
          '-e',
          'BACKUP_TO_DIR=/backups',
          // DB connection for pg_dump (inside the agent container)
          '-e',
          'PGHOST=$dbName',
          '-e',
          'PGPORT=5432',
          '-e',
          'PGDATABASE=postgres',
          '-e',
          'PGUSER=postgres',
          '-e',
          'PGPASSWORD=postgres',
          // Run agent only (no postgres inside this container)
          '--entrypoint',
          '/usr/local/bin/docker-entrypoint-agent-only.sh',
          imageTag,
        ]);

        // 6) Call the agent endpoint
        HttpRes? res;
        try {
          final uri = Uri.parse('http://127.0.0.1:$hostPort/backup?reason=adhoc');
          await waitHttpHealthy(uri);
          res = await httpPostJson(uri, headers: {HttpHeaders.authorizationHeader: 'Bearer tok'});
        } catch (e) {
          final logs = await dockerOut(['logs', agentName, '--tail', '200']);
          throw StateError('HTTP failed: $e\n--- agent logs ---\n$logs');
        }
        expect(res.statusCode, 200, reason: res.body);
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        expect(json['ok'], true, reason: res.body);

        // 7) Verify a dump file appears on the HOST (mounted volume)
        final dumpFile = await waitForDumpFile(backupsDir, timeout: const Duration(seconds: 30));
        expect(dumpFile.existsSync(), isTrue);

        // 8) (Optional but “real”): verify dump is readable with pg_restore -l
        // Use a throwaway postgres image container to run pg_restore against the mounted file.
        await _docker([
          'run',
          '--rm',
          '-v',
          '${backupsDir.path}:/backups',
          'postgres:16.3',
          'pg_restore',
          '-l',
          '/backups/${dumpFile.uri.pathSegments.last}',
        ]);
      } finally {
        // Cleanup (best-effort)
        await _dockerNoThrow(['rm', '-f', agentName]);
        await _dockerNoThrow(['rm', '-f', dbName]);
        await _dockerNoThrow(['network', 'rm', net]);
        backupsDir.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<bool> _hasDocker() async {
  try {
    final r = await Process.run('docker', ['version'], runInShell: true);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<void> _docker(List<String> args) async {
  final r = await Process.run('docker', args, runInShell: true);
  if (r.exitCode != 0) {
    throw StateError(
      'docker ${args.join(' ')} failed\n'
      'exit=${r.exitCode}\n'
      'stdout=${r.stdout}\n'
      'stderr=${r.stderr}',
    );
  }
}

Future<void> _dockerNoThrow(List<String> args) async {
  try {
    await Process.run('docker', args, runInShell: true);
  } catch (_) {}
}
