import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ProcResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  ProcResult(this.exitCode, this.stdout, this.stderr, {this.timedOut = false});

  ProcResult.named({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });
}

Future<ProcResult> runPgDump({
  required String host,
  required String port,
  required String db,
  required String user,
  required String outfile,
  required String password,
  required Duration timeout,
}) async {
  final args = ['-h', host, '-p', port, '-U', user, '-d', db, '-F', 'c', '-f', outfile];
  final env = {...Platform.environment, 'PGPASSWORD': password};

  final process = await Process.start('pg_dump', args, environment: env);
  final outBuf = StringBuffer();
  final errBuf = StringBuffer();

  final outSub = process.stdout.transform(utf8.decoder).listen(outBuf.write);
  final errSub = process.stderr.transform(utf8.decoder).listen(errBuf.write);

  try {
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        Future<void>.delayed(const Duration(seconds: 2), () => process.kill(ProcessSignal.sigkill));
        return -1;
      },
    );

    await outSub.cancel();
    await errSub.cancel();

    if (code == -1) {
      stdout.writeln(' Failed to backup file: $outfile');
      return ProcResult(code, outBuf.toString(), errBuf.toString(), timedOut: true);
    }

    stdout.writeln(' Created backup file: $outfile');
    return ProcResult(code, outBuf.toString(), errBuf.toString());
  } catch (_) {
    await outSub.cancel();
    await errSub.cancel();
    return ProcResult(1, outBuf.toString(), errBuf.toString());
  }
}
