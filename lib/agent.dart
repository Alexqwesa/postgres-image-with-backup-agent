import 'dart:async';
import 'dart:io';

import 'helpers/backup_lock.dart';
import 'helpers/env.dart';
import 'helpers/http_json.dart';
import 'helpers/pgdump.dart';
import 'helpers/prune.dart';
import 'helpers/safe_file_part.dart';

typedef PgDumpFn =
    Future<ProcResult> Function({
      required String host,
      required String port,
      required String db,
      required String user,
      required String outfile,
      required String password,
      required Duration timeout,
    });

typedef PruneFn = Future<void> Function(String dir, String policy, int keep);

Future<HttpServer> serve({
  int? port,
  InternetAddress? address,
  PgDumpFn pgDump = runPgDump,
  PruneFn prune = pruneByCount,
  File? lockFile,
  String? backupDir,
  String? expectedToken,
  String? pgPassword,
}) async {
  final bindPort = port ?? envInt('BACKUP_AGENT_PORT', 1804);
  final bindAddr = address ?? InternetAddress.anyIPv6;

  final server = await HttpServer.bind(bindAddr, bindPort, v6Only: false);
  stdout.writeln('pgdump-agent (Dart) listening on :${server.port}');

  final expected = expectedToken ?? envStr('BACKUP_AGENT_TOKEN');
  if (expected.isEmpty) {
    stdout.writeln('WARNING: BACKUP_AGENT_TOKEN is not set or empty!!!');
  }

  final dirPath = backupDir ?? envStr('BACKUP_TO_DIR', '/backups');

  unawaited(() async {
    await for (final req in server) {
      print("Backup agent got: ${req.requestedUri}");
      // Routing
      if (req.uri.path == '/health') {
        await jsonResponse(req, 200, {'ok': true, 'status': 'healthy'});
        continue;
      }
      if (req.method != 'POST' || req.uri.path != '/backup') {
        await jsonResponse(req, 404, {'ok': false, 'error': 'not found'});
        continue;
      }

      // Auth
      final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
      if (expected.isNotEmpty) {
        final token = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
        if (token != expected) {
          stdout.writeln(
            'AUTH FAIL from ${req.connectionInfo?.remoteAddress}:${req.connectionInfo?.remotePort} '
            'path=${req.uri.path} '
            'gotBearerLen=${token.isEmpty ? 0 : token.length} expectedLen=${expected.length}',
          );
          await jsonResponse(req, 401, {'ok': false, 'error': 'unauthorized'});
          continue;
        }
      }

      // Ensure backup dir is writable
      try {
        final dir = Directory(dirPath);
        await dir.create(recursive: true);
        final probe = File('${dir.path}/.write_probe');
        await probe.writeAsString(DateTime.now().toIso8601String());
        await probe.delete();
      } catch (e) {
        await jsonResponse(req, 400, {
          'ok': false,
          'error': 'backup dir not writable',
          'detail': e.toString(),
        });
        continue;
      }

      // Lock + stale detection
      final pgDumpTimeoutSec = envInt('BACKUP_TIMEOUT_SECONDS', 6000);
      final staleSec = envInt('LOCK_STALE_SECONDS', pgDumpTimeoutSec * 2);

      final lf = lockFile ?? File('${Directory.systemTemp.path}/pgdump-agent.lock');
      final lock = BackupLock(lockFile: lf, staleSec: staleSec);
      final lockRes = await lock.acquire();
      if (!lockRes.acquired) {
        await jsonResponse(req, 409, {
          'ok': false,
          'error': 'backup already running',
          if (lockRes.lockSinceUtc != null) 'lockSinceUtc': lockRes.lockSinceUtc!.toIso8601String(),
        });
        continue;
      }

      final policyRaw = (req.uri.queryParameters['reason'] ?? 'adhoc').toLowerCase();
      final policy = switch (policyRaw) {
        'daily' || 'weekly' || 'monthly' || 'adhoc' => policyRaw,
        _ => 'adhoc',
      };

      try {
        // Prefer libpq env vars, then fallback.
        var host = envStr('PGHOST', envStr('POSTGRES_HOST', '127.0.0.1'));
        var portStr = envStr('PGPORT', envStr('POSTGRES_PORT', '5432'));
        var dbname = envStr('PGDATABASE', envStr('POSTGRES_DB', 'postgres'));
        var user = envStr('PGUSER', envStr('POSTGRES_USER', 'postgres'));
        var pgpwd = pgPassword ?? envStr('PGPASSWORD', envStr('POSTGRES_PASSWORD', ''));

        final allowAnyDb = envBool('ALLOW_ANY_DB', def: false);
        if (allowAnyDb) {
          host = req.headers.value('PGHOST') ?? req.headers.value('POSTGRES_HOST') ?? host;
          portStr = req.headers.value('PGPORT') ?? req.headers.value('POSTGRES_PORT') ?? portStr;
          dbname = req.headers.value('PGDATABASE') ?? req.headers.value('POSTGRES_DB') ?? dbname;
          user = req.headers.value('PGUSER') ?? req.headers.value('POSTGRES_USER') ?? user;
          pgpwd =
              req.headers.value('PGPASSWORD') ?? req.headers.value('POSTGRES_PASSWORD') ?? pgpwd;
        }

        if (pgpwd.isEmpty) {
          await jsonResponse(req, 500, {'ok': false, 'error': 'PGPASSWORD not set'});
          continue;
        }

        if (int.tryParse(portStr) == null) {
          await jsonResponse(req, 400, {'ok': false, 'error': 'invalid POSTGRES_PORT'});
          continue;
        }

        final ts = DateTime.now()
            .toUtc()
            .toIso8601String()
            .replaceAll(':', '')
            .replaceAll('-', '')
            .split('.')
            .first;

        final outfile =
            '$dirPath/'
            '${safeFilePart(dbname, fallback: 'db')}_'
            '${ts}_'
            '${safeFilePart(host, fallback: 'host')}_'
            '${safeFilePart(portStr, fallback: 'p')}_'
            '${safeFilePart(policy, fallback: 'adhoc')}.dump';

        stdout.writeln(
          'pg_dump start: host=$host port=$portStr db=$dbname user=$user '
          'policy=$policy outfile=$outfile timeoutSec=$pgDumpTimeoutSec',
        );

        final result = await pgDump(
          host: host,
          port: portStr,
          db: dbname,
          user: user,
          outfile: outfile,
          password: pgpwd,
          timeout: Duration(seconds: pgDumpTimeoutSec),
        );

        if (result.timedOut) {
          await jsonResponse(req, 504, {
            'ok': false,
            'error': 'pg_dump timed out',
            'stderr': result.stderr,
          });
          continue;
        }
        if (result.exitCode != 0) {
          await jsonResponse(req, 500, {
            'ok': false,
            'error': 'pg_dump failed',
            'rc': result.exitCode,
            'stderr': result.stderr,
          });
          continue;
        }

        if (policy == 'daily' || policy == 'weekly' || policy == 'monthly') {
          final keep = switch (policy) {
            'daily' => envInt('BACKUP_KEEP_DAILY', 30),
            'weekly' => envInt('BACKUP_KEEP_WEEKLY', 12),
            'monthly' => envInt('BACKUP_KEEP_MONTHLY', 12),
            _ => 0,
          };
          if (keep > 0) {
            await prune(dirPath, policy, keep);
          }
        }

        await jsonResponse(req, 200, {'ok': true, 'file': outfile});
      } finally {
        await lock.release(deleteFile: true);
      }
    }
  }());

  return server;
}
