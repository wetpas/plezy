import '../utils/log_redaction_manager.dart';
import 'fork_feedback_config.dart';

/// Second redaction pass for text that leaves the device in a fork report.
///
/// The in-memory log buffer is already redacted by [LogRedactionManager] when
/// a line is written, but only against the tokens and server URLs registered
/// *at that moment*: a line logged before sign-in keeps the host it mentions.
/// Running the manager again at send time closes that gap, and the extra
/// rules here cover what it leaves alone by design — the host of any URL it
/// was never told about.
abstract final class ForkFeedbackRedaction {
  static const String hostPlaceholder = '[REDACTED_HOST]';

  /// Public services whose host says nothing about the user's own servers.
  /// Kept readable because "which service answered" is half of most reports.
  static const List<String> _publicHostSuffixes = [
    'plex.tv',
    'plezy.app',
    'themoviedb.org',
    'tmdb.org',
    'trakt.tv',
    'simkl.com',
    'anilist.co',
    'myanimelist.net',
    'opensubtitles.com',
    'github.com',
    'githubusercontent.com',
  ];

  /// scheme, `://` (or mpv's escaped `\://`), optional user-info, host.
  static final RegExp _networkUrlPattern = RegExp(
    r'''\b((?:https?|wss?|rtsps?|rtmps?|s?ftp|smb|nfs|davs?)\\?://)((?:[^\s/@"'<>]*@)?)(\[[0-9a-fA-F:.%]+\]|[^\s/:?#"'<>(),{}\\@]+)''',
    caseSensitive: false,
  );

  /// What [LogRedactionManager] leaves of an IPv4 address (`192.x.x.5`).
  static final RegExp _maskedIpv4Pattern = RegExp(r'^\d{1,3}([.-])x\1x\1\d{1,3}$');

  /// Redacts [text] for transport: credentials, registered server URLs, and
  /// the host of every other network URL. Idempotent.
  static String redact(String text, {ForkFeedbackConfig? config}) {
    if (text.isEmpty) return text;
    var redacted = LogRedactionManager.redact(text);

    // The feedback channel's own secrets must never ride along in a report,
    // however they ended up in a log line.
    final feedback = config ?? ForkFeedbackConfig.current;
    final key = feedback.apiKey.trim();
    if (key.isNotEmpty) redacted = redacted.replaceAll(key, '[REDACTED_TOKEN]');

    return redacted.replaceAllMapped(_networkUrlPattern, (match) {
      final scheme = match.group(1)!;
      final userInfo = match.group(2)!;
      final host = match.group(3)!;
      final safeUserInfo = userInfo.isEmpty ? '' : '[REDACTED]@';
      if (_isHarmlessHost(host)) return '$scheme$safeUserInfo$host';
      return '$scheme$safeUserInfo$hostPlaceholder';
    });
  }

  /// Redacts every string in a diagnostics value, keeping its structure.
  static Object? redactValue(Object? value, {ForkFeedbackConfig? config}) {
    return switch (value) {
      final String text => redact(text, config: config),
      final Map<Object?, Object?> map => <String, Object?>{
        for (final entry in map.entries) entry.key.toString(): redactValue(entry.value, config: config),
      },
      final Iterable<Object?> items => [for (final item in items) redactValue(item, config: config)],
      _ => value,
    };
  }

  static bool _isHarmlessHost(String host) {
    final lower = host.toLowerCase();
    if (lower.contains('redacted')) return true;
    if (lower == 'localhost') return true;
    if (_maskedIpv4Pattern.hasMatch(lower)) return true;
    for (final suffix in _publicHostSuffixes) {
      if (lower == suffix || lower.endsWith('.$suffix')) return true;
    }
    return false;
  }
}
