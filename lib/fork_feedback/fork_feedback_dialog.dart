import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_button.dart';
import '../focus/focusable_text_field.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../mixins/controller_disposer_mixin.dart';
import '../utils/dialogs.dart';
import '../utils/formatters.dart';
import '../utils/platform_detector.dart';
import '../widgets/app_icon.dart';
import '../widgets/dialog_action_button.dart';
import '../widgets/focusable_list_tile.dart';
import '../widgets/setting_tile.dart';
import 'fork_feedback_config.dart';
import 'fork_feedback_diagnostics.dart';
import 'fork_feedback_images.dart';
import 'fork_feedback_sender.dart';

/// Widget keys of the dialog's controls, for tests and UI automation.
abstract final class ForkFeedbackKeys {
  static const kindBug = Key('fork-feedback-kind-bug');
  static const kindWish = Key('fork-feedback-kind-wish');
  static const description = Key('fork-feedback-description');
  static const intent = Key('fork-feedback-intent');
  static const name = Key('fork-feedback-name');
  static const attach = Key('fork-feedback-attach');
  static const includeLog = Key('fork-feedback-include-log');
  static const cancel = Key('fork-feedback-cancel');
  static const send = Key('fork-feedback-send');
  static const error = Key('fork-feedback-error');
  static const reference = Key('fork-feedback-reference');
  static const close = Key('fork-feedback-close');
}

/// Opens the "Report a problem" dialog, or does nothing when this build has
/// no feedback channel configured.
///
/// [screen] names where the user came from; it ends up in the report so "it
/// hangs" has a place attached to it.
Future<void> showForkFeedbackDialog(
  BuildContext context, {
  String? screen,
  ForkFeedbackConfig? config,
  ForkFeedbackSender? sender,
  ForkFeedbackDiagnosticsCollector? collector,
  ForkFeedbackImagePicker? imagePicker,
  bool? canPickImages,
  ForkFeedbackKind kind = ForkFeedbackKind.bug,
  String? description,
  String? failureRecord,
}) async {
  final effectiveConfig = config ?? ForkFeedbackConfig.current;
  if (!effectiveConfig.isConfigured) return;

  final appState = ForkFeedbackAppState.fromContext(context, screen: screen);
  await showScopedDialog<void>(
    context: context,
    // A stray tap beside the dialog must not throw away what was typed.
    barrierDismissible: false,
    builder: (_) => ForkFeedbackDialog(
      appState: appState,
      sender: sender ?? ForkFeedbackSender(config: effectiveConfig),
      collector: collector ?? ForkFeedbackDiagnosticsCollector(config: effectiveConfig),
      imagePicker: imagePicker ?? pickForkFeedbackImage,
      canPickImages: canPickImages ?? forkFeedbackCanPickImages,
      initialKind: kind,
      initialDescription: description,
      failureRecord: failureRecord,
    ),
  );
}

/// Reports a launch that failed the startup gate: kind `crash`, with
/// [failureRecord] — the already-redacted text the screen shows — attached.
/// The description is prefilled so the report can be sent as it is.
Future<void> showForkFeedbackCrashDialog(BuildContext context, {required String failureRecord}) {
  return showForkFeedbackDialog(
    context,
    screen: 'Startup failure',
    kind: ForkFeedbackKind.crash,
    description: t.forkFeedback.crashDescription,
    failureRecord: failureRecord,
  );
}

/// Settings row that opens the dialog. Renders nothing in a build without a
/// feedback channel; inside a `SettingsGroup` exclude it with [isAvailable]
/// instead, because the group shapes its corners from the child count.
class ForkFeedbackSettingsTile extends StatelessWidget {
  const ForkFeedbackSettingsTile({super.key, this.focusNode, this.config});

  static bool get isAvailable => ForkFeedbackConfig.current.isConfigured;

  final FocusNode? focusNode;
  final ForkFeedbackConfig? config;

