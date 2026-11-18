import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';

/// Fork-only update channel (wetpas/plezy).
///
/// Every fork build of the `wetpas` branch is published as a GitHub release of the fork, tagged
/// `fork-b<build>`. `<build>` is the branch's commit count, compiled into the app as
/// `FORK_BUILD_NUMBER`, so a newer build always carries a larger number on every platform. The
/// check lists the fork's releases and picks the newest one that is newer than the running build
/// and carries a file for this device. On Android that file (the APK for the device's ABI) is
/// downloaded and handed to the system installer, which refuses an APK signed with another key.
///
/// Off unless both `FORK_UPDATE_REPO` and `FORK_BUILD_NUMBER` are compiled in, so upstream builds
/// and the test suite never take this path.
abstract final class ForkUpdate {
  static const String repo = String.fromEnvironment('FORK_UPDATE_REPO');
  static const int buildNumber = int.fromEnvironment('FORK_BUILD_NUMBER');

  static bool get enabled => repo.isNotEmpty && buildNumber > 0;

  /// Fork builds land often; GitHub allows 60 unauthenticated API calls per hour and address.
  static const Duration checkCooldown = Duration(minutes: 30);

  static const MethodChannel _channel = MethodChannel('com.edde746.plezy/fork_update');

  /// Largest APK/AppImage the app is willing to download.
  static const int _maxDownloadBytes = 400 * 1024 * 1024;

  /// Android ABIs the fork workflow builds, in the asset name `plezy-fork-<abi>.apk`.
  static const Set<String> _androidAbis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'};

  static final RegExp _tagPattern = RegExp(r'^fork-b(\d+)$');
  static final RegExp _versionPattern = RegExp(r'\d+\.\d+\.\d+');

  /// Version text shown to the user, e.g. `2.26.0 (Build 4160)`.
  static String label(String? version, int build) =>
      version == null || version.isEmpty ? 'Build $build' : '$version (Build $build)';

  /// Asks GitHub for the fork's releases. Returns update info in the shape
  /// [UpdateService] hands to its dialogs, or null when this build is current. Throws when the
  /// check itself fails.
  static Future<Map<String, dynamic>?> check(MediaServerHttpClient client, {required String? currentVersion}) async {
    final response = await client.get(
      'https://api.github.com/repos/$repo/releases',
      queryParameters: {'per_page': '20'},
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) {
      throw StateError('Fork release check returned HTTP ${response.statusCode}');
    }
    final releases = response.data;
    if (releases is! List) throw StateError('Fork release list is not a list');

    final candidate = pickUpdate(releases, currentBuild: buildNumber, wantedAssets: await _wantedAssetNames());
    if (candidate == null) return null;
    return candidate.toUpdateInfo(
      currentVersion: label(currentVersion, buildNumber),
      installable: Platform.isAndroid && candidate.asset.name.endsWith('.apk'),
    );
  }

  /// The newest release newer than [currentBuild] that carries one of [wantedAssets] (first match
  /// in that order wins). Drafts, pre-releases, foreign tags and unfinished uploads are skipped.
  @visibleForTesting
  static ForkUpdateCandidate? pickUpdate(
    List<dynamic> releases, {
    required int currentBuild,
    required List<String> wantedAssets,
  }) {
    if (wantedAssets.isEmpty) return null;
    ForkUpdateCandidate? best;
    for (final raw in releases) {
      if (raw is! Map) continue;
      if (raw['draft'] == true || raw['prerelease'] == true) continue;
      final match = _tagPattern.firstMatch('${raw['tag_name'] ?? ''}');
      final build = match == null ? null : int.tryParse(match.group(1)!);
      if (build == null || build <= currentBuild) continue;
      if (best != null && build <= best.build) continue;

      final assets = raw['assets'];
      if (assets is! List) continue;
      ForkReleaseAsset? chosen;
      for (final name in wantedAssets) {
        for (final a in assets) {
          if (a is! Map || a['name'] != name || a['state'] != 'uploaded') continue;
          final url = a['browser_download_url'];
          final size = a['size'];
          if (url is! String || !url.startsWith('https://') || size is! int || size <= 0) continue;
          final digest = a['digest'];
          chosen = ForkReleaseAsset(
            name: name,
            url: url,
            size: size,
            sha256: digest is String && digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
          );
          break;
        }
        if (chosen != null) break;
      }
      if (chosen == null) continue;

      final name = '${raw['name'] ?? ''}';
      best = ForkUpdateCandidate(
        build: build,
        version: _versionPattern.firstMatch(name)?.group(0),
        releaseName: name.isEmpty ? 'Build $build' : name,
        releaseUrl: '${raw['html_url'] ?? 'https://github.com/$repo/releases'}',
        notes: '${raw['body'] ?? ''}'.trim(),
        publishedAt: '${raw['published_at'] ?? ''}',
        asset: chosen,
      );
    }
    return best;
  }

