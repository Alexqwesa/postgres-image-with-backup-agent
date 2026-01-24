import 'dart:convert';
import 'dart:io';

String _env(String key, [String def = '']) =>
    (Platform.environment[key]?.trim().isNotEmpty ?? false)
        ? Platform.environment[key]!.trim()
        : def;

Future<void> main(List<String> args) async {
  // Policy: daily | weekly | monthly | adhoc
  final policy = (args.isNotEmpty ? args.first : 'adhoc').toLowerCase();

  if (!['daily', 'weekly', 'monthly', 'adhoc'].contains(policy)) {
    stderr.writeln(
      'Invalid policy "$policy". '
      'Use: daily | weekly | monthly | adhoc',
    );
    exit(1);
  }

  // Agent URL (e.g. http://127.0.0.1:1804)
  final baseUrl = _env('BACKUP_AGENT_URL', 'http://127.0.0.1:1804');
  final uri = Uri.parse(baseUrl).replace(
    path: '/backup',
    queryParameters: {'reason': policy},
  );

  // Optional bearer token for agent
  final token = _env('BACKUP_AGENT_TOKEN', '');

  // Optional DB connection overrides (forwarded as headers)
  final pgHost = _env('POSTGRES_HOST', 'host.docker.internal');
  final pgPort = _env('POSTGRES_PORT', '5432');
  final pgDb = _env('POSTGRES_DB', 'postgres');
  final pgUser = _env('POSTGRES_USER', 'postgres');
  final pgPwd =
      _env('POSTGRES_PASSWORD', _env('PGPASSWORD', 'postgres'));

  stdout.writeln('Calling backup agent: $uri');

  final client = HttpClient();
  try {
    final req = await client.postUrl(uri);

    // Auth header
    if (token.isNotEmpty) {
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $token',
      );
    }

    // Forward DB headers if set
    if (pgHost.isNotEmpty) {
      req.headers.set('POSTGRES_HOST', pgHost);
    }
    if (pgPort.isNotEmpty) {
      req.headers.set('POSTGRES_PORT', pgPort);
    }
    if (pgDb.isNotEmpty) {
      req.headers.set('POSTGRES_DB', pgDb);
    }
    if (pgUser.isNotEmpty) {
      req.headers.set('POSTGRES_USER', pgUser);
    }
    if (pgPwd.isNotEmpty) {
      req.headers.set('POSTGRES_PASSWORD', pgPwd);
    }

    // Body is empty; server uses only query + headers
    req.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    req.write('{}');

    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    stdout.writeln('Status: ${resp.statusCode}');
    stdout.writeln('Response:');
    try {
      final decoded = jsonDecode(body);
      final pretty = const JsonEncoder.withIndent('  ').convert(decoded);
      stdout.writeln(pretty);
    } catch (_) {
      // Not JSON? just print raw
      stdout.writeln(body);
    }

    if (resp.statusCode >= 400) {
      exitCode = 1;
    }
  } on SocketException catch (e) {
    stderr.writeln('Connection error: $e');
    exitCode = 1;
  } catch (e) {
    stderr.writeln('Unexpected error: $e');
    exitCode = 1;
  } finally {
    client.close();
  }
}