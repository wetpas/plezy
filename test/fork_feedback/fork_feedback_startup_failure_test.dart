import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/fork_feedback/fork_feedback_config.dart';
import 'package:plezy/fork_feedback/fork_feedback_diagnostics.dart';
import 'package:plezy/fork_feedback/fork_feedback_dialog.dart';
import 'package:plezy/fork_feedback/fork_feedback_sender.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/app_exit_service.dart';
import 'package:plezy/services/startup_diagnostics.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/widgets/startup_failure_view.dart';

import 'multipart_test_utils.dart';

const _config = ForkFeedbackConfig(baseUrl: 'https://vibe.example.org', apiKey: 'vs_test_key_123');

/// Every URL the app's own transport tried to open. The view and the default
/// sender both use the process-wide client, so this sees whatever either of
/// them would have sent — and lets nothing out.
final List<Uri> _opened = [];

class _RecordingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    _opened.add(url);
    throw const SocketException('network disabled in tests');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RecordingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _RecordingHttpClient();
}

class _FixedCollector extends ForkFeedbackDiagnosticsCollector {
  _FixedCollector() : super(logSource: () => const [], clock: () => DateTime(2026, 11, 18, 12), config: _config);

  @override
  Future<Map<String, Object?>> collectFacts(ForkFeedbackAppState state) async => {
    'platform': 'Windows',
    'screen': state.screen,
  };

  @override
  String? startupFailure() => null;
}

StartupFailureRecord _record() => StartupFailureRecord(
  phase: StartupPhase.preferences,
  errorType: 'CorruptPreferenceStoreException',
  message: 'the preference store could not be parsed',
  stackTrace: '#0 load (prefs.dart:1)',
  timestamp: DateTime.utc(2026),
  appVersion: '2.11.1',
  platform: 'windows',
  repairable: true,
);

/// The view as the startup gate mounts it: above every app provider.
Future<void> _pumpView(WidgetTester tester) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: StartupFailureView(
            failure: _record(),
            onRetry: () {},
            requestExit: ({AppExitApplication? exitApplicationForTesting}) async => false,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    LocaleSettings.setLocaleSync(AppLocale.en);
    // Before the first request, so the process-wide client is built on it.
    HttpOverrides.global = _RecordingHttpOverrides();
  });

  setUp(() {
    _opened.clear();
    MemoryLogOutput.clearLogs();
  });

  tearDown(() {
    ForkFeedbackConfig.debugOverride = null;
    MemoryLogOutput.clearLogs();
  });

  testWidgets('without a feedback channel the details still go to the upstream relay', (tester) async {
    await _pumpView(tester);

    await tester.ensureVisible(find.byKey(startupFailureUploadKey));
    await tester.tap(find.byKey(startupFailureUploadKey));
    await _settle(tester);

    expect(_opened, [Uri.parse('https://ice.plezy.app/logs')]);
    expect(find.byType(ForkFeedbackDialog), findsNothing);
    expect(find.text(t.messages.logsUploadFailed), findsOneWidget, reason: 'the upstream flow ran to its own end');
  });

  testWidgets('with a feedback channel the upload becomes a crash report and never reaches upstream', (tester) async {
    ForkFeedbackConfig.debugOverride = _config;
    await _pumpView(tester);

    await tester.ensureVisible(find.byKey(startupFailureUploadKey));
    await tester.tap(find.byKey(startupFailureUploadKey));
    await _settle(tester);

    expect(_opened, isEmpty, reason: 'opening the dialog sends nothing');
    final dialog = tester.widget<ForkFeedbackDialog>(find.byType(ForkFeedbackDialog));
    expect(dialog.initialKind, ForkFeedbackKind.crash);
    expect(dialog.failureRecord, _record().describe());
    expect(dialog.appState.screen, 'Startup failure');
    expect(find.byKey(ForkFeedbackKeys.kindBug), findsNothing, reason: 'a crash is not a bug-or-wish choice');
    expect(find.text(t.forkFeedback.crashDescription), findsOneWidget);
    expect(find.text(t.messages.logsUploaded), findsNothing);

    // Sending uses the fork endpoint only; the disabled network makes it fail,
    // which the dialog reports without losing the text.
    await tester.tap(find.byKey(ForkFeedbackKeys.send));
    await _settle(tester);

    expect(_opened, [Uri.parse('https://vibe.example.org/api/feedback/')]);
    expect(_opened.where((url) => url.host.endsWith('plezy.app')), isEmpty);
    expect(tester.widget<Text>(find.byKey(ForkFeedbackKeys.error)).data, t.forkFeedback.errorUnreachable);
    expect(find.text(t.forkFeedback.crashDescription), findsOneWidget);
    expect(find.text(t.messages.logsUploadFailed), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the crash report carries the failure record even without the log', (tester) async {
    final requests = <http.Request>[];
    final sender = ForkFeedbackSender(
      config: _config,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode({'id': '8c814ae5-1f0b-4c57-9d5e-0a1b2c3d4e5f'}), 201);
      }),
    );
    final record = '${_record().describe()}\nat https://media.family-mueller.de/prefs?token=SECRET123';
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showForkFeedbackDialog(
                  context,
                  screen: 'Startup failure',
                  config: _config,
                  sender: sender,
                  collector: _FixedCollector(),
                  canPickImages: false,
                  kind: ForkFeedbackKind.crash,
                  description: t.forkFeedback.crashDescription,
                  failureRecord: record,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'ForkFeedback:Send', reason: 'ready to send as opened');
    await tester.ensureVisible(find.byKey(ForkFeedbackKeys.includeLog));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ForkFeedbackKeys.includeLog));
    await tester.pump();
    await tester.tap(find.byKey(ForkFeedbackKeys.send));
    await tester.pumpAndSettle();

    final fields = {
      for (final part in parseMultipart(requests.single).where((part) => part.filename == null)) part.name: part.text,
    };
    expect(fields['kind'], 'crash');
    expect(fields['source'], 'plezy');
    expect(fields['description'], t.forkFeedback.crashDescription);
    final diagnostics = jsonDecode(fields['diagnostics']!) as Map<String, dynamic>;
    final sent = diagnostics['startup_failure'] as String;
    expect(sent, contains('Phase: preferences'));
    expect(sent, contains('CorruptPreferenceStoreException'));
    expect(sent, contains('#0 load (prefs.dart:1)'));
    expect(sent, isNot(contains('family-mueller')));
    expect(sent, isNot(contains('SECRET123')));
    expect(diagnostics['screen'], 'Startup failure');
    expect(diagnostics.containsKey('logs'), isFalse);
    expect(find.text('#8c814ae5'), findsOneWidget);
  });

  testWidgets('an untouched crash report closes on Back, an edited one does not', (tester) async {
    ForkFeedbackConfig.debugOverride = _config;
    await _pumpView(tester);
    await tester.ensureVisible(find.byKey(startupFailureUploadKey));
    await tester.tap(find.byKey(startupFailureUploadKey));
    await _settle(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ForkFeedbackDialog), findsNothing);

    await tester.tap(find.byKey(startupFailureUploadKey));
    await _settle(tester);
    await tester.enterText(
      find.descendant(of: find.byKey(ForkFeedbackKeys.description), matching: find.byType(EditableText)),
      'Seit dem Update startet nichts mehr',
    );
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ForkFeedbackDialog), findsOneWidget);
    expect(_opened, isEmpty);
  });
}
