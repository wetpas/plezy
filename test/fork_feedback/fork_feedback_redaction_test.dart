import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:plezy/fork_feedback/fork_feedback_config.dart';
import 'package:plezy/fork_feedback/fork_feedback_diagnostics.dart';
import 'package:plezy/fork_feedback/fork_feedback_redaction.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/log_redaction_manager.dart';

const _config = ForkFeedbackConfig(baseUrl: 'https://vibe.example.org', apiKey: 'vs_test_key_123');

String _redact(String text) => ForkFeedbackRedaction.redact(text, config: _config);

LogEntry _entry(DateTime time, String message, {Level level = Level.info, Object? error, StackTrace? stackTrace}) =>
    LogEntry(timestamp: time, level: level, message: message, error: error, stackTrace: stackTrace);

void main() {
  setUp(LogRedactionManager.clearTrackedValues);
  tearDown(LogRedactionManager.clearTrackedValues);

  group('ForkFeedbackRedaction', () {
    test('removes tokens and passwords in every common spelling', () {
      final redacted = _redact(
        'GET /library/sections?X-Plex-Token=AbCdEf123456&includeGuids=1\n'
        'headers: {Authorization: Bearer eyJhbGciOi.payload.sig, X-Emby-Token: 0123456789abcdef}\n'
        'login {"username":"paul","password":"hunter2 secret","pin":"4711"}\n'
        'Authorization: MediaBrowser Client="Plezy", Token="deadbeefcafe"\n'
        'api_key=zzTopSecretzz',
      );

      for (final secret in [
        'AbCdEf123456',
        'eyJhbGciOi.payload.sig',
        '0123456789abcdef',
        'hunter2',
        '4711',
        'deadbeefcafe',
        'zzTopSecretzz',
      ]) {
        expect(redacted, isNot(contains(secret)), reason: secret);
      }
      // The shape of the line survives; only the values go.
      expect(redacted, contains('/library/sections?X-Plex-Token=[REDACTED]&includeGuids=1'));
      expect(redacted, contains('"username":"paul"'));
    });

    test('masks the host of any server URL it was never told about', () {
      final redacted = _redact(
        'Connecting to https://media.family-mueller.de:32400/library/metadata/42?checkFiles=1 failed\n'
        'ws wss://jelly.home.arpa/socket open\n'
        'sub-files=https\\://nas.lan/subs/1.srt',
      );

      expect(redacted, isNot(contains('family-mueller')));
      expect(redacted, isNot(contains('jelly.home.arpa')));
      expect(redacted, isNot(contains('nas.lan')));
      // Port and path stay: they tell what was asked without telling whom.
      expect(redacted, contains('https://[REDACTED_HOST]:32400/library/metadata/42?checkFiles=1'));
      expect(redacted, contains('wss://[REDACTED_HOST]/socket'));
      expect(redacted, contains('https\\://[REDACTED_HOST]/subs/1.srt'));
    });

    test('removes credentials embedded in a URL together with the host', () {
      final redacted = _redact('open smb://paul:geheim@nas.example.net/media/film.mkv');

      expect(redacted, isNot(contains('paul')));
      expect(redacted, isNot(contains('geheim')));
      expect(redacted, isNot(contains('nas.example.net')));
      expect(redacted, contains('smb://[REDACTED]@[REDACTED_HOST]/media/film.mkv'));
    });

    test('masks IP addresses and IPv6 literals', () {
      final redacted = _redact(
        'http://192.168.178.20:8096/Users/Me and http://[fd00:1234::2]:8096/System/Info '
        'and https://192-168-178-20.0123456789abcdef0123456789abcdef.plex.direct:32400/identity',
      );

      expect(redacted, isNot(contains('168.178')));
      expect(redacted, isNot(contains('168-178')));
      expect(redacted, isNot(contains('fd00:1234')));
      expect(redacted, isNot(contains('0123456789abcdef0123456789abcdef')));
      expect(redacted, contains('http://192.x.x.20:8096/Users/Me'));
      expect(redacted, contains('http://[REDACTED_HOST]:8096/System/Info'));
    });

    test('keeps public service hosts readable', () {
      const line =
          'GET https://plex.tv/api/v2/user and https://api.themoviedb.org/3/movie/1 and https://clients.plex.tv/x';
      expect(_redact(line), line);
    });

    test('a registered server and token are removed even from lines logged before sign-in', () {
      const early = 'probe https://media.family-mueller.de:32400/identity with token tok-EarlyBird-99';
      LogRedactionManager.registerServer('https://media.family-mueller.de:32400', 'tok-EarlyBird-99');

      final redacted = _redact(early);

      expect(redacted, isNot(contains('family-mueller')));
      expect(redacted, isNot(contains('tok-EarlyBird-99')));
    });

    test('never lets the feedback key itself through', () {
      expect(_redact('header dump vs_test_key_123 end'), 'header dump [REDACTED_TOKEN] end');
      expect(_redact('X-API-Key: vs_test_key_123'), isNot(contains('vs_test_key_123')));
    });

    test('is idempotent and leaves ordinary text alone', () {
      const plain = 'Playback started: "Der Schuh des Manitu" (2001) at 00:12:01 — codec hevc 3840x2160';
      expect(_redact(plain), plain);

      final once = _redact('https://media.example.net/a?token=abc and smb://u:p@nas.example.net/x');
      expect(_redact(once), once);
    });

    test('redacts strings inside nested diagnostics values', () {
      final redacted = ForkFeedbackRedaction.redactValue({
        'screen': 'Player https://media.example.net/video/1',
        'count': 3,
        'nested': {
          'lines': ['password=geheim', 'ok'],
        },
      }, config: _config);

      expect(jsonEncode(redacted), isNot(contains('media.example.net')));
      expect(jsonEncode(redacted), isNot(contains('geheim')));
      expect((redacted! as Map)['count'], 3);
    });
  });

  group('log sections', () {
    final opened = DateTime(2026, 11, 18, 12, 0, 0);

    ForkFeedbackDiagnosticsCollector collector(List<LogEntry> newestFirst) =>
        ForkFeedbackDiagnosticsCollector(logSource: () => newestFirst, clock: () => opened, config: _config);

    test('formats an entry like the upstream log screen', () {
      final lines = ForkFeedbackDiagnosticsCollector.formatLogEntry(
        _entry(
          DateTime(2026, 11, 18, 9, 5, 7, 42),
          'Playback failed',
          level: Level.error,
          error: StateError('no stream'),
          stackTrace: StackTrace.fromString('#0 a (a.dart:1)\n#1 b (b.dart:2)\n'),
        ),
      );

      expect(lines, [
        '[09:05:07.042] [ERROR] Playback failed',
        'Error: Bad state: no stream',
        'Stack trace:',
        '#0 a (a.dart:1)',
        '#1 b (b.dart:2)',
      ]);
    });

    test('caps line length and stack depth', () {
      final frames = [for (var i = 0; i < 40; i++) '#$i frame (file.dart:$i)'].join('\n');
      final lines = ForkFeedbackDiagnosticsCollector.formatLogEntry(
        _entry(opened, 'x' * 1000, stackTrace: StackTrace.fromString(frames)),
      );

      expect(lines.first.length, ForkFeedbackLimits.logLineChars);
      expect(lines.where((line) => line.startsWith('#')), hasLength(ForkFeedbackLimits.stackTraceLines));
      expect(lines.last, '… 28 more frames');
    });

    test('splits the buffer at the moment the dialog opened, oldest line first', () {
      final source = [
        _entry(opened.add(const Duration(seconds: 9)), 'retry while typing'),
        _entry(opened.add(const Duration(seconds: 2)), 'timeout while typing'),
        _entry(opened, 'dialog opened'),
        _entry(opened.subtract(const Duration(seconds: 5)), 'play pressed'),
        _entry(opened.subtract(const Duration(minutes: 1)), 'app started'),
      ];

      final before = collector(source).logsUntil(opened);
      final after = collector(source).logsAfter(opened);

      expect(before.map((line) => line.split('] ').last), ['app started', 'play pressed', 'dialog opened']);
      expect(after.map((line) => line.split('] ').last), ['timeout while typing', 'retry while typing']);
      // A source that is already oldest-first gives the same result.
      expect(collector(source.reversed.toList()).logsUntil(opened), before);
    });

    test('keeps only the newest lines of a long buffer', () {
      final source = [for (var i = 999; i >= 0; i--) _entry(opened.subtract(Duration(seconds: 1000 - i)), 'line $i')];

      final lines = collector(source).logsUntil(opened);

      expect(lines, hasLength(ForkFeedbackLimits.logLines));
      expect(lines.last, endsWith('line 999'));
      expect(lines.first, endsWith('line 700'));
    });

    test('redacts log lines on their way out', () {
      final lines = collector([
        _entry(opened, 'GET https://media.family-mueller.de/Items?api_key=SECRET123 -> 500'),
      ]).logsUntil(opened);

      expect(lines.single, contains('https://[REDACTED_HOST]/Items?api_key=[REDACTED]'));
      expect(lines.single, isNot(contains('SECRET123')));
    });

    test('an empty buffer yields no section', () {
      expect(collector(const []).logsUntil(opened), isEmpty);
      expect(collector(const []).logsAfter(opened), isEmpty);
    });
  });

  group('buildForkFeedbackDiagnostics', () {
    test('puts the short facts first and the logs last', () {
      final diagnostics = buildForkFeedbackDiagnostics(
        facts: const {'platform': 'Android TV', 'app_version': '1.2.3 (Build 45)', 'screen': 'Settings', 'empty': null},
        reporterName: '  Jörg  ',
        logs: const ['a', 'b'],
        logsAfter: const ['c'],
        startupFailure: 'database: could not open https://media.example.net/db',
        config: _config,
      );

      expect(diagnostics.keys.toList(), [
        'name',
        'platform',
        'app_version',
        'screen',
        'startup_failure',
        'logs',
        'logs_danach',
      ]);
      expect(diagnostics['name'], 'Jörg');
      expect(diagnostics['logs'], ['a', 'b']);
      expect(diagnostics['logs_danach'], ['c']);
      expect(diagnostics['startup_failure'], 'database: could not open https://[REDACTED_HOST]/db');
    });

    test('leaves out what was not given', () {
      final diagnostics = buildForkFeedbackDiagnostics(facts: const {'platform': 'Linux'}, reporterName: '  ');

      expect(diagnostics, {'platform': 'Linux'});
    });

    test('uses no key the server would blank as a secret', () {
      const serverSecretHints = [
        'token',
        'password',
        'passwort',
        'secret',
        'authorization',
        'cookie',
        'api_key',
        'apikey',
        'session',
      ];
      final diagnostics = buildForkFeedbackDiagnostics(
        facts: const {
          'app_version': 'x',
          'git_commit': 'x',
          'platform': 'x',
          'os': 'x',
          'device': 'x',
          'form_factor': 'x',
          'backend': 'x',
          'seerr': 'x',
          'screen': 'x',
          'locale': 'x',
          'time': 'x',
          'display': 'x',
          'effects': 'x',
          'video_decoders': 'x',
        },
        reporterName: 'x',
        logs: const ['x'],
        logsAfter: const ['x'],
        startupFailure: 'x',
      );

      for (final key in diagnostics.keys) {
        expect(serverSecretHints.any(key.toLowerCase().contains), isFalse, reason: key);
      }
    });

    test('halves the logs from the front until the report fits', () {
      final logs = [for (var i = 0; i < 300; i++) '$i ${'ä' * 200}'];
      final diagnostics = buildForkFeedbackDiagnostics(
        facts: const {'platform': 'Linux'},
        logs: logs,
        logsAfter: const ['after'],
        maxBytes: 40 * 1024,
      );

      expect(utf8.encode(jsonEncode(diagnostics)).length, lessThanOrEqualTo(40 * 1024));
      final kept = diagnostics['logs']! as List;
      expect(kept.length, lessThan(300));
      expect(kept.last, logs.last, reason: 'the newest line must survive');
      expect(diagnostics['platform'], 'Linux');
      expect(diagnostics['logs_danach'], ['after']);
    });

    test('a full report stays below the limit of the server', () {
      final section = [for (var i = 0; i < ForkFeedbackLimits.logLines; i++) '€' * ForkFeedbackLimits.logLineChars];
      final diagnostics = buildForkFeedbackDiagnostics(
        facts: const {'platform': 'Linux'},
        logs: section,
        logsAfter: section,
      );

      expect(utf8.encode(jsonEncode(diagnostics)).length, lessThanOrEqualTo(160 * 1024));
      expect(diagnostics['platform'], 'Linux');
    });
  });
}
