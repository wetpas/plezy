import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart' show httpClient;
import 'fork_feedback_config.dart';

/// The server's `kind` choices this client offers.
enum ForkFeedbackKind {
  bug('bug'),
  idea('idea'),

  /// Not offered as a choice: set by the startup-failure screen.
  crash('crash');

  const ForkFeedbackKind(this.wireValue);

  final String wireValue;
}

/// An image attached to a report. [bytes] must already be PNG, JPEG or WebP:
/// the server decides by magic bytes, not by name or declared type.
@immutable
class ForkFeedbackImage {
  const ForkFeedbackImage({required this.bytes, required this.extension, this.label});

  final Uint8List bytes;

  /// `.png`, `.jpg` or `.webp`.
  final String extension;

  /// What the user sees in the attachment list; never sent.
  final String? label;
}

@immutable
class ForkFeedbackReport {
  const ForkFeedbackReport({
    required this.kind,
    required this.description,
    this.intent = '',
    this.diagnostics = const {},
    this.images = const [],
  });

  final ForkFeedbackKind kind;
  final String description;
  final String intent;
  final Map<String, Object?> diagnostics;
  final List<ForkFeedbackImage> images;
}

/// Why a report did not arrive. The dialog turns each into its own sentence;
/// "it failed" alone has cost the reference client a lot of guessing.
enum ForkFeedbackFailure {
  /// No route to the server: offline, DNS, TLS, timeout.
  unreachable,

  /// 400 — the server names what it objects to in [ForkFeedbackSendResult.detail].
  rejected,

  /// 401/403 — the build's API key is not accepted.
  unauthorized,

  /// 413 — the attachments are too large for the server or a proxy before it.
  tooLarge,

  /// 429 — the per-key report limit; passes on its own.
  throttled,

  /// 5xx.
  serverError,

  /// Any other status.
  unexpected,
}

@immutable
class ForkFeedbackSendResult {
  const ForkFeedbackSendResult.success(String this.reference)
    : failure = null,
      statusCode = 201,
      detail = null,
      retryAfter = null;

  const ForkFeedbackSendResult.failed(ForkFeedbackFailure this.failure, {this.statusCode, this.detail, this.retryAfter})
    : reference = null;

  /// Short reference of the stored report (first eight hex digits of its id).
  final String? reference;
  final ForkFeedbackFailure? failure;
  final int? statusCode;

  /// The server's own explanation, when it gave one.
  final String? detail;

  /// How long the server asks to wait after a 429.
  final Duration? retryAfter;

  bool get isSuccess => failure == null;

  /// Whether trying again later can help without changing the report.
  bool get isRetryable => switch (failure) {
    ForkFeedbackFailure.unreachable ||
    ForkFeedbackFailure.throttled ||
    ForkFeedbackFailure.serverError ||
    ForkFeedbackFailure.unexpected => true,
    _ => false,
  };
}

/// Posts a report to `{FORK_FEEDBACK_URL}/api/feedback/`.
///
/// Multipart rather than JSON because images can ride along: the server caps
/// in-memory form data at 2.5 MB, while real file parts are exempt.
class ForkFeedbackSender {
  ForkFeedbackSender({this._config, this._client, this.timeout = const Duration(seconds: 60)});

  /// Server limits (`apps/feedback/storage.py`).
  static const int maxImages = 6;
  static const int maxImageBytes = 8 * 1024 * 1024;

  /// Server limits (`apps/feedback/serializers.py`).
  static const int minDescriptionChars = 3;
  static const int maxDescriptionChars = 5000;
  static const int maxIntentChars = 2000;

  /// How this client identifies itself; a `source` choice of the server.
  static const String source = 'plezy';

  final ForkFeedbackConfig? _config;
  final http.Client? _client;
  final Duration timeout;

  ForkFeedbackConfig get _effectiveConfig => _config ?? ForkFeedbackConfig.current;

