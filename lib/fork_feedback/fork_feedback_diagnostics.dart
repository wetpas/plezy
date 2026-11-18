import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../main.dart' show gitCommit;
import '../profiles/active_profile_provider.dart';
import '../profiles/profile.dart';
import '../providers/seerr_account_provider.dart';
import '../services/device_performance.dart';
import '../services/log_upload_service.dart';
import '../services/startup_diagnostics.dart';
import '../services/video_decode_capabilities.dart';
import '../utils/app_logger.dart';
import '../utils/app_version.dart';
import '../utils/formatters.dart';
import '../utils/platform_detector.dart';
import 'fork_feedback_config.dart';
import 'fork_feedback_redaction.dart';

/// Limits of the receiving server (`apps/feedback/diagnostics.py`) and of the
/// reference client (`FeedbackCollector.kt`). Mirrored here so a report is
/// trimmed on the device, where the newest lines can be chosen deliberately,
/// rather than halved blindly on arrival.
abstract final class ForkFeedbackLimits {
  /// Lines kept per log section — one section up to the moment the dialog
  /// opened, one for what happened while the user was typing.
  static const int logLines = 300;

  /// Characters kept per log line.
  static const int logLineChars = 240;

  /// Frames kept of a single stack trace, so two errors cannot use up the
  /// whole section.
  static const int stackTraceLines = 12;

  /// Byte budgets of the two log sections before JSON encoding.
  static const int logBytes = 96 * 1024;
  static const int logAfterBytes = 40 * 1024;

  /// The server shrinks anything above 160 KiB; stay below it with room for
  /// Python's wider JSON separators.
  static const int diagnosticsBytes = 150 * 1024;

  /// The server's cap on a single diagnostics string.
  static const int stringChars = 8000;
}

/// What the running app knows about itself that needs a [BuildContext] to
/// read. Captured once, when the dialog is opened.
@immutable
class ForkFeedbackAppState {
  const ForkFeedbackAppState({
    this.screen,
    this.profileName,
    this.backends = const [],
    this.seerrConnected,
    this.formFactor,
  });

  /// The screen the report was started from.
  final String? screen;

  /// Display name of the active profile; only used to prefill the name field.
  final String? profileName;

  /// Backend kinds the active profile is connected to (`plex`, `jellyfin`, …).
  final List<String> backends;

  /// Null when the Seerr provider is not mounted (e.g. before sign-in).
  final bool? seerrConnected;

  /// `tv`, `phone`, `tablet`, `desktop` or `automotive`.
  final String? formFactor;

  /// Reads everything from [context] without ever throwing: a report must be
  /// possible from any screen, including ones mounted above the providers.
  factory ForkFeedbackAppState.fromContext(BuildContext context, {String? screen}) {
    String? profileName;
    final backends = <String>{};
    bool? seerrConnected;
    String? formFactor;
    String? route;

    try {
      final profiles = Provider.of<ActiveProfileProvider?>(context, listen: false);
      final active = profiles?.active;
      if (profiles != null && active != null) {
        profileName = active.displayName;
        if (active is PlexHomeProfile) backends.add('plex');
        for (final link in profiles.connectionsByProfile[active.id] ?? const []) {
          final connection = profiles.connectionsById[link.connectionId];
          if (connection != null) backends.add(connection.kind.id);
        }
      }
    } catch (_) {}

    try {
      seerrConnected = Provider.of<SeerrAccountProvider?>(context, listen: false)?.isConnected;
    } catch (_) {}

    try {
      formFactor = PlatformDetector.isAutomotive()
          ? 'automotive'
          : PlatformDetector.isTV()
          ? 'tv'
          : PlatformDetector.isDesktopOS()
          ? 'desktop'
          : PlatformDetector.isTablet(context)
          ? 'tablet'
          : 'phone';
    } catch (_) {}

    try {
      route = ModalRoute.of(context)?.settings.name;
    } catch (_) {}

    final namedRoute = route == null || route.isEmpty || route == '/' ? null : route;
    final origin = [?screen, ?namedRoute].join(' ').trim();
    return ForkFeedbackAppState(
      screen: origin.isEmpty ? null : origin,
      profileName: profileName,
      backends: backends.toList()..sort(),
      seerrConnected: seerrConnected,
      formFactor: formFactor,
    );
  }
}

/// Gathers the technical half of a report: who is asking is the user's
/// business, *what they are running* is something the app can answer itself.
class ForkFeedbackDiagnosticsCollector {
  ForkFeedbackDiagnosticsCollector({
    this._deviceInfo,
    List<LogEntry> Function()? logSource,
    DateTime Function()? clock,
    this._config,
  }) : _logSource = logSource ?? MemoryLogOutput.getLogs,
       _clock = clock ?? DateTime.now;

  final DeviceInfoPlugin? _deviceInfo;
  final List<LogEntry> Function() _logSource;
  final DateTime Function() _clock;
  final ForkFeedbackConfig? _config;

  DateTime now() => _clock();

