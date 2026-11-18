import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../services/update_service.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../widgets/dialog_action_button.dart';
import 'fork_update.dart';

/// Update dialog of the fork builds: shows what changed and, on Android, downloads and installs
/// the update in place. Elsewhere it links to the release page.
Future<void> showForkUpdateDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
}) {
  return showScopedDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ForkUpdateDialog(
      updateInfo: updateInfo,
      title: title,
      dismissLabel: dismissLabel,
      showSkipVersion: showSkipVersion,
    ),
  );
}

enum _Phase { idle, downloading, installing, failed }

class _ForkUpdateDialog extends StatefulWidget {
  const _ForkUpdateDialog({
    required this.updateInfo,
    required this.title,
    required this.dismissLabel,
    required this.showSkipVersion,
  });

  final Map<String, dynamic> updateInfo;
  final String title;
  final String dismissLabel;
  final bool showSkipVersion;

  @override
  State<_ForkUpdateDialog> createState() => _ForkUpdateDialogState();
}

class _ForkUpdateDialogState extends State<_ForkUpdateDialog> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  Completer<void>? _cancel;

  bool get _installable => widget.updateInfo['forkInstallable'] == true;

  @override
  void dispose() {
    _cancelDownload();
    super.dispose();
  }

  void _cancelDownload() {
    final cancel = _cancel;
    _cancel = null;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  Future<void> _install() async {
    final cancel = Completer<void>();
    _cancel = cancel;
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
    });
    try {
      final apk = await ForkUpdate.download(
        widget.updateInfo,
        cancel: cancel.future,
        onProgress: (p) {
          if (mounted && (p - _progress >= 0.01 || p >= 1)) setState(() => _progress = p);
        },
      );
      if (!mounted || cancel.isCompleted) return;
      setState(() => _phase = _Phase.installing);
      await ForkUpdate.installApk(apk);
      if (mounted) Navigator.pop(context);
    } on ForkUpdateCancelled {
      // Closed or cancelled by the user.
    } catch (error, stackTrace) {
      appLogger.e('Fork update failed', error: error, stackTrace: stackTrace);
      if (mounted) setState(() => _phase = _Phase.failed);
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  Future<void> _openRelease() async {
    final url = Uri.tryParse(widget.updateInfo['releaseUrl'] as String? ?? '');
    if (url != null && await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = widget.updateInfo;
    final notes = (info['releaseNotes'] as String? ?? '').trim();
    final busy = _phase == _Phase.downloading || _phase == _Phase.installing;

    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text(
              t.update.versionAvailable(version: info['latestVersion'] as String),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(t.update.currentVersion(version: info['currentVersion'] as String), style: theme.textTheme.bodySmall),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(child: Text(notes, style: theme.textTheme.bodySmall)),
              ),
            ],
            if (busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _phase == _Phase.installing ? null : _progress),
              const SizedBox(height: 8),
              Text(
                _phase == _Phase.installing
                    ? t.forkUpdate.openingInstaller
                    : t.forkUpdate.downloading(percent: (_progress * 100).floor()),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_phase == _Phase.failed) ...[
              const SizedBox(height: 16),
              Text(t.forkUpdate.failed, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: busy
          ? [
              DialogActionButton(
                autofocus: true,
                onPressed: () {
                  _cancelDownload();
                  Navigator.pop(context);
                },
                label: t.common.cancel,
              ),
            ]
          : [
              DialogActionButton(onPressed: () => Navigator.pop(context), label: widget.dismissLabel),
              if (widget.showSkipVersion)
                DialogActionButton(
                  onPressed: () async {
                    await UpdateService.skipVersion(info['latestVersion'] as String);
                    if (context.mounted) Navigator.pop(context);
                  },
                  label: t.update.skipVersion,
                ),
              DialogActionButton(
                autofocus: true,
                onPressed: _installable ? _install : _openRelease,
                label: _installable
                    ? (_phase == _Phase.failed ? t.forkUpdate.retry : t.forkUpdate.install)
                    : t.update.viewRelease,
                isPrimary: true,
              ),
            ],
    );
  }
}