  @override
  Widget build(BuildContext context) {
    final effectiveConfig = config ?? ForkFeedbackConfig.current;
    if (!effectiveConfig.isConfigured) return const SizedBox.shrink();
    return SettingNavigationTile(
      focusNode: focusNode,
      icon: Symbols.feedback_rounded,
      title: t.forkFeedback.reportProblem,
      subtitle: t.forkFeedback.reportProblemDescription,
      onTap: () => showForkFeedbackDialog(context, screen: 'Settings', config: effectiveConfig),
    );
  }
}

class ForkFeedbackDialog extends StatefulWidget {
  const ForkFeedbackDialog({
    super.key,
    required this.appState,
    required this.sender,
    required this.collector,
    required this.imagePicker,
    required this.canPickImages,
    this.initialKind = ForkFeedbackKind.bug,
    this.initialDescription,
    this.failureRecord,
  });

  /// [ForkFeedbackKind.crash] fixes the kind: the bug/wish choice is hidden.
  final ForkFeedbackKind initialKind;

  /// Prefilled description; sending it unchanged is fine.
  final String? initialDescription;

  /// A failure record that is the subject of the report. Sent whether or
  /// not the log is included.
  final String? failureRecord;

  final ForkFeedbackAppState appState;
  final ForkFeedbackSender sender;
  final ForkFeedbackDiagnosticsCollector collector;
  final ForkFeedbackImagePicker imagePicker;
  final bool canPickImages;

  @override
  State<ForkFeedbackDialog> createState() => _ForkFeedbackDialogState();
}

class _ForkFeedbackDialogState extends State<ForkFeedbackDialog> with ControllerDisposerMixin {
  late final TextEditingController _descriptionController = createTextEditingController(
    text: widget.initialDescription,
  );
  late final TextEditingController _intentController = createTextEditingController();
  late final TextEditingController _nameController = createTextEditingController(text: widget.appState.profileName);

  final _bugFocus = FocusNode(debugLabel: 'ForkFeedback:KindBug');
  final _wishFocus = FocusNode(debugLabel: 'ForkFeedback:KindWish');
  final _descriptionFocus = FocusNode(debugLabel: 'ForkFeedback:Description');
  final _intentFocus = FocusNode(debugLabel: 'ForkFeedback:Intent');
  final _nameFocus = FocusNode(debugLabel: 'ForkFeedback:Name');
  final _attachFocus = FocusNode(debugLabel: 'ForkFeedback:Attach');
  final _includeLogFocus = FocusNode(debugLabel: 'ForkFeedback:IncludeLog');
  final _cancelFocus = FocusNode(debugLabel: 'ForkFeedback:Cancel');
  final _sendFocus = FocusNode(debugLabel: 'ForkFeedback:Send');
  final _closeFocus = FocusNode(debugLabel: 'ForkFeedback:Close');
  final _errorKey = GlobalKey();

  /// The technical facts describe the moment the dialog was opened — that is
  /// when the problem was on screen — so they are collected right away.
  late final DateTime _openedAt;
  late final Future<Map<String, Object?>> _facts;
  late final List<String> _logsAtOpen;

  late ForkFeedbackKind _kind = widget.initialKind;

  /// A crash report has nothing to choose and is ready to send as opened.
  bool get _isCrash => widget.initialKind == ForkFeedbackKind.crash;
  bool _includeLog = true;
  final List<ForkFeedbackImage> _images = [];

  /// One node per attached image, kept in step with [_images].
  final List<FocusNode> _imageFocusNodes = [];
  bool _sending = false;
  bool _picking = false;
  String? _descriptionError;
  String? _errorText;

  /// Non-null once the report is stored; the dialog then only confirms.
  String? _reference;

  /// Whether closing now would throw away something the user made.
  bool _hasDraft = false;

  /// A desktop has a real keyboard, so typing can start at once. Everywhere
  /// else the form opens on its first control: focusing the text field would
  /// raise a keyboard over the form before the user has seen it.
  bool get _startInDescription => !_isCrash && PlatformDetector.isDesktopOS() && !PlatformDetector.isTV();