  /// Short scalar facts. Their keys follow the server's summary line
  /// (`platform`, `os`, `device`, `app_version`, `screen`) so a report from
  /// this app reads like one from the other clients.
  Future<Map<String, Object?>> collectFacts(ForkFeedbackAppState state) async {
    final facts = <String, Object?>{};
    try {
      final appVersion = await AppVersion.current();
      facts['app_version'] = '${appVersion.versionOrUnknown} (Build ${appVersion.buildNumber ?? AppVersion.unknown})';
    } catch (_) {
      facts['app_version'] = AppVersion.unknown;
    }
    facts['git_commit'] = gitCommit.isEmpty ? AppVersion.unknown : gitCommit;

    try {
      await _addDevice(facts, state);
    } catch (error) {
      facts['platform'] ??= _platformName(state);
      facts['device_info_error'] = error.runtimeType.toString();
    }

    facts['form_factor'] = state.formFactor ?? AppVersion.unknown;
    facts['backend'] = state.backends.isEmpty ? 'none' : state.backends.join('+');
    facts['seerr'] = switch (state.seerrConnected) {
      true => 'connected',
      false => 'not connected',
      null => AppVersion.unknown,
    };
    facts['screen'] = state.screen ?? AppVersion.unknown;
    try {
      facts['locale'] = '${LocaleSettings.currentLocale.languageTag} (system ${Platform.localeName})';
    } catch (_) {}
    facts['time'] = _formatDateTime(_clock());

    // Cheap, synchronous and already part of the upstream log header.
    _addSync(facts, 'display', DevicePerformance.describeDisplay);
    _addSync(facts, 'effects', DevicePerformance.describeSync);
    _addSync(facts, 'video_decoders', VideoDecodeCapabilities.describeSync);
    return facts;
  }

  Future<void> _addDevice(Map<String, Object?> facts, ForkFeedbackAppState state) async {
    facts['platform'] = _platformName(state);
    final deviceInfo = _deviceInfo ?? DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      facts['os'] = 'Android ${info.version.release} (SDK ${info.version.sdkInt})';
      facts['device'] = '${info.manufacturer} ${info.model}';
    } else if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      facts['os'] = '${info.systemName} ${info.systemVersion}';
      facts['device'] = info.utsname.machine;
    } else if (Platform.isMacOS) {
      final info = await deviceInfo.macOsInfo;
      facts['os'] = 'macOS ${info.osRelease}';
      facts['device'] = info.model;
    } else if (Platform.isWindows) {
      final info = await deviceInfo.windowsInfo;
      facts['os'] = '${info.productName} ${info.displayVersion} (Build ${info.buildNumber})';
    } else if (Platform.isLinux) {
      final info = await deviceInfo.linuxInfo;
      facts['os'] = info.prettyName;
    }
  }

  static String _platformName(ForkFeedbackAppState state) {
    final tv = state.formFactor == 'tv';
    if (Platform.isAndroid) return tv ? 'Android TV' : 'Android';
    if (Platform.isIOS) return PlatformDetector.isAppleTV() ? 'tvOS' : 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return Platform.operatingSystem;
  }

  static void _addSync(Map<String, Object?> facts, String key, String Function() describe) {
    try {
      final value = describe();
      if (value.isNotEmpty && value != 'unknown') facts[key] = value;
    } catch (_) {}
  }

  /// Log lines written up to and including [moment], oldest first.
  List<String> logsUntil(DateTime moment) => _section(
    _newestFirst().where((entry) => !entry.timestamp.isAfter(moment)),
    maxBytes: ForkFeedbackLimits.logBytes,
  );

  /// Log lines written after [moment] — what the app did while the user was
  /// typing, which is often the second attempt that explains the first.
  List<String> logsAfter(DateTime moment) => _section(
    _newestFirst().where((entry) => entry.timestamp.isAfter(moment)),
    maxBytes: ForkFeedbackLimits.logAfterBytes,
  );

  /// The record of a launch that failed before the log buffer existed.
  String? startupFailure() {
    try {
      return StartupDiagnosticsStore.pending?.describe();
    } catch (_) {
      return null;
    }
  }

  /// [MemoryLogOutput.getLogs] is newest-first already; a source in the
  /// other order is turned around.
  Iterable<LogEntry> _newestFirst() {
    final entries = _logSource();
    if (entries.length > 1 && entries.first.timestamp.isBefore(entries.last.timestamp)) return entries.reversed;
    return entries;
  }

  /// Walks back from the newest entry and stops once the section is full:
  /// the buffer holds up to 5 MiB, of which a report can carry a sliver.
  List<String> _section(Iterable<LogEntry> newestFirst, {required int maxBytes}) {
    final chunks = <List<String>>[];
    var count = 0;
    for (final entry in newestFirst) {
      final chunk = formatLogEntry(entry);
      chunks.add(chunk);
      count += chunk.length;
      if (count >= ForkFeedbackLimits.logLines) break;
    }
    if (chunks.isEmpty) return const [];
    final lines = [for (final chunk in chunks.reversed) ...chunk];
    final redacted = ForkFeedbackRedaction.redact(lines.join('\n'), config: _config);
    // Same trimming as the upstream log upload: whole lines, newest kept.
    final constrained = constrainLogUploadPayload(header: '', logs: redacted, maxBytes: maxBytes);
    final kept = const LineSplitter().convert(constrained);
    return kept.length <= ForkFeedbackLimits.logLines ? kept : kept.sublist(kept.length - ForkFeedbackLimits.logLines);
  }

  /// One entry in the format of the upstream log screen
  /// (`[HH:mm:ss.mmm] [LEVEL] message`, then `Error:` and `Stack trace:`),
  /// split into capped lines.
  @visibleForTesting
  static List<String> formatLogEntry(LogEntry entry) {
    final time = entry.timestamp;
    final stamp =
        '${padNumber(time.hour, 2)}:${padNumber(time.minute, 2)}:${padNumber(time.second, 2)}'
        '.${padNumber(time.millisecond, 3)}';
    final lines = <String>[
      ...const LineSplitter().convert('[$stamp] [${entry.level.name.toUpperCase()}] ${entry.message}'),
      if (entry.error != null) ...const LineSplitter().convert('Error: ${entry.error}'),
    ];
    final stackTrace = entry.stackTrace?.toString().trimRight();
    if (stackTrace != null && stackTrace.isNotEmpty) {
      final frames = const LineSplitter().convert(stackTrace);
      lines.add('Stack trace:');
      lines.addAll(frames.take(ForkFeedbackLimits.stackTraceLines));
      if (frames.length > ForkFeedbackLimits.stackTraceLines) {
        lines.add('… ${frames.length - ForkFeedbackLimits.stackTraceLines} more frames');
      }
    }
    return [for (final line in lines) _truncate(line, ForkFeedbackLimits.logLineChars)];
  }

  static String _formatDateTime(DateTime time) =>
      '${padNumber(time.year, 4)}-${padNumber(time.month, 2)}-${padNumber(time.day, 2)} '
      '${padNumber(time.hour, 2)}:${padNumber(time.minute, 2)}:${padNumber(time.second, 2)}';
}

