import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';

import '../services/file_picker_service.dart';
import '../utils/platform_detector.dart';
import 'fork_feedback_sender.dart';

/// Why a picked file could not be attached.
enum ForkFeedbackImageProblem { notAnImage, tooLarge, unreadable }

class ForkFeedbackImageException implements Exception {
  const ForkFeedbackImageException(this.problem);

  final ForkFeedbackImageProblem problem;

  @override
  String toString() => 'ForkFeedbackImageException(${problem.name})';
}

/// Picks one image for a report. Returns null when the user cancels.
typedef ForkFeedbackImagePicker = Future<ForkFeedbackImage?> Function();

/// Whether this device can hand the app an image at all. Android TV and tvOS
/// have no document picker — the same rule the settings backup tiles use.
bool get forkFeedbackCanPickImages => !PlatformDetector.isTV() || PlatformDetector.isDesktopOS();

/// The extension the server would give [bytes] (`storage.sniff_image`), or
/// null when it would refuse them.
String? sniffForkFeedbackImage(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return '.png';
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return '.jpg';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) && startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) return '.webp';
  return null;
}

/// Re-encodes [bytes] as a PNG no larger than [maxDimension] on its long
/// side. Used for formats the server refuses (an iPhone hands over HEIC) and
/// for photos above its size limit.
typedef ForkFeedbackImageTranscoder = Future<Uint8List?> Function(Uint8List bytes, {required int maxDimension});

Future<Uint8List?> _transcodeToPng(Uint8List bytes, {required int maxDimension}) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final longSide = width > height ? width : height;
        if (longSide <= maxDimension) return ui.TargetImageSize(width: width, height: height);
        final scale = maxDimension / longSide;
        return ui.TargetImageSize(
          width: (width * scale).round().clamp(1, maxDimension),
          height: (height * scale).round().clamp(1, maxDimension),
        );
      },
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}

/// Turns picked [bytes] into something the server accepts, or throws a
/// [ForkFeedbackImageException] saying why that is not possible.
Future<ForkFeedbackImage> prepareForkFeedbackImage(
  Uint8List bytes, {
  String? label,
  ForkFeedbackImageTranscoder transcode = _transcodeToPng,
}) async {
  if (bytes.isEmpty) throw const ForkFeedbackImageException(ForkFeedbackImageProblem.unreadable);

  final extension = sniffForkFeedbackImage(bytes);
  if (extension != null && bytes.length <= ForkFeedbackSender.maxImageBytes) {
    return ForkFeedbackImage(bytes: bytes, extension: extension, label: label);
  }

  // Shrink in two steps: a full-size screenshot first, a clearly smaller one
  // if the PNG of a photo is still above the limit.
  for (final maxDimension in const [2560, 1280]) {
    final png = await transcode(bytes, maxDimension: maxDimension);
    if (png == null) {
      throw ForkFeedbackImageException(
        extension == null ? ForkFeedbackImageProblem.notAnImage : ForkFeedbackImageProblem.tooLarge,
      );
    }
    if (png.length <= ForkFeedbackSender.maxImageBytes && sniffForkFeedbackImage(png) != null) {
      return ForkFeedbackImage(bytes: png, extension: '.png', label: label);
    }
  }
  throw const ForkFeedbackImageException(ForkFeedbackImageProblem.tooLarge);
}

/// The default picker: the platform's image chooser through the app's
/// serialized [FilePickerService].
Future<ForkFeedbackImage?> pickForkFeedbackImage() async {
  final result = await FilePickerService.instance.pickFiles(type: FileType.image, withData: true);
  final file = result?.files.firstOrNull;
  if (file == null) return null;

  var bytes = file.bytes;
  if (bytes == null) {
    final path = file.path;
    if (path == null) throw const ForkFeedbackImageException(ForkFeedbackImageProblem.unreadable);
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      throw const ForkFeedbackImageException(ForkFeedbackImageProblem.unreadable);
    }
  }
  return prepareForkFeedbackImage(bytes, label: file.name);
}
