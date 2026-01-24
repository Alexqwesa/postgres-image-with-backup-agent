import 'dart:convert';
import 'dart:io';

Future<void> jsonResponse(HttpRequest req, int status, Map<String, dynamic> body) async {
  final bytes = utf8.encode(jsonEncode(body));

  final res = req.response;
  res.statusCode = status;
  res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
  res.headers.set(HttpHeaders.contentLengthHeader, bytes.length);

  res.add(bytes);
  await res.close();
}