  /// Release file names this device can use, most preferred first.
  static Future<List<String>> _wantedAssetNames() async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      return [
        for (final abi in info.supportedAbis)
          if (_androidAbis.contains(abi)) 'plezy-fork-$abi.apk',
      ];
    }
    if (Platform.isLinux && Abi.current() == Abi.linuxX64) {
      final appImage = Platform.environment['APPIMAGE']?.isNotEmpty ?? false;
      return appImage
          ? const ['plezy-fork-linux-x64.AppImage', 'plezy-fork-linux-x64.tar.gz']
          : const ['plezy-fork-linux-x64.tar.gz', 'plezy-fork-linux-x64.AppImage'];
    }
    // Windows, macOS and iOS have no fork release files yet.
    return const [];
  }

  /// Downloads the update file named in [updateInfo] into the app cache, checks its size and
  /// SHA-256 (when GitHub reports one) and returns it. [onProgress] gets 0..1. Completing
  /// [cancel] aborts the download.
  static Future<File> download(
    Map<String, dynamic> updateInfo, {
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    final url = Uri.parse(updateInfo['forkDownloadUrl'] as String);
    final name = updateInfo['forkDownloadName'] as String;
    final expectedSize = updateInfo['forkDownloadSize'] as int;
    final expectedSha = updateInfo['forkDownloadSha256'] as String?;
    if (expectedSize > _maxDownloadBytes) throw StateError('Update file too large: $expectedSize bytes');

    final dir = Directory('${(await getTemporaryDirectory()).path}/fork_update');
    if (dir.existsSync()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final part = File('${dir.path}/$name.part');

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    var cancelled = false;
    unawaited(
      cancel?.then((_) {
        cancelled = true;
        client.close(force: true);
      }),
    );
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}', uri: url);

      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(const Duration(seconds: 60))) {
          received += chunk.length;
          if (received > expectedSize) throw StateError('Update file larger than announced');
          sink.add(chunk);
          onProgress?.call(received / expectedSize);
        }
      } finally {
        await sink.close();
      }
      if (received != expectedSize) throw StateError('Update file incomplete: $received of $expectedSize bytes');
      if (expectedSha != null) {
        final actual = (await sha256.bind(part.openRead()).first).toString();
        if (actual != expectedSha) throw StateError('Update file checksum mismatch');
      }
      return await part.rename('${dir.path}/$name');
    } catch (_) {
      if (part.existsSync()) await part.delete();
      if (cancelled) throw const ForkUpdateCancelled();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// Hands a downloaded APK to the Android package installer. On first use Android asks the user
  /// to allow installs from this app; after the update the app restarts in its new version.
  static Future<void> installApk(File apk) async {
    final started = await _channel.invokeMethod<bool>('installApk', {'path': apk.path});
    if (started != true) throw StateError('Package installer did not start');
    appLogger.i('Fork update handed to the package installer: ${apk.path}');
  }
}

class ForkUpdateCancelled implements Exception {
  const ForkUpdateCancelled();
}

@immutable
class ForkReleaseAsset {
  const ForkReleaseAsset({required this.name, required this.url, required this.size, this.sha256});

  final String name;
  final String url;
  final int size;
  final String? sha256;
}

@immutable
class ForkUpdateCandidate {
  const ForkUpdateCandidate({
    required this.build,
    required this.version,
    required this.releaseName,
    required this.releaseUrl,
    required this.notes,
    required this.publishedAt,
    required this.asset,
  });

  final int build;
  final String? version;
  final String releaseName;
  final String releaseUrl;
  final String notes;
  final String publishedAt;
  final ForkReleaseAsset asset;

  Map<String, dynamic> toUpdateInfo({required String currentVersion, required bool installable}) => {
    'hasUpdate': true,
    'currentVersion': currentVersion,
    'latestVersion': ForkUpdate.label(version, build),
    'releaseUrl': releaseUrl,
    'releaseName': releaseName,
    'releaseNotes': notes,
    'publishedAt': publishedAt,
    'forkInstallable': installable,
    'forkDownloadUrl': asset.url,
    'forkDownloadName': asset.name,
    'forkDownloadSize': asset.size,
    'forkDownloadSha256': asset.sha256,
  };
}
