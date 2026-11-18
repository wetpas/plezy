import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/fork_update/fork_update.dart';

Map<String, dynamic> _asset(String name, {String state = 'uploaded', int size = 1000, String? digest}) => {
  'name': name,
  'state': state,
  'size': size,
  'browser_download_url': 'https://github.com/wetpas/plezy/releases/download/x/$name',
  'digest': ?digest,
};

Map<String, dynamic> _release(
  String tag,
  List<Map<String, dynamic>> assets, {
  bool draft = false,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'name': 'Plezy Fork 2.26.0 · Build ${tag.replaceFirst('fork-b', '')}',
  'html_url': 'https://github.com/wetpas/plezy/releases/tag/$tag',
  'body': '- feat(x): something',
  'published_at': '2026-11-18T10:00:00Z',
  'draft': draft,
  'prerelease': prerelease,
  'assets': assets,
};

void main() {
  const apk = ['plezy-fork-arm64-v8a.apk', 'plezy-fork-armeabi-v7a.apk'];

  test('picks the newest newer release that carries a file for this device', () {
    final candidate = ForkUpdate.pickUpdate(
      [
        _release('fork-b4170', [_asset('plezy-fork-linux-x64.AppImage')]),
        _release('fork-b4165', [_asset('plezy-fork-arm64-v8a.apk', digest: 'sha256:ABCDEF')]),
        _release('fork-b4162', [_asset('plezy-fork-arm64-v8a.apk')]),
      ],
      currentBuild: 4160,
      wantedAssets: apk,
    );

    expect(candidate, isNotNull);
    expect(candidate!.build, 4165);
    expect(candidate.version, '2.26.0');
    expect(candidate.asset.name, 'plezy-fork-arm64-v8a.apk');
    expect(candidate.asset.sha256, 'abcdef');
    final info = candidate.toUpdateInfo(currentVersion: '2.26.0 (Build 4160)', installable: true);
    expect(info['latestVersion'], '2.26.0 (Build 4165)');
    expect(info['hasUpdate'], isTrue);
    expect(info['forkInstallable'], isTrue);
  });

  test('falls back to the next preferred file in device order', () {
    final candidate = ForkUpdate.pickUpdate(
      [
        _release('fork-b4165', [_asset('plezy-fork-armeabi-v7a.apk')]),
      ],
      currentBuild: 4160,
      wantedAssets: apk,
    );
    expect(candidate?.asset.name, 'plezy-fork-armeabi-v7a.apk');
  });

  test('ignores current, older, draft, pre-release, foreign and half-uploaded releases', () {
    final candidate = ForkUpdate.pickUpdate(
      [
        _release('fork-b4160', [_asset('plezy-fork-arm64-v8a.apk')]),
        _release('fork-b4100', [_asset('plezy-fork-arm64-v8a.apk')]),
        _release('fork-b4200', [_asset('plezy-fork-arm64-v8a.apk')], draft: true),
        _release('fork-b4201', [_asset('plezy-fork-arm64-v8a.apk')], prerelease: true),
        _release('2.27.0', [_asset('plezy-fork-arm64-v8a.apk')]),
        _release('fork-b4202', [_asset('plezy-fork-arm64-v8a.apk', state: 'open')]),
        _release('fork-b4203', [_asset('plezy-fork-arm64-v8a.apk', size: 0)]),
        'not a release',
      ],
      currentBuild: 4160,
      wantedAssets: apk,
    );
    expect(candidate, isNull);
  });

  test('no wanted files means no update', () {
    expect(
      ForkUpdate.pickUpdate(
        [
          _release('fork-b4165', [_asset('plezy-fork-arm64-v8a.apk')]),
        ],
        currentBuild: 4160,
        wantedAssets: const [],
      ),
      isNull,
    );
  });

  test('label shows the build number with or without a version', () {
    expect(ForkUpdate.label('2.26.0', 4160), '2.26.0 (Build 4160)');
    expect(ForkUpdate.label(null, 4160), 'Build 4160');
  });

  test('stays off without fork build defines', () {
    expect(ForkUpdate.enabled, isFalse);
  });
}
