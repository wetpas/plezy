import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One part of a parsed `multipart/form-data` body.
class MultipartPart {
  MultipartPart({required this.headers, required this.bytes});

  final Map<String, String> headers;
  final Uint8List bytes;

  String get disposition => headers['content-disposition'] ?? '';
  String? get name => RegExp(r'\bname="([^"]*)"').firstMatch(disposition)?.group(1);
  String? get filename => RegExp(r'\bfilename="([^"]*)"').firstMatch(disposition)?.group(1);
  String get text => utf8.decode(bytes);
}

/// Parses the body the way a server would: by the boundary of the request's
/// own Content-Type header, byte for byte.
List<MultipartPart> parseMultipart(http.Request request) {
  final contentType = request.headers['content-type'] ?? '';
  final boundary = RegExp(r'boundary=("?)([^";]+)\1').firstMatch(contentType)?.group(2);
  if (boundary == null) throw StateError('no multipart boundary in "$contentType"');

  // latin1 maps bytes to code units one to one, so string offsets are byte offsets.
  final body = latin1.decode(request.bodyBytes);
  final parts = <MultipartPart>[];
  for (final raw in body.split('--$boundary')) {
    if (raw.isEmpty || raw.startsWith('--')) continue;
    final section = raw.startsWith('\r\n') ? raw.substring(2) : raw;
    final split = section.indexOf('\r\n\r\n');
    if (split < 0) continue;
    final headers = <String, String>{};
    for (final line in section.substring(0, split).split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon > 0) headers[line.substring(0, colon).trim().toLowerCase()] = line.substring(colon + 1).trim();
    }
    var content = section.substring(split + 4);
    if (content.endsWith('\r\n')) content = content.substring(0, content.length - 2);
    parts.add(MultipartPart(headers: headers, bytes: latin1.encode(content)));
  }
  return parts;
}

/// Smallest byte strings the server's magic-byte check accepts.
final Uint8List pngBytes = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0,
  1,
  2,
  3,
  255,
  13,
  10,
]);
final Uint8List jpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 9, 8, 7]);
final Uint8List webpBytes = Uint8List.fromList([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits, 1]);
