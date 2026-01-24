import 'dart:async';
import 'dart:io';

class BackupLock {
  BackupLock({
    required this.lockFile,
    required this.staleSec,
    this.tryLockTimeout = const Duration(seconds: 1),
  });

  final File lockFile;
  final int staleSec;
  final Duration tryLockTimeout;

  RandomAccessFile? _raf;

  RandomAccessFile? get raf => _raf;

  Future<DateTime?> _readTimestamp() async {
    try {
      final txt = await lockFile.readAsString();
      final s = txt.trim();
      if (s.isEmpty) return null;
      return DateTime.tryParse(s);
    } catch (_) {
      return null;
    }
  }

  Future<void> _tryLockOnce() async {
    _raf = await lockFile.open(mode: FileMode.write);
    await _raf!.lock(FileLock.exclusive).timeout(tryLockTimeout);
    await _raf!.setPosition(0);
    await _raf!.truncate(0);
    await _raf!.writeString(DateTime.now().toUtc().toIso8601String());
  }

  /// Returns:
  /// - acquired: true if lock acquired
  /// - lockSinceUtc: timestamp from file if we couldn't acquire due to active lock
  /// - staleCleared: true if we detected and cleared a stale lock and then acquired
  Future<({bool acquired, DateTime? lockSinceUtc, bool staleCleared})> acquire() async {
    try {
      await _tryLockOnce();
      return (acquired: true, lockSinceUtc: null, staleCleared: false);
    } on TimeoutException {
      await _raf?.close();
      _raf = null;

      final ts = await _readTimestamp();
      final now = DateTime.now().toUtc();
      final isStale = ts != null && now.difference(ts).inSeconds > staleSec;

      if (!isStale) {
        return (acquired: false, lockSinceUtc: ts, staleCleared: false);
      }

      // Stale: delete and retry once
      try {
        await lockFile.delete();
      } catch (_) {}

      try {
        await _tryLockOnce();
        return (acquired: true, lockSinceUtc: ts, staleCleared: true);
      } on TimeoutException {
        await _raf?.close();
        _raf = null;
        return (acquired: false, lockSinceUtc: ts, staleCleared: true);
      }
    }
  }

  Future<void> release({bool deleteFile = true}) async {
    try {
      await _raf?.unlock();
    } catch (_) {}
    try {
      await _raf?.close();
    } catch (_) {}
    _raf = null;

    if (deleteFile) {
      try {
        await lockFile.delete();
      } catch (_) {}
    }
  }
}
