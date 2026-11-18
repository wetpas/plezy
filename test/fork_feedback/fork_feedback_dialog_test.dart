import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/fork_feedback/fork_feedback_config.dart';
import 'package:plezy/fork_feedback/fork_feedback_diagnostics.dart';
import 'package:plezy/fork_feedback/fork_feedback_dialog.dart';
import 'package:plezy/fork_feedback/fork_feedback_images.dart';
import 'package:plezy/fork_feedback/fork_feedback_sender.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/logs_screen.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/platform_detector.dart';

import 'multipart_test_utils.dart';

const _config = ForkFeedbackConfig(baseUrl: 'https://vibe.example.org', apiKey: 'vs_test_key_123');
final _opened = DateTime(2026, 11, 18, 12);

/// Collector with fixed facts, so no test waits on package or device plugins.
class _FakeCollector extends ForkFeedbackDiagnosticsCollector {
  _FakeCollector({List<LogEntry> Function()? logSource})
    : super(logSource: logSource ?? () => const [], clock: () => _opened, config: _config);

  ForkFeedbackAppState? seenState;

  @override
  Future<Map<String, Object?>> collectFacts(ForkFeedbackAppState state) async {
    seenState = state;
    return {
      'platform': 'Android TV',
      'app_version': '1.2.3 (Build 45)',
      'screen': state.screen,
      'backend': state.backends.join('+'),
    };
  }

  @override
  String? startupFailure() => null;
}

/// Records every request and answers from a queue; the last answer repeats.
class _Server {
  _Server(this._answers);

  final List<Future<http.Response> Function()> _answers;
  final List<http.Request> requests = [];

  late final ForkFeedbackSender sender = ForkFeedbackSender(
    config: _config,
    client: MockClient((request) {
      requests.add(request);
      final index = requests.length - 1;
      return _answers[index < _answers.length ? index : _answers.length - 1]();
    }),
  );

  Map<String?, String> fields([int index = 0]) => {
    for (final part in parseMultipart(requests[index]).where((part) => part.filename == null)) part.name: part.text,
  };

  Map<String, dynamic> diagnostics([int index = 0]) =>
      jsonDecode(fields(index)['diagnostics']!) as Map<String, dynamic>;

  List<MultipartPart> screenshots([int index = 0]) =>
      parseMultipart(requests[index]).where((part) => part.name == 'screenshot').toList();
}

Future<http.Response> _created() async => http.Response.bytes(
  utf8.encode(jsonEncode({'id': '8c814ae5-1f0b-4c57-9d5e-0a1b2c3d4e5f', 'short_id': '8c814ae5'})),
  201,
  headers: {'content-type': 'application/json'},
);

