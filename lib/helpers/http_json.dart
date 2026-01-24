import 'dart:convert';
import 'dart:io';

void jsonResponse(HttpRequest req, int status, Map<String, Object?> obj) {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(obj));
  req.response.close();
}
