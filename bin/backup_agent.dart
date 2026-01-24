import 'dart:async';
import 'dart:io';

import 'package:postgres_image_with_backup_agent/helpers/backup_lock.dart';
import 'package:postgres_image_with_backup_agent/helpers/env.dart';
import 'package:postgres_image_with_backup_agent/helpers/http_json.dart';
import 'package:postgres_image_with_backup_agent/helpers/pgdump.dart';
import 'package:postgres_image_with_backup_agent/helpers/prune.dart';
import 'package:postgres_image_with_backup_agent/helpers/safe_file_part.dart';

Future<void> main() async {
  final port = envInt('BACKUP_AGENT_PORT', 1804);
  final server = await HttpServer.bind(InternetAddress.anyIPv6, port, v6Only: false);

  stdout.writeln('pgdump-agent (Dart) listening on :$port');

  final expected = envStr('BACKUP_AGENT_TOKEN');
  if (expected.isEmpty) {
    stdout.writeln('WARNING: BACKUP_AGENT_TOKEN is not set or empty!!!');
  }

  await for (final req in server) {
    // Routing
    if (req.uri.path == '/health') {
      jsonResponse(req, 200, {'ok': true, 'status': 'healthy'});
      continue;
    }
    if (req.method != 'POST' || req.uri.path != '/backup') {
      jsonResponse(req, 404, {'ok': false, 'error': 'not found'});
      continue;
    }

    // Auth
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (expected.isNotEmpty) {
      final token = auth.startsWith('Bearer ') ? auth.substring(7).trim() : '';
      if (token != expected) {
        jsonResponse(req, 401, {'ok': false, 'error': 'unauthorized'});
        continue;
      }
    }

    final backupDir = envStr('BACKUP_TO_DIR', '/backups');

    // Ensure backup dir is writable
    try {
      final dir = Directory(backupDir);
      await dir.create(recursive: true);
      final probe = File('${dir.path}/.write_probe');
      await probe.writeAsString(DateTime.now().toIso8601String());
      await probe.delete();
    } catch (e) {
      jsonResponse(req, 400, {
        'ok': false,
        'error': 'backup dir not writable',
        'detail': e.toString(),
      });
      continue;
    }

    // Lock (exclusive) + stale detection
    final pgDumpTimeoutSec = envInt('BACKUP_TIMEOUT_SECONDS', 6000); // 100 min
    final staleSec = envInt('LOCK_STALE_SECONDS', pgDumpTimeoutSec * 2);

    // If you want cross-container locking on same shared volume, put lock in backupDir:
    // final lockFile = File('$backupDir/.pgdump-agent.lock');
    final lockFile = File('${Directory.systemTemp.path}/pgdump-agent.lock');

    final lock = BackupLock(lockFile: lockFile, staleSec: staleSec);
    final lockRes = await lock.acquire();
    if (!lockRes.acquired) {
      jsonResponse(req, 409, {
        'ok': false,
        'error': 'backup already running',
        if (lockRes.lockSinceUtc != null) 'lockSinceUtc': lockRes.lockSinceUtc!.toIso8601String(),
      });
      continue;
    }

    // Policy: daily | weekly | monthly | adhoc
    final policyRaw = (req.uri.queryParameters['reason'] ?? 'adhoc').toLowerCase();
    final policy = switch (policyRaw) {
      'daily' || 'weekly' || 'monthly' || 'adhoc' => policyRaw,
      _ => 'adhoc',
    };

    try {
      // DB connection (envs)
      // Prefer standard libpq env vars first, then fallback to official postgres vars.
      var host = envStr('PGHOST', envStr('POSTGRES_HOST', '127.0.0.1'));
      var portStr = envStr('PGPORT', envStr('POSTGRES_PORT', '5432'));
      var dbname = envStr('PGDATABASE', envStr('POSTGRES_DB', 'postgres'));
      var user = envStr('PGUSER', envStr('POSTGRES_USER', 'postgres'));

      // Prefer PGPASSWORD; fallback to POSTGRES_PASSWORD for convenience.
      var pgpwd = envStr('PGPASSWORD', envStr('POSTGRES_PASSWORD', ''));

      // Gate overrides behind ALLOW_ANY_DB
      final allowAnyDb = envBool('ALLOW_ANY_DB', def: false);
      if (allowAnyDb) {
        host = req.headers.value('PGHOST') ?? req.headers.value('POSTGRES_HOST') ?? host;
        portStr = req.headers.value('PGPORT') ?? req.headers.value('POSTGRES_PORT') ?? portStr;
        dbname = req.headers.value('PGDATABASE') ?? req.headers.value('POSTGRES_DB') ?? dbname;
        user = req.headers.value('PGUSER') ?? req.headers.value('POSTGRES_USER') ?? user;
        pgpwd = req.headers.value('PGPASSWORD') ?? req.headers.value('POSTGRES_PASSWORD') ?? pgpwd;
      }

      if (pgpwd.isEmpty) {
        jsonResponse(req, 500, {'ok': false, 'error': 'PGPASSWORD not set'});
        continue;
      }

      if (pgpwd.isEmpty) {
        jsonResponse(req, 500, {'ok': false, 'error': 'PGPASSWORD not set'});
        continue;
      }

      if (int.tryParse(portStr) == null) {
        jsonResponse(req, 400, {'ok': false, 'error': 'invalid POSTGRES_PORT'});
        continue;
      }

      final ts = DateTime
          .now()
          .toUtc()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .split('.')
          .first; // YYYYmmddTHHMMSS

      // Filename parts (sanitized)
      final dbPart = safeFilePart(dbname, fallback: 'db');
      final hostPart = safeFilePart(host, fallback: 'host');
      final portPart = safeFilePart(portStr, fallback: 'p');
      final policyPart = safeFilePart(policy, fallback: 'adhoc');

      final outfile = '$backupDir/${dbPart}_${ts}_${hostPart}_${portPart}_${policyPart}.dump';

      final result = await runPgDump(
        host: host,
        port: portStr,
        db: dbname,
        user: user,
        outfile: outfile,
        password: pgpwd,
        timeout: Duration(seconds: pgDumpTimeoutSec),
      );

      if (result.timedOut) {
        jsonResponse(req, 504, {
          'ok': false,
          'error': 'pg_dump timed out',
          'stderr': result.stderr,
        });
        continue;
      }
      if (result.exitCode != 0) {
        jsonResponse(req, 500, {
          'ok': false,
          'error': 'pg_dump failed',
          'rc': result.exitCode,
          'stderr': result.stderr,
        });
        continue;
      }

      // Retention
      if (policy == 'daily' || policy == 'weekly' || policy == 'monthly') {
        final keep = switch (policy) {
          'daily' => envInt('BACKUP_KEEP_DAILY', 30),
          'weekly' => envInt('BACKUP_KEEP_WEEKLY', 12),
          'monthly' => envInt('BACKUP_KEEP_MONTHLY', 12),
          _ => 0,
        };
        if (keep > 0) {
          await pruneByCount(backupDir, policy, keep);
        }
      }

      jsonResponse(req, 200, {'ok': true, 'file': outfile});
    } finally {
      await lock.release(deleteFile: true);
    }
  }
}
