import 'dart:io';

Future<void> pruneByCount(String dir, String policy, int keep) async {
  final d = Directory(dir);
  final files = <File>[];

  await for (final ent in d.list(followLinks: false)) {
    if (ent is! File) continue;
    if (ent.path.endsWith('_$policy.dump')) {
      files.add(ent);
    }
  }

  // Sort newest first
  files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

  final deletedCount = files.length > keep ? files.length - keep : 0;
  for (var i = keep; i < files.length; i++) {
    try {
      await files[i].delete();
    } catch (_) {}
  }

  stdout.writeln(' Pruned $deletedCount files for policy: $policy');
}
