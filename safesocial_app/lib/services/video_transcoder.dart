import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:video_compress/video_compress.dart';

/// The result of re-encoding a clip for sending.
class TranscodedVideo {
  /// Path of the re-encoded MP4.
  final String path;
  final Duration? duration;

  /// A JPEG frame from the clip, for the inline poster. Null if none could be
  /// extracted; the clip is still sendable.
  final Uint8List? posterJpeg;

  const TranscodedVideo({
    required this.path,
    required this.duration,
    required this.posterJpeg,
  });
}

/// Raised on a platform with no encoder, instead of uploading the original.
///
/// Sending an untranscoded phone recording means an unknown codec, an unknown
/// size, and the camera's metadata — including GPS atoms — travelling with it.
/// Refusing is the honest answer; see the house rule in CLAUDE.md.
class UnsupportedVideoException implements Exception {
  final String message;
  const UnsupportedVideoException(this.message);
  @override
  String toString() => message;
}

/// Re-encodes video with whatever the platform provides.
///
/// Abstract so the media pipeline can be tested without a device, and so the
/// encoder can change without touching the pipeline.
abstract class VideoTranscoder {
  /// Length of the clip at [path], or null if it cannot be probed.
  Future<Duration?> durationOf(String path);

  /// Re-encode to 720p H.264 + AAC in MP4. The output is a new file; the input
  /// is left alone.
  Future<TranscodedVideo> transcode(String path);

  /// A JPEG frame suitable for a poster, or null.
  Future<Uint8List?> poster(String path);
}

/// The platform encoder: MediaCodec on Android, AVFoundation on iOS.
///
/// Why not ffmpeg: `ffmpeg-kit` was retired upstream in 2025 and its forks
/// ship tens of megabytes of native code per ABI, which inflates the APK and
/// makes the reproducible build fragile. The platform encoder is already on
/// every phone. Container metadata, including location, does not survive the
/// re-mux.
class PlatformVideoTranscoder implements VideoTranscoder {
  /// `video_compress` refuses to run two jobs at once; serialise them.
  Future<void> _queue = Future.value();

  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  Future<T> _serial<T>(Future<T> Function() job) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await job());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  void _requireSupport() {
    if (!isSupported) {
      throw const UnsupportedVideoException(
        'Video can only be prepared on Android and iOS for now; this platform '
        'has no encoder.',
      );
    }
  }

  @override
  Future<Duration?> durationOf(String path) async {
    _requireSupport();
    try {
      final info = await VideoCompress.getMediaInfo(path);
      final ms = info.duration;
      return ms == null ? null : Duration(milliseconds: ms.round());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<TranscodedVideo> transcode(String path) async {
    _requireSupport();
    return _serial(() async {
      final info = await VideoCompress.compressVideo(
        path,
        quality: VideoQuality.Res1280x720Quality,
        includeAudio: true,
        deleteOrigin: false,
      );
      final out = info?.file?.path ?? info?.path;
      if (info == null || out == null || info.isCancel == true) {
        throw const UnsupportedVideoException(
            'The video could not be re-encoded on this device.');
      }
      final ms = info.duration;
      return TranscodedVideo(
        path: out,
        duration: ms == null ? null : Duration(milliseconds: ms.round()),
        posterJpeg: await poster(out),
      );
    });
  }

  @override
  Future<Uint8List?> poster(String path) async {
    _requireSupport();
    try {
      return await VideoCompress.getByteThumbnail(path, quality: 60);
    } catch (_) {
      return null;
    }
  }
}
