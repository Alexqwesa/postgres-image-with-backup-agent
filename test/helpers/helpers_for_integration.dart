import 'dart:convert';
import 'dart:io';

import 'wait_until.dart';

Future<void> waitPgReady({
  required String container,
  Duration timeout = const Duration(seconds: 60),
}) async {
  await waitUntil<bool>(
    () async {
      final r = await Process.run('docker', [
        'exec',
        container,
        'pg_isready',
        '-U',
        'postgres',
        '-d',
        'postgres',
      ], runInShell: true);
      return r.exitCode == 0 ? true : null;
    },
    what: 'Postgres not ready',
    timeout: timeout,
    step: const Duration(seconds: 1),
  );
}

Future<int> pickFreePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

class HttpRes {
  final int statusCode;
  final String body;

  HttpRes(this.statusCode, this.body);
}

Future<HttpRes> httpPostJson(Uri uri, {Map<String, String>? headers}) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(uri);
    headers?.forEach(req.headers.set);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.add(utf8.encode('{}'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return HttpRes(res.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

Future<File> waitForDumpFile(
  Directory dir, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  return waitUntil<File>(
    () async {
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.dump')).toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

      return files.isNotEmpty ? files.first : null;
    },
    what: 'No .dump file created',
    timeout: timeout,
    step: const Duration(milliseconds: 300),
  );
}

Future<void> waitHttpHealthy(Uri base, {Duration timeout = const Duration(seconds: 30)}) async {
  final client = HttpClient();
  try {
    await waitUntil<bool>(
      () async {
        final req = await client.getUrl(base.replace(path: '/health'));
        final res = await req.close();
        await res.drain();
        return res.statusCode == 200 ? true : null;
      },
      what: 'Agent not healthy',
      timeout: timeout,
      step: const Duration(milliseconds: 300),
    );
  } finally {
    client.close(force: true);
  }
}

Future<String> dockerOut(List<String> args) async {
  final r = await Process.run('docker', args, runInShell: true);
  return (r.stdout?.toString() ?? '') + (r.stderr?.toString() ?? '');
}
