import 'dart:io';

import 'package:test/test.dart';
import 'package:postgres_image_with_backup_agent/helpers/prune.dart';

void main() {
  test('pruneByCount keeps newest N files for a policy', () async {
    final dir = Directory.systemTemp.createTempSync('prune-test-');

    // Helper to create a file with controlled modified time
    Future<File> mk(String name, DateTime mtime) async {
      final f = File('${dir.path}/$name');
      await f.writeAsString(name);
      await f.setLastModified(mtime);
      return f;
    }

    // Create 5 matching "daily" dumps with ascending timestamps
    // Older -> newer
    final base = DateTime(2026, 1, 1, 0, 0, 0);
    final f0 = await mk('db_0_host_5432_daily.dump', base.add(const Duration(minutes: 0)));
    final f1 = await mk('db_1_host_5432_daily.dump', base.add(const Duration(minutes: 1)));
    final f2 = await mk('db_2_host_5432_daily.dump', base.add(const Duration(minutes: 2)));
    final f3 = await mk('db_3_host_5432_daily.dump', base.add(const Duration(minutes: 3)));
    final f4 = await mk('db_4_host_5432_daily.dump', base.add(const Duration(minutes: 4)));

    // Non-matching files (must be untouched)
    final weekly = await mk('db_x_host_5432_weekly.dump', base.add(const Duration(minutes: 10)));
    final other = await mk('notes.txt', base.add(const Duration(minutes: 10)));
    final almost = await mk('db_bad_host_5432_daily.sql', base.add(const Duration(minutes: 10)));

    // Keep only 2 newest daily
    await pruneByCount(dir.path, 'daily', 2);

    // Newest two daily should remain: f4, f3
    expect(f4.existsSync(), isTrue);
    expect(f3.existsSync(), isTrue);

    // Older daily should be deleted: f2, f1, f0
    expect(f2.existsSync(), isFalse);
    expect(f1.existsSync(), isFalse);
    expect(f0.existsSync(), isFalse);

    // Non-matching should remain
    expect(weekly.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
    expect(almost.existsSync(), isTrue);

    dir.deleteSync(recursive: true);
  });

  test('pruneByCount does nothing when files <= keep', () async {
    final dir = Directory.systemTemp.createTempSync('prune-test-');
    final f0 = File('${dir.path}/a_daily.dump')..writeAsStringSync('x');
    final f1 = File('${dir.path}/b_daily.dump')..writeAsStringSync('y');

    await pruneByCount(dir.path, 'daily', 5);

    expect(f0.existsSync(), isTrue);
    expect(f1.existsSync(), isTrue);

    dir.deleteSync(recursive: true);
  });

  test('pruneByCount keep=0 deletes all matching', () async {
    final dir = Directory.systemTemp.createTempSync('prune-test-');
    final f0 = File('${dir.path}/a_daily.dump')..writeAsStringSync('x');
    final f1 = File('${dir.path}/b_daily.dump')..writeAsStringSync('y');
    final other = File('${dir.path}/c_weekly.dump')..writeAsStringSync('z');

    await pruneByCount(dir.path, 'daily', 0);

    expect(f0.existsSync(), isFalse);
    expect(f1.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);

    dir.deleteSync(recursive: true);
  });
}
