import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/fork_feedback/fork_feedback_config.dart';
import 'package:plezy/fork_feedback/fork_feedback_diagnostics.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/providers/seerr_account_provider.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:provider/provider.dart';

const _config = ForkFeedbackConfig(baseUrl: 'https://vibe.example.org', apiKey: 'vs_test_key_123');

class _BrokenDeviceInfo implements DeviceInfoPlugin {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('device info unavailable');
}

/// Only the three getters the report reads; everything else is unused here.
class _FakeProfiles extends ChangeNotifier implements ActiveProfileProvider {
  _FakeProfiles({required this.active, required this.connectionsByProfile, required this.connectionsById});

  @override
  final Profile? active;
  @override
  final Map<String, List<ProfileConnection>> connectionsByProfile;
  @override
  final Map<String, Connection> connectionsById;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSeerr extends ChangeNotifier implements SeerrAccountProvider {
  _FakeSeerr({required this.isConnected});

  @override
  final bool isConnected;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    PackageInfo.setMockInitialValues(
      appName: 'Plezy',
      packageName: 'com.plezy.test',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );
  });

  group('collectFacts', () {
    test('describes the build, the device and what the app is connected to', () async {
      final deviceInfo = DeviceInfoPlugin.setMockInitialValues(
        linuxDeviceInfo: LinuxDeviceInfo(
          name: 'Test Linux',
          id: 'test-linux',
          prettyName: 'Test Linux 42',
          machineId: 'test-machine',
        ),
      );
      final collector = ForkFeedbackDiagnosticsCollector(
        deviceInfo: deviceInfo,
        logSource: () => const [],
        clock: () => DateTime(2026, 11, 18, 9, 5, 7),
        config: _config,
      );

      final facts = await collector.collectFacts(
        const ForkFeedbackAppState(
          screen: 'Settings',
          profileName: 'Paula',
          backends: ['jellyfin', 'plex'],
          seerrConnected: true,
          formFactor: 'desktop',
        ),
      );

      expect(facts['app_version'], '1.2.3 (Build 45)');
      expect(facts['git_commit'], 'unknown', reason: 'the test build carries no GIT_COMMIT');
      expect(facts['platform'], 'Linux');
      expect(facts['os'], 'Test Linux 42');
      expect(facts['form_factor'], 'desktop');
      expect(facts['backend'], 'jellyfin+plex');
      expect(facts['seerr'], 'connected');
      expect(facts['screen'], 'Settings');
      expect(facts['time'], '2026-11-18 09:05:07');
      expect(facts['locale'], startsWith('en '));
      // The profile name only prefills the form; it is the user's to send.
      expect(facts.values, isNot(contains('Paula')));
      expect(facts.containsKey('server'), isFalse, reason: 'no server address in a report');
    }, testOn: 'linux');

    test('says so when nothing is connected', () async {
      final collector = ForkFeedbackDiagnosticsCollector(
        deviceInfo: _BrokenDeviceInfo(),
        logSource: () => const [],
        config: _config,
      );

      final facts = await collector.collectFacts(const ForkFeedbackAppState(seerrConnected: false));

      expect(facts['backend'], 'none');
      expect(facts['seerr'], 'not connected');
      expect(facts['screen'], 'unknown');
      expect(facts['form_factor'], 'unknown');
    });

    test('a failing device plugin costs the device line, not the report', () async {
      final collector = ForkFeedbackDiagnosticsCollector(
        deviceInfo: _BrokenDeviceInfo(),
        logSource: () => const [],
        config: _config,
      );

      final facts = await collector.collectFacts(const ForkFeedbackAppState(screen: 'Logs'));

      expect(facts['app_version'], '1.2.3 (Build 45)');
      expect(facts['platform'], isNotNull);
      expect(facts['device_info_error'], 'StateError');
      expect(facts['screen'], 'Logs');
      expect(facts.containsKey('os'), isFalse);
    });
  });

  group('ForkFeedbackAppState.fromContext', () {
    tearDown(() {
      TvDetectionService.setForceTVSync(false);
      PlatformDetector.debugSetIsDesktopOSOverride(null);
    });

    Future<ForkFeedbackAppState> read(WidgetTester tester, {String? screen, String? routeName}) async {
      ForkFeedbackAppState? state;
      await tester.pumpWidget(
        MaterialApp(
          // A fresh app per read, so the route is built again.
          key: UniqueKey(),
          initialRoute: routeName ?? '/',
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (context) {
              if (settings.name == (routeName ?? '/')) {
                state = ForkFeedbackAppState.fromContext(context, screen: screen);
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump();
      return state!;
    }

    testWidgets('works above the app providers and reports what it can', (tester) async {
      final state = await read(tester, screen: 'Settings');

      expect(state.screen, 'Settings');
      expect(state.profileName, isNull);
      expect(state.backends, isEmpty);
      expect(state.seerrConnected, isNull);
      expect(state.formFactor, 'desktop');
      expect(tester.takeException(), isNull);
    });

    testWidgets('reads the profile, its backends and Seerr from the app providers', (tester) async {
      final created = DateTime(2026);
      final profiles = _FakeProfiles(
        active: Profile.plexHome(id: 'home-1', displayName: 'Paula', createdAt: created),
        connectionsByProfile: const {
          'home-1': [ProfileConnection(profileId: 'home-1', connectionId: 'jf-1', userIdentifier: 'u1')],
          'other': [ProfileConnection(profileId: 'other', connectionId: 'missing', userIdentifier: 'u2')],
        },
        connectionsById: {
          'jf-1': JellyfinConnection(
            id: 'jf-1',
            baseUrl: 'https://jelly.family-mueller.de',
            serverName: 'Wohnzimmer',
            serverMachineId: 'machine',
            userId: 'u1',
            userName: 'paula',
            accessToken: 'jf-secret-token',
            deviceId: 'device',
            createdAt: created,
          ),
        },
      );
      final seerr = _FakeSeerr(isConnected: true);
      addTearDown(profiles.dispose);
      addTearDown(seerr.dispose);

      late ForkFeedbackAppState state;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: profiles),
            ChangeNotifierProvider<SeerrAccountProvider>.value(value: seerr),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                state = ForkFeedbackAppState.fromContext(context, screen: 'Settings');
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(state.profileName, 'Paula');
      expect(state.backends, ['jellyfin', 'plex']);
      expect(state.seerrConnected, isTrue);

      // Nothing of the connection itself ends up in the facts.
      final facts = await ForkFeedbackDiagnosticsCollector(
        deviceInfo: _BrokenDeviceInfo(),
        logSource: () => const [],
        config: _config,
      ).collectFacts(state);
      expect(facts['backend'], 'jellyfin+plex');
      expect(facts['seerr'], 'connected');
      final text = facts.values.join('\n');
      expect(text, isNot(contains('family-mueller')));
      expect(text, isNot(contains('jf-secret-token')));
      expect(text, isNot(contains('Wohnzimmer')));
    });

    testWidgets('adds a named route to the screen', (tester) async {
      expect((await read(tester, screen: 'Logs', routeName: '/settings/logs')).screen, 'Logs /settings/logs');
      expect((await read(tester, routeName: '/')).screen, isNull);
    });

    testWidgets('tells a TV from a phone from a tablet', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      PlatformDetector.debugSetIsDesktopOSOverride(false);

      tester.view.physicalSize = const Size(400, 800);
      expect((await read(tester)).formFactor, 'phone');

      tester.view.physicalSize = const Size(1280, 800);
      expect((await read(tester)).formFactor, 'tablet');

      await TvDetectionService.getInstance(forceTv: true);
      TvDetectionService.setForceTVSync(true);
      expect((await read(tester)).formFactor, 'tv');
    });
  });
}