Future<void> _pumpOpener(
  WidgetTester tester, {
  ForkFeedbackConfig config = _config,
  required ForkFeedbackSender sender,
  ForkFeedbackDiagnosticsCollector? collector,
  ForkFeedbackImagePicker? imagePicker,
  bool canPickImages = true,
  Size size = const Size(800, 600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    TranslationProvider(
      child: InputModeTracker(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showForkFeedbackDialog(
                    context,
                    screen: 'Test screen',
                    config: config,
                    sender: sender,
                    collector: collector ?? _FakeCollector(),
                    imagePicker: imagePicker ?? () async => null,
                    canPickImages: canPickImages,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _field(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

String _text(WidgetTester tester, Key key) => tester.widget<EditableText>(_field(key)).controller.text;

String? _focused() => FocusManager.instance.primaryFocus?.debugLabel;

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  setUp(MemoryLogOutput.clearLogs);
  tearDown(() {
    MemoryLogOutput.clearLogs();
    ForkFeedbackConfig.debugOverride = null;
  });

  group('availability', () {
    testWidgets('the settings tile is absent in a build without a feedback channel', (tester) async {
      Widget host(ForkFeedbackConfig config) => TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            home: Scaffold(body: ForkFeedbackSettingsTile(config: config)),
          ),
        ),
      );

      await tester.pumpWidget(host(ForkFeedbackConfig.disabled));
      expect(find.text(t.forkFeedback.reportProblem), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(ForkFeedbackSettingsTile.isAvailable, isFalse);

      await tester.pumpWidget(host(const ForkFeedbackConfig(baseUrl: 'https://vibe.example.org', apiKey: '')));
      expect(find.text(t.forkFeedback.reportProblem), findsNothing);

      await tester.pumpWidget(host(_config));
      expect(find.text(t.forkFeedback.reportProblem), findsOneWidget);
      expect(find.text(t.forkFeedback.reportProblemDescription), findsOneWidget);

      ForkFeedbackConfig.debugOverride = _config;
      expect(ForkFeedbackSettingsTile.isAvailable, isTrue);
    });

    testWidgets('tapping the settings tile opens the dialog', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: const MaterialApp(
              home: Scaffold(body: ForkFeedbackSettingsTile(config: _config)),
            ),
          ),
        ),
      );

      await tester.tap(find.text(t.forkFeedback.reportProblem));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ForkFeedbackDialog), findsOneWidget);
    });

    testWidgets('opening is a no-op without configuration', (tester) async {
      final server = _Server([_created]);

      await _pumpOpener(tester, config: ForkFeedbackConfig.disabled, sender: server.sender);

      expect(find.byType(ForkFeedbackDialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('form', () {
    testWidgets('shows every control and prefills nothing but the defaults', (tester) async {
      final server = _Server([_created]);

      await _pumpOpener(tester, sender: server.sender);

      expect(find.text(t.forkFeedback.kindBug), findsOneWidget);
      expect(find.text(t.forkFeedback.kindWish), findsOneWidget);
      expect(find.text(t.forkFeedback.descriptionLabel), findsOneWidget);
      expect(find.text(t.forkFeedback.intentLabel), findsOneWidget);
      expect(find.text(t.forkFeedback.nameLabel), findsOneWidget);
      expect(find.text(t.forkFeedback.attachImage), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, t.forkFeedback.kindBug)).selected, isTrue);
      expect(find.byKey(ForkFeedbackKeys.cancel), findsOneWidget);
      expect(find.byKey(ForkFeedbackKeys.send), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a phone in portrait and keeps Cancel and Send on screen', (tester) async {
      final server = _Server([_created]);

      await _pumpOpener(tester, sender: server.sender, size: const Size(360, 640));

      expect(tester.takeException(), isNull);
      final screen = Offset.zero & const Size(360, 640);
      for (final key in [ForkFeedbackKeys.cancel, ForkFeedbackKeys.send]) {
        final rect = tester.getRect(find.byKey(key));
        expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight), isTrue, reason: '$key at $rect');
      }
    });

    testWidgets('refuses an empty description without contacting the server', (tester) async {
      final server = _Server([_created]);
      await _pumpOpener(tester, sender: server.sender);

      await tester.tap(find.byKey(ForkFeedbackKeys.send));
      await tester.pumpAndSettle();

      expect(find.text(t.forkFeedback.descriptionRequired), findsOneWidget);
      expect(server.requests, isEmpty);
      expect(find.byType(ForkFeedbackDialog), findsOneWidget);

      // Two characters are still below what the server accepts.
      await tester.enterText(_field(ForkFeedbackKeys.description), ' ab ');
      await tester.pump();
      expect(find.text(t.forkFeedback.descriptionRequired), findsNothing, reason: 'typing clears the message');
      await tester.tap(find.byKey(ForkFeedbackKeys.send));
      await tester.pumpAndSettle();

      expect(find.text(t.forkFeedback.descriptionRequired), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('sends the report and shows the short reference', (tester) async {
      final server = _Server([_created]);
      final collector = _FakeCollector(
        logSource: () => [
          LogEntry(timestamp: _opened.add(const Duration(seconds: 3)), level: Level.warning, message: 'retry'),
          LogEntry(
            timestamp: _opened.subtract(const Duration(seconds: 3)),
            level: Level.error,
            message: 'GET https://media.family-mueller.de/Items?api_key=SECRET123 failed',
          ),
        ],
      );
      await _pumpOpener(tester, sender: server.sender, collector: collector);

      await tester.tap(find.text(t.forkFeedback.kindWish));
      await tester.enterText(_field(ForkFeedbackKeys.description), 'Bitte eine Schlaf-Zeitschaltuhr');
      await tester.enterText(_field(ForkFeedbackKeys.intent), 'Abends einschlafen');
      await tester.enterText(_field(ForkFeedbackKeys.name), 'Jörg');
      await tester.tap(find.byKey(ForkFeedbackKeys.send));
      await tester.pumpAndSettle();

      expect(server.requests, hasLength(1));
      expect(server.requests.single.url, Uri.parse('https://vibe.example.org/api/feedback/'));
      expect(server.requests.single.headers['X-API-Key'], 'vs_test_key_123');
      final fields = server.fields();
      expect(fields['kind'], 'idea');
      expect(fields['source'], 'plezy');
      expect(fields['description'], 'Bitte eine Schlaf-Zeitschaltuhr');
      expect(fields['intent'], 'Abends einschlafen');

      final diagnostics = server.diagnostics();
      expect(diagnostics['name'], 'Jörg');
      expect(diagnostics['platform'], 'Android TV');
      expect(diagnostics['screen'], 'Test screen');
      expect(diagnostics['logs'], [
        '[11:59:57.000] [ERROR] GET https://[REDACTED_HOST]/Items?api_key=[REDACTED] failed',
      ]);
      expect(diagnostics['logs_danach'], ['[12:00:03.000] [WARNING] retry']);
      expect(fields['diagnostics'], isNot(contains('SECRET123')));
      expect(fields['diagnostics'], isNot(contains('family-mueller')));
      expect(server.screenshots(), isEmpty);

      expect(find.text(t.forkFeedback.sentTitle), findsOneWidget);
      expect(find.text('#8c814ae5'), findsOneWidget);
      expect(find.byKey(ForkFeedbackKeys.send), findsNothing);
      expect(_focused(), 'ForkFeedback:Close');

      await tester.tap(find.byKey(ForkFeedbackKeys.close));
      await tester.pumpAndSettle();
      expect(find.byType(ForkFeedbackDialog), findsNothing);
    });

    testWidgets('leaves the log out when the box is unticked', (tester) async {
      final server = _Server([_created]);
      final collector = _FakeCollector(
        logSource: () => [LogEntry(timestamp: _opened, level: Level.info, message: 'private line')],
      );
      await _pumpOpener(tester, sender: server.sender, collector: collector);

      await tester.enterText(_field(ForkFeedbackKeys.description), 'ohne Protokoll');
      await tester.ensureVisible(find.byKey(ForkFeedbackKeys.includeLog));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ForkFeedbackKeys.includeLog));
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
      await tester.tap(find.byKey(ForkFeedbackKeys.send));
      await tester.pumpAndSettle();

      final diagnostics = server.diagnostics();
      expect(diagnostics.containsKey('logs'), isFalse);
      expect(diagnostics.containsKey('logs_danach'), isFalse);
      expect(server.fields()['diagnostics'], isNot(contains('private line')));
      expect(diagnostics['platform'], 'Android TV', reason: 'the short facts are not the log');
    });

    testWidgets('prefills the name with the active profile', (tester) async {
      final server = _Server([_created]);
      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              home: Scaffold(
                body: ForkFeedbackDialog(
                  appState: const ForkFeedbackAppState(profileName: 'Paula', backends: ['jellyfin', 'plex']),
                  sender: server.sender,
                  collector: _FakeCollector(),
                  imagePicker: () async => null,
                  canPickImages: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_text(tester, ForkFeedbackKeys.name), 'Paula');
      expect(find.text(t.forkFeedback.attachImage), findsNothing, reason: 'no picker on this device');

      await tester.enterText(_field(ForkFeedbackKeys.description), 'Name bleibt');
      await tester.tap(find.byKey(ForkFeedbackKeys.send));
      await tester.pumpAndSettle();

      expect(server.diagnostics()['name'], 'Paula');
      expect(server.diagnostics()['backend'], 'jellyfin+plex');
    });

    for (final (label, answer, message) in <(String, Future<http.Response> Function(), String Function())>[
      ('offline', () async => throw const SocketException('Failed host lookup'), () => t.forkFeedback.errorUnreachable),
      ('a 500', () async => http.Response('boom', 500), () => t.forkFeedback.errorServer(code: 500)),
      (
        'a 429',
        () async => http.Response('{}', 429, headers: {'retry-after': '1872'}),
        () => t.forkFeedback.errorThrottledMinutes(minutes: 32),
      ),
      (
        'a 400',
        () async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'screenshot': ['Der Anhang ist kein Bild.'],
            }),
          ),
          400,
        ),
        () => t.forkFeedback.errorRejectedDetail(detail: 'Der Anhang ist kein Bild.'),
      ),
      ('a 403', () async => http.Response('{}', 403), () => t.forkFeedback.errorUnauthorized),
    ]) {
      testWidgets('$label keeps everything typed and says what went wrong', (tester) async {
        final server = _Server([answer, _created]);
        await _pumpOpener(tester, sender: server.sender);

        await tester.tap(find.text(t.forkFeedback.kindWish));
        await tester.enterText(_field(ForkFeedbackKeys.description), 'Mein langer Text');
        await tester.enterText(_field(ForkFeedbackKeys.intent), 'Etwas ansehen');
        await tester.enterText(_field(ForkFeedbackKeys.name), 'Jörg');
        await tester.tap(find.byKey(ForkFeedbackKeys.send));
        await tester.pumpAndSettle();

        expect(find.byKey(ForkFeedbackKeys.error), findsOneWidget);
        expect(tester.widget<Text>(find.byKey(ForkFeedbackKeys.error)).data, message());
        expect(find.byType(ForkFeedbackDialog), findsOneWidget);
        expect(find.text(t.forkFeedback.sentTitle), findsNothing);
        expect(_text(tester, ForkFeedbackKeys.description), 'Mein langer Text');
        expect(_text(tester, ForkFeedbackKeys.intent), 'Etwas ansehen');
        expect(_text(tester, ForkFeedbackKeys.name), 'Jörg');
        expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, t.forkFeedback.kindWish)).selected, isTrue);
        expect(find.text(t.forkFeedback.send), findsOneWidget, reason: 'Send is available again');

        // The same form goes through on the second attempt.
        await tester.tap(find.byKey(ForkFeedbackKeys.send));
        await tester.pumpAndSettle();

        expect(server.requests, hasLength(2));
        expect(server.fields(1)['description'], 'Mein langer Text');
        expect(server.fields(1)['kind'], 'idea');
        expect(find.text('#8c814ae5'), findsOneWidget);
        expect(find.byKey(ForkFeedbackKeys.error), findsNothing);
      });
    }

    testWidgets('Back closes an untouched form but never throws a draft away', (tester) async {
      final server = _Server([_created]);
      await _pumpOpener(tester, sender: server.sender);

      await tester.enterText(_field(ForkFeedbackKeys.description), 'halb fertig');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ForkFeedbackDialog), findsOneWidget, reason: 'Escape must not discard the text');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ForkFeedbackDialog), findsOneWidget, reason: 'neither must the system back gesture');
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(ForkFeedbackDialog), findsOneWidget, reason: 'nor a tap beside the dialog');
      expect(_text(tester, ForkFeedbackKeys.description), 'halb fertig');

      // Cancel is the deliberate way out.
      await tester.tap(find.byKey(ForkFeedbackKeys.cancel));
      await tester.pumpAndSettle();
      expect(find.byType(ForkFeedbackDialog), findsNothing);
      expect(server.requests, isEmpty);

      // With nothing typed, Back simply closes.
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(_text(tester, ForkFeedbackKeys.description), isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ForkFeedbackDialog), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ForkFeedbackDialog), findsNothing);
    });

    testWidgets('a second press while sending does not send twice', (tester) async {
      final server = _Server([
        () async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return _created();
        },
      ]);
      await _pumpOpener(tester, sender: server.sender);

      await tester.enterText(_field(ForkFeedbackKeys.description), 'einmal reicht');
      await tester.tap(find.byKey(ForkFeedbackKeys.send));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(t.forkFeedback.sending), findsOneWidget);
      await tester.tap(find.byKey(ForkFeedbackKeys.send));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(server.requests, hasLength(1));
      expect(find.text('#8c814ae5'), findsOneWidget);
    });
  });

  group('images', () {
    testWidgets('attached images are listed, removable and sent as screenshot parts', (tester) async {
      final server = _Server([_created]);
      final picks = [
        ForkFeedbackImage(bytes: pngBytes, extension: '.png', label: 'eins.png'),
        ForkFeedbackImage(bytes: jpegBytes, extension: '.jpg', label: 'zwei.jpg'),
        ForkFeedbackImage(bytes: webpBytes, extension: '.webp', label: 'drei.webp'),
      ];
      var next = 0;
      await _pumpOpener(tester, sender: server.sender, imagePicker: () async => picks[next++]);

      for (var i = 0; i < 3; i++) {
        await tester.ensureVisible(find.byKey(ForkFeedbackKeys.attach));
        await tester.tap(find.byKey(ForkFeedbackKeys.attach));
        await tester.pumpAndSettle();
      }
      expect(find.text('eins.png'), findsOneWidget);
      expect(find.text('zwei.jpg'), findsOneWidget);
      expect(find.text('drei.webp'), findsOneWidget);
      expect(find.text(t.forkFeedback.attachImageCount(count: 3, max: 6)), findsOneWidget);

      await tester.ensureVisible(find.text('zwei.jpg'));
      await tester.tap(find.text('zwei.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('zwei.jpg'), findsNothing);

      await tester.enterText(_field(ForkFeedbackKeys.description), 'mit Bildern');
      await tester.tap(find.byKey(ForkFeedbackKeys.send));
      await tester.pumpAndSettle();

      final screenshots = server.screenshots();
      expect(screenshots.map((part) => part.filename), ['screenshot.png', 'screenshot.webp']);
      expect(screenshots[0].bytes, pngBytes);
      expect(screenshots[1].bytes, webpBytes);
      expect(find.text('#8c814ae5'), findsOneWidget);
    });

    testWidgets('a refused file is explained and nothing is attached', (tester) async {
      final server = _Server([_created]);
      await _pumpOpener(
        tester,
        sender: server.sender,
        imagePicker: () async => throw const ForkFeedbackImageException(ForkFeedbackImageProblem.notAnImage),
      );

      await tester.enterText(_field(ForkFeedbackKeys.description), 'bleibt stehen');
      await tester.ensureVisible(find.byKey(ForkFeedbackKeys.attach));
      await tester.tap(find.byKey(ForkFeedbackKeys.attach));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(ForkFeedbackKeys.error)).data, t.forkFeedback.imageNotAnImage);
      expect(find.text(t.forkFeedback.attachImageCount(count: 0, max: 6)), findsOneWidget);
      expect(_text(tester, ForkFeedbackKeys.description), 'bleibt stehen');
    });

    testWidgets('stops at the number of images the server accepts', (tester) async {
      final server = _Server([_created]);
      var picked = 0;
      await _pumpOpener(
        tester,
        sender: server.sender,
        imagePicker: () async {
          picked++;
          return ForkFeedbackImage(bytes: pngBytes, extension: '.png', label: 'bild$picked.png');
        },
      );

      for (var i = 0; i < 7; i++) {
        await tester.ensureVisible(find.byKey(ForkFeedbackKeys.attach));
        await tester.tap(find.byKey(ForkFeedbackKeys.attach));
        await tester.pumpAndSettle();
      }

      expect(picked, 6);
      expect(tester.widget<Text>(find.byKey(ForkFeedbackKeys.error)).data, t.forkFeedback.imageLimit(max: 6));
    });
  });

  group('TV remote', () {
    setUp(() async {
      TvDetectionService.debugSetAppleTVOverride(null);
      await TvDetectionService.getInstance(forceTv: true);
      TvDetectionService.setForceTVSync(true);
      PlatformDetector.debugSetIsDesktopOSOverride(false);
    });

    tearDown(() {
      TvDetectionService.setForceTVSync(false);
      PlatformDetector.debugSetIsDesktopOSOverride(null);
    });

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    testWidgets('D-pad walks the form top to bottom and reaches Cancel and Send', (tester) async {
      final server = _Server([_created]);
      await _pumpOpener(tester, sender: server.sender, canPickImages: false, size: const Size(960, 540));

      expect(_focused(), 'ForkFeedback:KindBug', reason: 'the form opens on its first control, not on a keyboard');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(), 'ForkFeedback:KindWish');
      await press(tester, LogicalKeyboardKey.select);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, t.forkFeedback.kindWish)).selected, isTrue);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focused(), 'ForkFeedback:KindBug');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Description');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Intent', reason: 'the multiline field must not trap the D-pad');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Name');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:IncludeLog');

      // Left and Right have nowhere to go from a full-width row.
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focused(), 'ForkFeedback:IncludeLog');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(), 'ForkFeedback:IncludeLog');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Send');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focused(), 'ForkFeedback:Cancel');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focused(), 'ForkFeedback:Cancel', reason: 'the edge of the form does not wrap');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(), 'ForkFeedback:Send');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focused(), 'ForkFeedback:Send');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Send');

      // And all the way back up.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:IncludeLog');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:Name');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:Intent');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:Description');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:KindWish', reason: 'Up returns to the selected kind');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:KindWish');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the attach row sits between the name and the log checkbox', (tester) async {
      final server = _Server([_created]);
      await _pumpOpener(tester, sender: server.sender, size: const Size(960, 540));

      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Name');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Attach');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:IncludeLog');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:Attach');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:Name');
    });

    testWidgets('attached images are rows of their own and removing one keeps the focus', (tester) async {
      final server = _Server([_created]);
      var picked = 0;
      await _pumpOpener(
        tester,
        sender: server.sender,
        size: const Size(960, 540),
        imagePicker: () async => ForkFeedbackImage(bytes: pngBytes, extension: '.png', label: 'bild${++picked}.png'),
      );

      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(_focused(), 'ForkFeedback:Attach');
      await press(tester, LogicalKeyboardKey.select);
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('bild1.png'), findsOneWidget);
      expect(find.text('bild2.png'), findsOneWidget);
      expect(_focused(), 'ForkFeedback:Attach');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Image');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Image');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:IncludeLog');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused(), 'ForkFeedback:Image');

      // Select removes the focused image; focus must not fall off the form.
      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('bild2.png'), findsNothing);
      expect(find.text('bild1.png'), findsOneWidget);
      expect(_focused(), 'ForkFeedback:Attach');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the on-screen keyboard opens on Select only and hands the D-pad back when closed', (tester) async {
      const keyboard = Key('tv_virtual_keyboard_panel');
      final server = _Server([_created]);
      await _pumpOpener(tester, sender: server.sender, canPickImages: false, size: const Size(960, 540));

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Description');
      expect(find.byKey(keyboard), findsNothing, reason: 'passing through a field must not bury the form');

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byKey(keyboard), findsOneWidget);
      // A paired keyboard types straight into the field.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH, character: 'H');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE, character: 'e');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY, character: 'y');
      await tester.pumpAndSettle();
      expect(_text(tester, ForkFeedbackKeys.description), 'Hey');

      if (find.byKey(keyboard).evaluate().isNotEmpty) {
        await press(tester, LogicalKeyboardKey.escape);
      }
      expect(find.byKey(keyboard), findsNothing);
      expect(find.byType(ForkFeedbackDialog), findsOneWidget, reason: 'closing the keyboard keeps the form');
      expect(_focused(), 'ForkFeedback:Description');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(_focused(), 'ForkFeedback:Intent');
      for (var i = 0; i < 3; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(_focused(), 'ForkFeedback:Send');
      await press(tester, LogicalKeyboardKey.select);

      expect(server.fields()['description'], 'Hey');
      expect(find.text('#8c814ae5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Select on Send submits, keeps focus through a failure and lands on Close', (tester) async {
      final server = _Server([() async => http.Response('boom', 503), _created]);
      await _pumpOpener(tester, sender: server.sender, canPickImages: false, size: const Size(960, 540));

      // On a TV the field is filled through the on-screen keyboard, which
      // writes to the controller; the platform text channel is not attached.
      tester.widget<EditableText>(_field(ForkFeedbackKeys.description)).controller.text = 'vom Sofa aus';
      for (var i = 0; i < 5; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(_focused(), 'ForkFeedback:Send');

      await press(tester, LogicalKeyboardKey.select);
      expect(tester.widget<Text>(find.byKey(ForkFeedbackKeys.error)).data, t.forkFeedback.errorServer(code: 503));
      expect(_focused(), 'ForkFeedback:Send', reason: 'the remote must still have something to press');

      await press(tester, LogicalKeyboardKey.select);
      expect(find.text('#8c814ae5'), findsOneWidget);
      expect(_focused(), 'ForkFeedback:Close');

      await press(tester, LogicalKeyboardKey.select);
      expect(find.byType(ForkFeedbackDialog), findsNothing);
    });
  });

  group('logs screen', () {
    testWidgets('upload opens the fork dialog instead of posting to the upstream relay', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Plezy',
        packageName: 'com.plezy.test',
        version: '1.2.3',
        buildNumber: '45',
        buildSignature: '',
      );
      final upstream = <http.Request>[];
      final client = MediaServerHttpClient(
        client: MockClient((request) async {
          upstream.add(request);
          return http.Response(jsonEncode({'id': 'upstream'}), 200, headers: {'content-type': 'application/json'});
        }),
      );
      addTearDown(client.close);
      appLogger.i('a line worth uploading');
      ForkFeedbackConfig.debugOverride = _config;

      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(home: LogsScreen(httpClient: client)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(t.logs.uploadLogs));
      await tester.pumpAndSettle();

      expect(upstream, isEmpty, reason: 'fork logs must not reach ice.plezy.app');
      expect(find.byType(ForkFeedbackDialog), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
      expect(find.text(t.messages.logsUploaded), findsNothing);
    });

    testWidgets('without a feedback channel the upstream upload is unchanged', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Plezy',
        packageName: 'com.plezy.test',
        version: '1.2.3',
        buildNumber: '45',
        buildSignature: '',
      );
      final upstream = <http.Request>[];
      final client = MediaServerHttpClient(
        client: MockClient((request) async {
          upstream.add(request);
          return http.Response(jsonEncode({'id': 'upstream-id'}), 200, headers: {'content-type': 'application/json'});
        }),
      );
      addTearDown(client.close);
      appLogger.i('a line worth uploading');

      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(home: LogsScreen(httpClient: client)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(t.logs.uploadLogs));
      await tester.pumpAndSettle();

      expect(upstream.single.url, Uri.parse('https://ice.plezy.app/logs'));
      expect(find.byType(ForkFeedbackDialog), findsNothing);
      expect(find.text('upstream-id', findRichText: true), findsOneWidget);
    });
  });
}
