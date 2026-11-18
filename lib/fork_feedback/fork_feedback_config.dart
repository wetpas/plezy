import 'package:flutter/foundation.dart';

/// Build-time configuration of the fork's "Report a problem" channel.
///
/// Reports go to the fork owner's own server, never to an upstream Plezy
/// service. Both values are baked in with `--dart-define`:
///
/// ```
/// flutter build apk \
///   --dart-define=FORK_FEEDBACK_URL=https://music.example.org \
///   --dart-define=FORK_FEEDBACK_KEY=<api key>
/// ```
///
/// A build without both values has no feedback feature at all: every entry
/// point checks [isConfigured] and stays hidden.
@immutable
class ForkFeedbackConfig {
  const ForkFeedbackConfig({required this.baseUrl, required this.apiKey});

  /// A configuration that hides the feature.
  static const ForkFeedbackConfig disabled = ForkFeedbackConfig(baseUrl: '', apiKey: '');

  static const ForkFeedbackConfig _fromEnvironment = ForkFeedbackConfig(
    baseUrl: String.fromEnvironment('FORK_FEEDBACK_URL'),
    apiKey: String.fromEnvironment('FORK_FEEDBACK_KEY'),
  );

  static ForkFeedbackConfig? _debugOverride;

  /// The configuration every entry point reads.
  static ForkFeedbackConfig get current => _debugOverride ?? _fromEnvironment;

  /// Test-only: replace the build-time configuration. Pass null to restore it.
  @visibleForTesting
  static set debugOverride(ForkFeedbackConfig? value) => _debugOverride = value;

  /// Base URL of the receiving server, without the `/api/feedback/` path.
  final String baseUrl;

  /// Sent as `X-API-Key`. Never logged and never part of a report.
  final String apiKey;

  /// The endpoint reports are posted to, or null when [baseUrl] is unusable.
  Uri? get endpoint {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) return null;
    final base = Uri.tryParse(trimmed);
    if (base == null || base.host.isEmpty || (base.scheme != 'https' && base.scheme != 'http')) return null;
    final path = base.path.replaceFirst(RegExp(r'/+$'), '');
    // Rebuilt rather than `replace`d: a query, fragment or user-info on the
    // configured value must not travel with every report.
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '$path/api/feedback/',
    );
  }

  bool get isConfigured => apiKey.trim().isNotEmpty && endpoint != null;
}