  Future<ForkFeedbackSendResult> send(ForkFeedbackReport report) async {
    final config = _effectiveConfig;
    final endpoint = config.endpoint;
    if (endpoint == null || !config.isConfigured) {
      return const ForkFeedbackSendResult.failed(ForkFeedbackFailure.unauthorized);
    }

    final request = http.MultipartRequest('POST', endpoint)
      ..headers['X-API-Key'] = config.apiKey.trim()
      ..headers['Accept'] = 'application/json'
      ..fields['kind'] = report.kind.wireValue
      ..fields['source'] = source
      ..fields['intent'] = report.intent.trim()
      ..fields['description'] = report.description.trim()
      ..fields['diagnostics'] = jsonEncode(report.diagnostics);
    // Several parts of the same name: the server reads them as a list, and a
    // single part stays valid for its older single-image path.
    for (final image in report.images.take(maxImages)) {
      request.files.add(
        http.MultipartFile.fromBytes('screenshot', image.bytes, filename: 'screenshot${image.extension}'),
      );
    }

    try {
      final streamed = await (_client ?? httpClient.inner).send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed).timeout(timeout);
      return _interpret(response);
    } on TimeoutException {
      appLogger.w('Fork feedback: no answer within ${timeout.inSeconds}s');
      return const ForkFeedbackSendResult.failed(ForkFeedbackFailure.unreachable);
    } on IOException catch (error) {
      // The exception text names the host; the type is enough for a log.
      appLogger.w('Fork feedback: not sent (${error.runtimeType})');
      return const ForkFeedbackSendResult.failed(ForkFeedbackFailure.unreachable);
    } on http.ClientException catch (error) {
      appLogger.w('Fork feedback: not sent (${error.runtimeType})');
      return const ForkFeedbackSendResult.failed(ForkFeedbackFailure.unreachable);
    } catch (error) {
      appLogger.w('Fork feedback: not sent (${error.runtimeType})');
      return const ForkFeedbackSendResult.failed(ForkFeedbackFailure.unexpected);
    }
  }

  ForkFeedbackSendResult _interpret(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      final reference = _reference(response);
      appLogger.i('Fork feedback: report ${reference.isEmpty ? 'sent' : '#$reference sent'}');
      return ForkFeedbackSendResult.success(reference);
    }

    appLogger.w('Fork feedback: server answered $status');
    return switch (status) {
      400 => ForkFeedbackSendResult.failed(
        ForkFeedbackFailure.rejected,
        statusCode: status,
        detail: firstFieldError(_bodyText(response)),
      ),
      401 || 403 => ForkFeedbackSendResult.failed(ForkFeedbackFailure.unauthorized, statusCode: status),
      413 => ForkFeedbackSendResult.failed(ForkFeedbackFailure.tooLarge, statusCode: status),
      429 => ForkFeedbackSendResult.failed(
        ForkFeedbackFailure.throttled,
        statusCode: status,
        retryAfter: _retryAfter(response),
      ),
      >= 500 => ForkFeedbackSendResult.failed(ForkFeedbackFailure.serverError, statusCode: status),
      _ => ForkFeedbackSendResult.failed(ForkFeedbackFailure.unexpected, statusCode: status),
    };
  }

  static String _bodyText(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  /// `short_id` as the server reports it, else the first eight hex digits of
  /// the UUID `id`. Empty when the answer carries neither.
  static String _reference(http.Response response) {
    try {
      final body = jsonDecode(_bodyText(response));
      if (body is Map) {
        final shortId = body['short_id'];
        if (shortId is String && shortId.trim().isNotEmpty) return shortId.trim();
        final id = body['id']?.toString().replaceAll('-', '') ?? '';
        if (id.isNotEmpty) return id.length <= 8 ? id : id.substring(0, 8);
      }
    } catch (_) {}
    return '';
  }

  static Duration? _retryAfter(http.Response response) {
    final seconds = int.tryParse(response.headers['retry-after']?.trim() ?? '');
    return seconds == null || seconds <= 0 ? null : Duration(seconds: seconds);
  }

  /// First message of a DRF error body (`{"screenshot": ["…"]}` or
  /// `{"detail": "…"}`), or null when there is none worth showing.
  @visibleForTesting
  static String? firstFieldError(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final detail = json['detail'];
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      for (final value in json.values) {
        if (value is List && value.isNotEmpty && value.first.toString().trim().isNotEmpty) {
          return value.first.toString().trim();
        }
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    } catch (_) {}
    return null;
  }
}
