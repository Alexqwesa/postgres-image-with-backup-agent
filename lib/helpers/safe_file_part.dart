


import 'dart:io';

String safeFilePart(
  String input, {
  int maxLen = 80,
  String fallback = 'x',
}) {
  var s = input.trim();

  // Replace any unsafe char with underscore
  s = s.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');

  // Remove path-ish / sneaky bits
  s = s.replaceAll(RegExp(r'[.]{2,}'), '.'); // collapse ".."
  s = s.replaceAll(RegExp(r'^[_\.]+|[_\.]+$'), ''); // trim underscores/dots
  s = s.replaceAll(RegExp(r'_{2,}'), '_'); // collapse

  if (s.isEmpty) s = fallback;
  if (s.length > maxLen) s = s.substring(0, maxLen);

  // Windows reserved device names (if you ever run on Windows)
  const reserved = {
    'CON','PRN','AUX','NUL',
    'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
    'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9',
  };
  final upper = s.toUpperCase();
  if (Platform.isWindows && reserved.contains(upper)) {
    s = '${s}_';
  }

  return s;
}
