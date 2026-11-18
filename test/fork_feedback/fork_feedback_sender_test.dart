import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/fork_feedback/fork_feedback_config.dart';
import 'package:plezy/fork_feedback/fork_feedback_images.dart';
import 'package:plezy/fork_feedback/fork_feedback_sender.dart';
import 'package:plezy/utils/app_logger.dart';

import 'multipart_test_utils.dart';

const _config = ForkFeedbackConfig(baseUrl: 'https://vibe.example.org', apiKey: 'vs_test_key_123');

const _created = {
  'id': '8c814ae5-1f0b-4c57-9d5e-0a1b2c3d4e5f',
  'short_id': '8c814ae5',
  'kind': 'bug',
  'source': 'plezy',
  'notified': true,
};

http.Response _json(Object body, int status, {Map<String, String> headers = const {}}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

void main() {
  setUp(MemoryLogOutput.clearLogs);
  tearDown(MemoryLogOutput.clearLogs);

  group('ForkFeedbackConfig', () {
    test('is hidden unless both the URL and the key are set', () {
      expect(ForkFeedbackConfig.disabled.isConfigured, isFalse);
      expect(const ForkFeedbackConfig(baseUrl: 'https://vibe.example.org', apiKey: '').isConfigured, isFalse);
      expect(const ForkFeedbackConfig(baseUrl: '', apiKey: 'key').isConfigured, isFalse);
      expect(const ForkFeedbackConfig(baseUrl: '   ', apiKey: ' key ').isConfigured, isFalse);
      expect(const ForkFeedbackConfig(baseUrl: 'vibe.example.org', apiKey: 'key').isConfigured, isFalse);
      expect(const ForkFeedbackConfig(baseUrl: 'ftp://vibe.example.org', apiKey: 'key').isConfigured, isFalse);
      expect(_config.isConfigured, isTrue);
    });

    test('a build without dart-defines has no feedback channel', () {
      expect(ForkFeedbackConfig.current.isConfigured, isFalse);
    });

    test('builds the endpoint from the base URL', () {
      Uri? endpoint(String base) => ForkFeedbackConfig(baseUrl: base, apiKey: 'k').endpoint;

      expect(endpoint('https://vibe.example.org'), Uri.parse('https://vibe.example.org/api/feedback/'));
      expect(endpoint('https://vibe.example.org/'), Uri.parse('https://vibe.example.org/api/feedback/'));
      expect(endpoint(' http://10.0.0.11:8000// '), Uri.parse('http://10.0.0.11:8000/api/feedback/'));
      expect(endpoint('https://example.org/vibe/'), Uri.parse('https://example.org/vibe/api/feedback/'));
      expect(endpoint('https://user:pw@example.org/?x=1#frag'), Uri.parse('https://example.org/api/feedback/'));
    });
  });

  group('ForkFeedbackSender', () {
    test('posts the report as multipart with the API key header', () async {
      late http.Request captured;
      final sender = ForkFeedbackSender(
        config: _config,
        client: MockClient((request) async {
          captured = request;
          return _json(_created, 201);
        }),
      );

      final result = await sender.send(
        ForkFeedbackReport(
          kind: ForkFeedbackKind.idea,
          description: '  Die Wiedergabe hängt nach 5 Sekunden – „Überspringen“ fehlt 🚀  ',
          intent: ' Einen Film starten ',
          diagnostics: const {
            'name': 'Jörg',
            'platform': 'Android TV',
            'logs': ['[12:00:00.000] [INFO] eins', '[12:00:01.000] [ERROR] zwei'],
          },
          images: [
            ForkFeedbackImage(bytes: pngBytes, extension: '.png'),
            ForkFeedbackImage(bytes: jpegBytes, extension: '.jpg'),
          ],
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.reference, '8c814ae5');

      expect(captured.method, 'POST');
      expect(captured.url, Uri.parse('https://vibe.example.org/api/feedback/'));
      expect(captured.headers['X-API-Key'], 'vs_test_key_123');
      expect(captured.headers['content-type'], startsWith('multipart/form-data; boundary='));

      final parts = parseMultipart(captured);
      final fields = {for (final part in parts.where((part) => part.filename == null)) part.name: part.text};
      expect(fields.keys, unorderedEquals(['kind', 'source', 'intent', 'description', 'diagnostics']));
      expect(fields['kind'], 'idea');
      expect(fields['source'], 'plezy');
      expect(fields['intent'], 'Einen Film starten');
      expect(fields['description'], 'Die Wiedergabe hängt nach 5 Sekunden – „Überspringen“ fehlt 🚀');
      expect(jsonDecode(fields['diagnostics']!), {
        'name': 'Jörg',
        'platform': 'Android TV',
        'logs': ['[12:00:00.000] [INFO] eins', '[12:00:01.000] [ERROR] zwei'],
      });

      final files = parts.where((part) => part.filename != null).toList();
      expect(files.map((part) => part.name), ['screenshot', 'screenshot']);
      expect(files.map((part) => part.filename), ['screenshot.png', 'screenshot.jpg']);
      expect(files[0].bytes, pngBytes);
      expect(files[1].bytes, jpegBytes);
    });

    test('sends no screenshot part and an empty intent when there is none', () async {
      late http.Request captured;
      final sender = ForkFeedbackSender(
        config: _config,
        client: MockClient((request) async {
          captured = request;
          return _json(_created, 201);
        }),
      );

      await sender.send(const ForkFeedbackReport(kind: ForkFeedbackKind.bug, description: 'kaputt'));

      final parts = parseMultipart(captured);
      expect(parts.where((part) => part.filename != null), isEmpty);
      final fields = {for (final part in parts) part.name: part.text};
      expect(fields['kind'], 'bug');
      expect(fields['intent'], '');
      expect(fields['diagnostics'], '{}');
    });

    test('never sends more images than the server accepts', () async {
      late http.Request captured;
      final sender = ForkFeedbackSender(
        config: _config,
        client: MockClient((request) async {
          captured = request;
          return _json(_created, 201);
        }),
      );

      await sender.send(
        ForkFeedbackReport(
          kind: ForkFeedbackKind.bug,
          description: 'viele Bilder',
          images: [for (var i = 0; i < 9; i++) ForkFeedbackImage(bytes: pngBytes, extension: '.png')],
        ),
      );

      expect(parseMultipart(captured).where((part) => part.name == 'screenshot'), hasLength(6));
    });

    test('derives the reference from the UUID when the server sends no short id', () async {
      final sender = ForkFeedbackSender(
        config: _config,
        client: MockClient((_) async => _json({'id': 'A1B2C3D4-0000-4000-8000-000000000000'}, 201)),
      );

      final result = await sender.send(const ForkFeedbackReport(kind: ForkFeedbackKind.bug, description: 'abc'));

      expect(result.isSuccess, isTrue);
      expect(result.reference, 'A1B2C3D4');
    });

    Future<ForkFeedbackSendResult> sendAgainst(MockClientHandler handler, {Duration? timeout}) {
      final sender = ForkFeedbackSender(
        config: _config,
        client: MockClient(handler),
        timeout: timeout ?? const Duration(seconds: 60),
      );
      return sender.send(const ForkFeedbackReport(kind: ForkFeedbackKind.bug, description: 'abc'));
    }

    test('400 carries the field message of the server', () async {
      final result = await sendAgainst(
        (_) async => _json({
          'screenshot': ['Der Anhang ist kein Bild (PNG, JPEG oder WebP).'],
        }, 400),
      );

      expect(result.failure, ForkFeedbackFailure.rejected);
      expect(result.statusCode, 400);
      expect(result.detail, 'Der Anhang ist kein Bild (PNG, JPEG oder WebP).');
      expect(result.isRetryable, isFalse);
    });

    test('400 without a readable body is still a rejection', () async {
      final result = await sendAgainst((_) async => http.Response('<html>Bad Request</html>', 400));

      expect(result.failure, ForkFeedbackFailure.rejected);
      expect(result.detail, isNull);
    });

    test('401 and 403 mean the API key is not accepted', () async {
      for (final status in [401, 403]) {
        final result = await sendAgainst((_) async => _json({'detail': 'Ungültiger API-Schlüssel.'}, status));
        expect(result.failure, ForkFeedbackFailure.unauthorized, reason: '$status');
        expect(result.statusCode, status);
        expect(result.isRetryable, isFalse);
      }
    });

    test('413 is reported as too large', () async {
      final result = await sendAgainst((_) async => http.Response('', 413));
      expect(result.failure, ForkFeedbackFailure.tooLarge);
    });

    test('429 is throttling and keeps the wait the server asks for', () async {
      final result = await sendAgainst(
        (_) async => _json(
          {'detail': 'Anfrage wurde gedrosselt. Erwarte Verfügbarkeit in 1872 Sekunden.'},
          429,
          headers: {'retry-after': '1872'},
        ),
      );

      expect(result.failure, ForkFeedbackFailure.throttled);
      expect(result.retryAfter, const Duration(seconds: 1872));
      expect(result.isRetryable, isTrue);
    });

    test('5xx is a server error, other statuses are unexpected', () async {
      final serverError = await sendAgainst((_) async => http.Response('Bad Gateway', 502));
      expect(serverError.failure, ForkFeedbackFailure.serverError);
      expect(serverError.statusCode, 502);
      expect(serverError.isRetryable, isTrue);

      final notFound = await sendAgainst((_) async => http.Response('Not Found', 404));
      expect(notFound.failure, ForkFeedbackFailure.unexpected);
      expect(notFound.statusCode, 404);
    });

    test('offline, transport errors and timeouts are all "unreachable"', () async {
      final offline = await sendAgainst((_) async => throw const SocketException('Failed host lookup'));
      expect(offline.failure, ForkFeedbackFailure.unreachable);
      expect(offline.isRetryable, isTrue);

      final transport = await sendAgainst((_) async => throw http.ClientException('Connection reset'));
      expect(transport.failure, ForkFeedbackFailure.unreachable);

      final tls = await sendAgainst((_) async => throw const HandshakeException('bad certificate'));
      expect(tls.failure, ForkFeedbackFailure.unreachable);

      final slow = await sendAgainst(
        (_) => Completer<http.Response>().future,
        timeout: const Duration(milliseconds: 20),
      );
      expect(slow.failure, ForkFeedbackFailure.unreachable);
    });

    test('does not contact anything when the build is not configured', () async {
      var requests = 0;
      final sender = ForkFeedbackSender(
        config: ForkFeedbackConfig.disabled,
        client: MockClient((_) async {
          requests++;
          return _json(_created, 201);
        }),
      );

      final result = await sender.send(const ForkFeedbackReport(kind: ForkFeedbackKind.bug, description: 'abc'));

      expect(result.isSuccess, isFalse);
      expect(requests, 0);
    });

    test('never writes the API key or the server address to the log', () async {
      await sendAgainst((_) async => _json(_created, 201));
      await sendAgainst((_) async => http.Response('nope', 500));
      await sendAgainst((_) async => throw const SocketException('Failed host lookup: vibe.example.org'));

      final logged = MemoryLogOutput.getLogs().map((entry) => '${entry.message} ${entry.error ?? ''}').join('\n');
      expect(logged, contains('#8c814ae5'));
      expect(logged, isNot(contains('vs_test_key_123')));
      expect(logged, isNot(contains('vibe.example.org')));
    });

    test('reads the first message out of a DRF error body', () {
      expect(ForkFeedbackSender.firstFieldError('{"detail": "Nicht erlaubt."}'), 'Nicht erlaubt.');
      expect(
        ForkFeedbackSender.firstFieldError('{"description": ["Bitte beschreibe kurz, was passiert ist."]}'),
        'Bitte beschreibe kurz, was passiert ist.',
      );
      expect(ForkFeedbackSender.firstFieldError('{"kind": "ungültig"}'), 'ungültig');
      expect(ForkFeedbackSender.firstFieldError('not json'), isNull);
      expect(ForkFeedbackSender.firstFieldError('[]'), isNull);
      expect(ForkFeedbackSender.firstFieldError(''), isNull);
      expect(ForkFeedbackSender.firstFieldError(null), isNull);
    });
  });

  group('images', () {
    test('recognises exactly the formats the server accepts', () {
      expect(sniffForkFeedbackImage(pngBytes), '.png');
      expect(sniffForkFeedbackImage(jpegBytes), '.jpg');
      expect(sniffForkFeedbackImage(webpBytes), '.webp');
      expect(sniffForkFeedbackImage(Uint8List.fromList('GIF89a....'.codeUnits)), isNull);
      expect(sniffForkFeedbackImage(Uint8List.fromList([0x89, 0x50])), isNull);
      expect(sniffForkFeedbackImage(Uint8List(0)), isNull);
    });

    test('passes an accepted image through untouched', () async {
      var transcodes = 0;
      final image = await prepareForkFeedbackImage(
        jpegBytes,
        label: 'foto.jpeg',
        transcode: (bytes, {required maxDimension}) async {
          transcodes++;
          return null;
        },
      );

      expect(image.bytes, jpegBytes);
      expect(image.extension, '.jpg');
      expect(image.label, 'foto.jpeg');
      expect(transcodes, 0);
    });

    test('re-encodes a format the server refuses', () async {
      final heic = Uint8List.fromList([0, 0, 0, 24, ...'ftypheic'.codeUnits]);
      final image = await prepareForkFeedbackImage(heic, transcode: (bytes, {required maxDimension}) async => pngBytes);

      expect(image.bytes, pngBytes);
      expect(image.extension, '.png');
    });

    test('shrinks an oversized image step by step, then gives up', () async {
      final huge = Uint8List(ForkFeedbackSender.maxImageBytes + 1)..setRange(0, 8, pngBytes);
      final requested = <int>[];
      final image = await prepareForkFeedbackImage(
        huge,
        transcode: (bytes, {required maxDimension}) async {
          requested.add(maxDimension);
          return maxDimension > 2000 ? huge : pngBytes;
        },
      );
      expect(requested, [2560, 1280]);
      expect(image.bytes, pngBytes);

      await expectLater(
        prepareForkFeedbackImage(huge, transcode: (bytes, {required maxDimension}) async => huge),
        throwsA(
          isA<ForkFeedbackImageException>().having((e) => e.problem, 'problem', ForkFeedbackImageProblem.tooLarge),
        ),
      );
    });

    test('names the problem when a file is not an image at all', () async {
      await expectLater(
        prepareForkFeedbackImage(
          Uint8List.fromList('just text'.codeUnits),
          transcode: (bytes, {required maxDimension}) async => null,
        ),
        throwsA(
          isA<ForkFeedbackImageException>().having((e) => e.problem, 'problem', ForkFeedbackImageProblem.notAnImage),
        ),
      );
      await expectLater(
        prepareForkFeedbackImage(Uint8List(0)),
        throwsA(
          isA<ForkFeedbackImageException>().having((e) => e.problem, 'problem', ForkFeedbackImageProblem.unreadable),
        ),
      );
    });
  });
}
