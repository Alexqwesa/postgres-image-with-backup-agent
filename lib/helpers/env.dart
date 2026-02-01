import 'dart:io';

String envStr(String key, [String def = '']) =>
    (Platform.environment[key]?.trim().isNotEmpty ?? false)
        ? Platform.environment[key]!.trim()
        : def;

int envInt(String key, int def) {
  final s = envStr(key, '');
  if (s.isEmpty) return def;
  final i = int.tryParse(s);
  if (i == null) {
    // stdout.writeln('WARNING: environment variable $key="$s" is not a valid integer. Using default: $def');
    return def;
  }
  return i;
}

bool envBool(String key, {bool def = false}) {
  final v = envStr(key, '');
  if (v.isEmpty) return def;
  final lc = v.toLowerCase();
  if (['1', 'true', 'yes', 'y', 'on'].contains(lc)) return true;
  if (['0', 'false', 'no', 'n', 'off'].contains(lc)) return false;
  // stdout.writeln('WARNING: environment variable $key="$v" is not a valid boolean. Using default: $def');
  return def;
}