  @override
  void initState() {
    super.initState();
    _descriptionController.addListener(_updateDraft);
    _intentController.addListener(_updateDraft);
    _openedAt = widget.collector.now();
    _logsAtOpen = _safeLogs(() => widget.collector.logsUntil(_openedAt));
    // Handled here as well as in [_submit], so a failure that settles before
    // the first send is not reported as an uncaught async error.
    _facts = widget.collector.collectFacts(widget.appState);
    unawaited(_facts.then<void>((_) {}, onError: (Object _) {}));
  }

  @override
  void dispose() {
    for (final node in [
      _bugFocus,
      _wishFocus,
      _descriptionFocus,
      _intentFocus,
      _nameFocus,
      _attachFocus,
      _includeLogFocus,
      _cancelFocus,
      _sendFocus,
      _closeFocus,
      ..._imageFocusNodes,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  static List<String> _safeLogs(List<String> Function() read) {
    try {
      return read();
    } catch (_) {
      return const [];
    }
  }

  void _updateDraft() {
    final hasDraft =
        _reference == null &&
        (_descriptionController.text.trim() != (widget.initialDescription ?? '').trim() ||
            _intentController.text.trim().isNotEmpty ||
            _images.isNotEmpty);
    if (hasDraft == _hasDraft || !mounted) return;
    setState(() => _hasDraft = hasDraft);
  }

  FocusNode get _selectedKindFocus => _kind == ForkFeedbackKind.bug ? _bugFocus : _wishFocus;

  /// The control below the name field: the attach row where images can be
  /// picked, the log checkbox otherwise.
  FocusNode get _afterNameFocus => widget.canPickImages ? _attachFocus : _includeLogFocus;

  /// An edge of the form. The dialog route traverses as a closed loop, so an
  /// unhandled arrow at an edge would jump to an unrelated control.
  static void _stay() {}

  /// The full-width rows below the text fields, top to bottom.
  List<FocusNode> get _rowFocusNodes => [if (widget.canPickImages) _attachFocus, ..._imageFocusNodes, _includeLogFocus];

  /// Moves between the rows by their order instead of by geometry. The text
  /// fields and buttons around them move focus explicitly, and Flutter's
  /// directional traversal keeps a history that such moves bypass: left to
  /// itself, the first Up after returning from the buttons would be spent on
  /// "undoing" a move that never ended where the history thinks it did.
  KeyEventResult _handleRowKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    // Left and Right have nowhere to go from a full-width row.
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) return KeyEventResult.handled;
    final up = key == LogicalKeyboardKey.arrowUp;
    if (!up && key != LogicalKeyboardKey.arrowDown) return KeyEventResult.ignored;

    final rows = _rowFocusNodes;
    final index = rows.indexWhere((node) => node.hasPrimaryFocus);
    if (index < 0) return KeyEventResult.ignored;
    if (event is! KeyUpEvent) {
      final target = up
          ? (index == 0 ? _nameFocus : rows[index - 1])
          : (index == rows.length - 1 ? _sendFocus : rows[index + 1]);
      target.requestFocus();
    }
    return KeyEventResult.handled;
  }

  void _setKind(ForkFeedbackKind kind) {
    if (_kind == kind) return;
    setState(() => _kind = kind);
  }

  void _showError(String message) {
    setState(() => _errorText = message);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final errorContext = _errorKey.currentContext;
      if (errorContext != null && errorContext.mounted) {
        unawaited(Scrollable.ensureVisible(errorContext, alignment: 1, duration: const Duration(milliseconds: 150)));
      }
    });
  }

  Future<void> _pickImage() async {
    if (_picking || _sending) return;
    if (_images.length >= ForkFeedbackSender.maxImages) {
      _showError(t.forkFeedback.imageLimit(max: ForkFeedbackSender.maxImages));
      return;
    }
    setState(() {
      _picking = true;
      _errorText = null;
    });
    try {
      final image = await widget.imagePicker();
      if (!mounted || image == null) return;
      setState(() {
        _images.add(image);
        _imageFocusNodes.add(FocusNode(debugLabel: 'ForkFeedback:Image'));
      });
      _updateDraft();
    } on ForkFeedbackImageException catch (problem) {
      if (!mounted) return;
      _showError(switch (problem.problem) {
        ForkFeedbackImageProblem.notAnImage => t.forkFeedback.imageNotAnImage,
        ForkFeedbackImageProblem.tooLarge => t.forkFeedback.imageTooLarge,
        ForkFeedbackImageProblem.unreadable => t.forkFeedback.imageUnreadable,
      });
    } catch (_) {
      if (!mounted) return;
      _showError(t.forkFeedback.imageUnreadable);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _removeImage(int index) {
    final node = _imageFocusNodes[index];
    // The removed row would take the focus with it.
    final hadFocus = node.hasFocus;
    if (hadFocus) _attachFocus.requestFocus();
    setState(() {
      _images.removeAt(index);
      _imageFocusNodes.removeAt(index);
    });
    _updateDraft();
    WidgetsBinding.instance.addPostFrameCallback((_) => node.dispose());
  }

  Future<void> _submit() async {
    if (_sending) return;
    final description = _descriptionController.text.trim();
    if (description.length < ForkFeedbackSender.minDescriptionChars) {
      setState(() => _descriptionError = t.forkFeedback.descriptionRequired);
      _descriptionFocus.requestFocus();
      return;
    }

    setState(() {
      _sending = true;
      _errorText = null;
      _descriptionError = null;
    });

    // A device plugin that never answers must not hold the report back.
    Map<String, Object?> facts;
    try {
      facts = await _facts.timeout(const Duration(seconds: 5));
    } catch (_) {
      facts = const {};
    }
    final diagnostics = buildForkFeedbackDiagnostics(
      facts: facts,
      reporterName: _nameController.text,
      logs: _includeLog ? _logsAtOpen : const [],
      logsAfter: _includeLog ? _safeLogs(() => widget.collector.logsAfter(_openedAt)) : const [],
      startupFailure: widget.failureRecord ?? (_includeLog ? widget.collector.startupFailure() : null),
    );

    final result = await widget.sender.send(
      ForkFeedbackReport(
        kind: _kind,
        description: description,
        intent: _intentController.text,
        diagnostics: diagnostics,
        images: List.unmodifiable(_images),
      ),
    );
    if (!mounted) return;

    if (result.isSuccess) {
      setState(() {
        _sending = false;
        _reference = result.reference ?? '';
        _hasDraft = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closeFocus.requestFocus();
      });
      return;
    }

    // Everything typed stays in the form: only the message changes.
    setState(() => _sending = false);
    _showError(_describeFailure(result));
  }

  String _describeFailure(ForkFeedbackSendResult result) {
    final code = result.statusCode;
    return switch (result.failure!) {
      ForkFeedbackFailure.unreachable => t.forkFeedback.errorUnreachable,
      ForkFeedbackFailure.rejected =>
        result.detail == null
            ? t.forkFeedback.errorRejected
            : t.forkFeedback.errorRejectedDetail(detail: result.detail!),
      ForkFeedbackFailure.unauthorized => t.forkFeedback.errorUnauthorized,
      ForkFeedbackFailure.tooLarge => t.forkFeedback.errorTooLarge,
      ForkFeedbackFailure.throttled =>
        result.retryAfter == null
            ? t.forkFeedback.errorThrottled
            : t.forkFeedback.errorThrottledMinutes(minutes: (result.retryAfter!.inSeconds / 60).ceil()),
      ForkFeedbackFailure.serverError => t.forkFeedback.errorServer(code: code ?? 500),
      ForkFeedbackFailure.unexpected =>
        code == null ? t.forkFeedback.errorUnexpected : t.forkFeedback.errorUnexpectedCode(code: code),
    };
  }

  @override
  Widget build(BuildContext context) {
    final reference = _reference;
    // Back, Escape and the system back gesture close the dialog only while
    // nothing would be lost; a draft is discarded with Cancel, deliberately.
    return PopScope(
      canPop: !_hasDraft,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
        child: reference != null ? _buildConfirmation(context, reference) : _buildForm(context),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.forkFeedback.reportProblem),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_isCrash) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildKindChip(
                    key: ForkFeedbackKeys.kindBug,
                    kind: ForkFeedbackKind.bug,
                    label: t.forkFeedback.kindBug,
                    icon: Symbols.bug_report_rounded,
                    focusNode: _bugFocus,
                    onNavigateLeft: _stay,
                    onNavigateRight: _wishFocus.requestFocus,
                  ),
                  _buildKindChip(
                    key: ForkFeedbackKeys.kindWish,
                    kind: ForkFeedbackKind.idea,
                    label: t.forkFeedback.kindWish,
                    icon: Symbols.lightbulb_rounded,
                    focusNode: _wishFocus,
                    onNavigateLeft: _bugFocus.requestFocus,
                    onNavigateRight: _stay,
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            FocusableTextField(
              key: ForkFeedbackKeys.description,
              controller: _descriptionController,
              focusNode: _descriptionFocus,
              autofocus: _startInDescription,
              tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
              tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
              decoration: InputDecoration(
                labelText: t.forkFeedback.descriptionLabel,
                hintText: t.forkFeedback.descriptionHint,
                errorText: _descriptionError,
                alignLabelWithHint: true,
              ),
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: [LengthLimitingTextInputFormatter(ForkFeedbackSender.maxDescriptionChars)],
              maxLines: 6,
              minLines: 3,
              onChanged: (_) {
                if (_descriptionError != null) setState(() => _descriptionError = null);
              },
              // A multiline field keeps Up/Down for its caret unless both
              // exits are wired, which would trap a D-pad inside it.
              onNavigateUp: _isCrash ? _stay : () => _selectedKindFocus.requestFocus(),
              onNavigateDown: _intentFocus.requestFocus,
              onNavigateLeft: _stay,
              onNavigateRight: _stay,
            ),
            const SizedBox(height: 12),
            FocusableTextField(
              key: ForkFeedbackKeys.intent,
              controller: _intentController,
              focusNode: _intentFocus,
              tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
              decoration: InputDecoration(labelText: t.forkFeedback.intentLabel),
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: [LengthLimitingTextInputFormatter(ForkFeedbackSender.maxIntentChars)],
              onSubmitted: (_) => _nameFocus.requestFocus(),
              onNavigateUp: _descriptionFocus.requestFocus,
              onNavigateDown: _nameFocus.requestFocus,
              onNavigateLeft: _stay,
              onNavigateRight: _stay,
            ),
            const SizedBox(height: 12),
            FocusableTextField(
              key: ForkFeedbackKeys.name,
              controller: _nameController,
              focusNode: _nameFocus,
              tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
              decoration: InputDecoration(labelText: t.forkFeedback.nameLabel),
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [LengthLimitingTextInputFormatter(80)],
              onSubmitted: (_) => _sendFocus.requestFocus(),
              onNavigateUp: _intentFocus.requestFocus,
              onNavigateDown: () => _afterNameFocus.requestFocus(),
              onNavigateLeft: _stay,
              onNavigateRight: _stay,
            ),
            const SizedBox(height: 8),
            Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _handleRowKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.canPickImages) ...[
                    FocusableListTile(
                      key: ForkFeedbackKeys.attach,
                      focusNode: _attachFocus,
                      enabled: !_sending,
                      contentPadding: EdgeInsets.zero,
                      leading: const AppIcon(Symbols.add_photo_alternate_rounded, fill: 1),
                      title: Text(t.forkFeedback.attachImage),
                      subtitle: Text(
                        t.forkFeedback.attachImageCount(count: _images.length, max: ForkFeedbackSender.maxImages),
                      ),
                      onTap: _pickImage,
                    ),
                    for (var index = 0; index < _images.length; index++)
                      FocusableListTile(
                        focusNode: _imageFocusNodes[index],
                        contentPadding: EdgeInsets.zero,
                        enabled: !_sending,
                        leading: const AppIcon(Symbols.image_rounded, fill: 1),
                        title: Text(
                          _images[index].label ?? t.forkFeedback.imageNumber(number: index + 1),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(ByteFormatter.formatBytes(_images[index].bytes.length)),
                        trailing: AppIcon(Symbols.close_rounded, fill: 1, semanticLabel: t.forkFeedback.removeImage),
                        onTap: () => _removeImage(index),
                      ),
                  ],
                  FocusableCheckboxListTile(
                    key: ForkFeedbackKeys.includeLog,
                    focusNode: _includeLogFocus,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _includeLog,
                    onChanged: _sending ? null : (value) => setState(() => _includeLog = value ?? false),
                    title: Text(t.forkFeedback.includeLog),
                    subtitle: Text(t.forkFeedback.includeLogDescription),
                  ),
                ],
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _errorText!,
                  key: ForkFeedbackKeys.error,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
            // Anchor for bringing a fresh message into view.
            SizedBox(key: _errorKey, height: 0),
          ],
        ),
      ),
      actions: [
        DialogActionButton(
          key: ForkFeedbackKeys.cancel,
          focusNode: _cancelFocus,
          onPressed: () => Navigator.pop(context),
          onNavigateUp: _includeLogFocus.requestFocus,
          onNavigateDown: _stay,
          onNavigateLeft: _stay,
          onNavigateRight: _sendFocus.requestFocus,
          label: t.common.cancel,
        ),
        // Stays enabled while a send is in flight: a disabled button cannot
        // hold focus, and on a TV that leaves the remote with nothing to
        // steer. A second press is ignored in [_submit] instead.
        DialogActionButton(
          key: ForkFeedbackKeys.send,
          focusNode: _sendFocus,
          autofocus: _isCrash,
          isPrimary: true,
          onPressed: _submit,
          onNavigateUp: _includeLogFocus.requestFocus,
          onNavigateDown: _stay,
          onNavigateLeft: _cancelFocus.requestFocus,
          onNavigateRight: _stay,
          label: _sending ? t.forkFeedback.sending : t.forkFeedback.send,
          icon: _sending
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const AppIcon(Symbols.send_rounded, fill: 1, size: 18),
        ),
      ],
    );
  }

  Widget _buildKindChip({
    required Key key,
    required ForkFeedbackKind kind,
    required String label,
    required IconData icon,
    required FocusNode focusNode,
    VoidCallback? onNavigateLeft,
    VoidCallback? onNavigateRight,
  }) {
    final selected = _kind == kind;
    return FocusableButton(
      key: key,
      focusNode: focusNode,
      autofocus: !_startInDescription && kind == _kind,
      onPressed: () => _setKind(kind),
      onNavigateUp: _stay,
      onNavigateLeft: onNavigateLeft,
      onNavigateRight: onNavigateRight,
      onNavigateDown: _descriptionFocus.requestFocus,
      child: ChoiceChip(
        avatar: AppIcon(icon, fill: 1, size: 18),
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: _sending ? null : (_) => _setKind(kind),
      ),
    );
  }

  Widget _buildConfirmation(BuildContext context, String reference) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.forkFeedback.sentTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.forkFeedback.sentMessage),
          if (reference.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('${t.forkFeedback.reference}:'),
            const SizedBox(height: 4),
            SelectableText(
              '#$reference',
              key: ForkFeedbackKeys.reference,
              style: theme.textTheme.titleLarge?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.bold),
            ),
          ],
        ],
      ),
      actions: [
        DialogActionButton(
          key: ForkFeedbackKeys.close,
          focusNode: _closeFocus,
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          label: t.common.close,
        ),
      ],
    );
  }
}
