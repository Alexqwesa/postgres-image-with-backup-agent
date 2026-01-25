import 'dart:async';

/// Reusable polling helper.
/// - calls [check] until it returns a non-null value (or true if you use bool)
/// - waits [step] between attempts
/// - throws TimeoutException with [what] on timeout
Future<T> waitUntil<T>(
  Future<T?> Function() check, {
  required String what,
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 300),
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? lastErr;

  while (DateTime.now().isBefore(deadline)) {
    try {
      final v = await check();
      if (v != null) return v;
      lastErr = null;
    } catch (e) {
      lastErr = e;
    }
    await Future<void>.delayed(step);
  }

  throw TimeoutException(lastErr == null ? what : '$what (last error: $lastErr)', timeout);
}