String _truncate(String value, int maxChars) {
  if (value.length <= maxChars) return value;
  var end = maxChars;
  // Never cut a surrogate pair in half: the result must stay encodable.
  if (end > 0 && (value.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end--;
  return value.substring(0, end);
}

/// Assembles the `diagnostics` JSON object of a report.
///
/// Scalars come first and lists last: when the total is too large the lists
/// are halved from the front — the same rule the server applies — so the
/// short, telling fields and the newest log lines always survive.
Map<String, Object?> buildForkFeedbackDiagnostics({
  required Map<String, Object?> facts,
  String? reporterName,
  List<String> logs = const [],
  List<String> logsAfter = const [],
  String? startupFailure,
  ForkFeedbackConfig? config,
  int maxBytes = ForkFeedbackLimits.diagnosticsBytes,
}) {
  final name = reporterName?.trim() ?? '';
  final diagnostics = <String, Object?>{
    if (name.isNotEmpty) 'name': _truncate(name, 80),
    for (final entry in facts.entries)
      if (entry.value != null) entry.key: ForkFeedbackRedaction.redactValue(entry.value, config: config),
    if (startupFailure != null && startupFailure.trim().isNotEmpty)
      'startup_failure': _truncate(
        ForkFeedbackRedaction.redact(startupFailure.trim(), config: config),
        ForkFeedbackLimits.stringChars,
      ),
    if (logs.isNotEmpty) 'logs': List<String>.of(logs),
    // Named like the reference client's section so the server-side view
    // groups both the same way.
    if (logsAfter.isNotEmpty) 'logs_danach': List<String>.of(logsAfter),
  };
  for (final entry in diagnostics.entries.toList()) {
    final value = entry.value;
    if (value is String) diagnostics[entry.key] = _truncate(value, ForkFeedbackLimits.stringChars);
  }

  for (var round = 0; round < 8; round++) {
    if (utf8.encode(jsonEncode(diagnostics)).length <= maxBytes) return diagnostics;
    var shrunk = false;
    for (final key in diagnostics.keys.toList()) {
      final value = diagnostics[key];
      if (value is List && value.length > 4) {
        final keep = value.length ~/ 2 < 4 ? 4 : value.length ~/ 2;
        diagnostics[key] = value.sublist(value.length - keep);
        shrunk = true;
      } else if (value is String && value.length > 500) {
        diagnostics[key] = value.substring(value.length - 500);
        shrunk = true;
      }
    }
    if (!shrunk) break;
  }
  if (utf8.encode(jsonEncode(diagnostics)).length <= maxBytes) return diagnostics;
  return {
    for (final entry in diagnostics.entries)
      if (entry.value is! List && entry.value is! Map && entry.value.toString().length < 500) entry.key: entry.value,
  };
}
