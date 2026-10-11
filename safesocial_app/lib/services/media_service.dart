import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/blob.dart';
import '../models/media_provenance.dart';
import 'blob_service.dart';
import 'debug_log_service.dart';
import 'provenance_scanner.dart';
import 'video_transcoder.dart';

/// A piece of media the user chose that cannot be sent as-is: too long, too
/// large, or not something this platform can prepare. The message is written
/// for the user and the UI shows it; the send does not proceed.
/// Which part of a clip to send, and the frame that stands for it.
class VideoTrim {
  final Duration start;
  final Duration end;
  final Duration? posterAt;

  const VideoTrim({required this.start, required this.end, this.posterAt});

  factory VideoTrim.fromJson(Map<String, dynamic> j) => VideoTrim(
        start: Duration(milliseconds: (j['start'] as num?)?.toInt() ?? 0),
        end: Duration(milliseconds: (j['end'] as num?)?.toInt() ?? 0),
        posterAt: j['posterAt'] is num
            ? Duration(milliseconds: (j['posterAt'] as num).toInt())
            : null,
      );

  Map<String, dynamic> toJson() => {
        'start': start.inMilliseconds,
        'end': end.inMilliseconds,
        if (posterAt != null) 'posterAt': posterAt!.inMilliseconds,
      };
}

class MediaRejectedException implements Exception {
  final String message;
  const MediaRejectedException(this.message);
  @override
  String toString() => message;
}

/// Media picking, preparation and local storage.
///
/// Images are re-encoded on pick so EXIF and GPS never reach disk; what the
/// original said about its origin is scored first and kept as a
/// [MediaProvenance] sidecar. Video is transcoded on the platform encoder
/// before upload. Both are encrypted,
/// chunked and stored out of band by [BlobService]; the message carries only a
/// [BlobRef] plus a small inline thumbnail.
class MediaService extends ChangeNotifier {
  final ImagePicker _picker = ImagePicker();

  /// Replaceable so the pipeline can be tested without a device.
  static VideoTranscoder transcoder = PlatformVideoTranscoder();

  /// Clip length limits. Feed and stories match what mainstream platforms
  /// allow; chat and albums are more generous.
  static const Duration feedVideoLimit = Duration(seconds: 60);
  static const Duration chatVideoLimit = Duration(minutes: 3);

  /// Maximum media we will upload after preparation. 48 KB chunks make this
  /// a little under the relay's 1,400-chunk ceiling.
  static const int maxMediaBytes = 64 * 1024 * 1024;

  // -- Picking ----------------------------------------------------------------

  /// Longest side kept for a picked image. Sending resizes again to 1600.
  static const int pickedLongestSide = 1920;

  /// Pick an image from the gallery, or take one with the camera, and return
  /// its local path.
  ///
  /// The original file is read first so its own metadata can be scored (see
  /// [ProvenanceScanner]); the result is written beside the stored copy and
  /// travels with the message. The copy itself is re-encoded without any
  /// metadata, so EXIF and GPS never reach disk or the wire.
  Future<String?> pickAndStoreImage({ImageSource source = ImageSource.gallery}) async {
    try {
      final image = await _picker.pickImage(source: source);
      if (image == null) return null;

      final bytes = await image.readAsBytes();
      final provenance = ProvenanceScanner.assessImage(
        bytes,
        source: source == ImageSource.camera ? 'camera' : 'gallery',
        fileName: image.name,
      );
      final path = await storePickedImage(bytes, provenance: provenance);
      if (ProvenanceScanner.looksEquirectangular(bytes)) await setPanorama(path, true);
      // The picker's copy is no longer needed and may hold location data.
      try {
        await File(image.path).delete();
      } catch (_) {}
      return path;
    } catch (e) {
      DebugLogService().error('Media', 'Error picking image: $e');
      return null;
    }
  }

  /// Replace a picked picture with an edited version of it. The origin score
  /// keeps what the original said and adds that it was edited here, so a
  /// camera shot cropped in Spheres is no longer presented as untouched.
  static Future<String> replaceEdited(String path, Uint8List jpegBytes) async {
    await File(path).writeAsBytes(jpegBytes);
    final before = provenanceFor(path);
    if (before != null) {
      await writeProvenance(path, before.editedInApp());
    }
    return path;
  }

  /// Take a photo with the camera. Its provenance is the strongest the app
  /// can claim: captured live, from inside Spheres.
  Future<String?> captureImage() => pickAndStoreImage(source: ImageSource.camera);

  /// Re-encode picked image bytes without metadata, write them to the temp
  /// directory with [provenance] in a sidecar, and return the path.
  ///
  /// Decoding uses the engine's codec, which downsamples large photos
  /// natively; the pure-Dart decoder is the fallback. Throws when the bytes
  /// are not an image.
  static Future<String> storePickedImage(
    Uint8List bytes, {
    required MediaProvenance provenance,
    Directory? into,
  }) async {
    final decoded = await _decodeDownscaled(bytes, pickedLongestSide) ??
        _decodeInDart(bytes, pickedLongestSide);
    if (decoded == null) {
      throw const MediaRejectedException('That file is not an image.');
    }
    final dir = into ?? await getTemporaryDirectory();
    final path = '${dir.path}/picked_${DateTime.now().microsecondsSinceEpoch}.jpg';
    await File(path).writeAsBytes(img.encodeJpg(decoded, quality: 88));
    await writeProvenance(path, provenance);
    DebugLogService().success(
        'Media', 'Stored picked image without metadata (trust ${provenance.score})');
    return path;
  }

  /// Decode with the platform codec, already scaled so the longest side is at
  /// most [longest]. EXIF orientation is applied by the codec. Null when the
  /// engine cannot decode the bytes or no engine is available.
  static Future<img.Image?> _decodeDownscaled(Uint8List bytes, int longest) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? frame;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width;
      final h = descriptor.height;
      if (w <= 0 || h <= 0) return null;
      int? tw;
      int? th;
      if (w > longest || h > longest) {
        if (w >= h) {
          tw = longest;
          th = (h * longest / w).round().clamp(1, longest);
        } else {
          th = longest;
          tw = (w * longest / h).round().clamp(1, longest);
        }
      }
      codec = await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
      final frameInfo = await codec.getNextFrame();
      frame = frameInfo.image;
      final data = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return img.Image.fromBytes(
        width: frame.width,
        height: frame.height,
        bytes: data.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
    } catch (e) {
      DebugLogService().warn('Media', 'Engine decode unavailable, using Dart: $e');
      return null;
    } finally {
      frame?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static img.Image? _decodeInDart(Uint8List bytes, int longest) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      return _fit(img.bakeOrientation(decoded), longest);
    } catch (_) {
      return null;
    }
  }

  // -- Provenance sidecars ----------------------------------------------------

  /// Where a local media file's provenance claim lives: beside it, `.prov`.
  static String provenancePathFor(String mediaPath) => '$mediaPath.prov';

  static Future<void> writeProvenance(String mediaPath, MediaProvenance p) async {
    try {
      await File(provenancePathFor(mediaPath)).writeAsString(jsonEncode(p.toJson()));
    } catch (e) {
      DebugLogService().warn('Media', 'Could not record provenance: $e');
    }
  }

  /// The provenance recorded for a local file, or null when none was (remote
  /// references carry theirs in the message instead).
  static MediaProvenance? provenanceFor(String ref) {
    if (BlobRef.tryDecode(ref) != null) return null;
    try {
      final file = File(provenancePathFor(ref));
      if (!file.existsSync()) return null;
      return MediaProvenance.fromJson(jsonDecode(file.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  /// One entry per reference, aligned with [refs], for a message or post.
  static List<MediaProvenance?> provenanceListFor(List<String> refs) =>
      refs.map(provenanceFor).toList();

  /// Pick a video no longer than [limit] and return its local path.
  ///
  /// The picker's own limit only applies to camera capture, so the length is
  /// checked here as well. Throws [MediaRejectedException] when the clip is too
  /// long and [UnsupportedVideoException] where no encoder exists; returns null
  /// when the user cancelled.
  Future<String?> pickVideo({required Duration limit}) async {
    final XFile? video;
    try {
      video = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: limit,
      );
    } catch (e) {
      DebugLogService().error('Media', 'Error picking video: $e');
      return null;
    }
    if (video == null) return null;

    final duration = await transcoder.durationOf(video.path);
    if (duration != null && duration > limit) {
      throw MediaRejectedException(
        'That video is ${_describe(duration)} long; the limit here is '
        '${_describe(limit)}.',
      );
    }

    // A poster beside the file, so previews can show a frame before the clip
    // is sent. Optional: a clip without one still sends.
    await writePosterFor(video.path);
    return video.path;
  }

  /// Record a short clip with the camera, for a video note.
  Future<String?> recordVideoNote({Duration limit = const Duration(seconds: 60)}) async {
    final XFile? video;
    try {
      video = await _picker.pickVideo(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxDuration: limit,
      );
    } catch (e) {
      DebugLogService().error('Media', 'Error recording video: $e');
      return null;
    }
    if (video == null) return null;
    final duration = await transcoder.durationOf(video.path);
    if (duration != null && duration > limit) {
      throw MediaRejectedException(
          'That clip is ${_describe(duration)} long; the limit is ${_describe(limit)}.');
    }
    await writePosterFor(video.path);
    await writeProvenance(video.path, MediaProvenance.liveCamera);
    return video.path;
  }

  static String _describe(Duration d) {
    if (d.inMinutes >= 1) {
      final s = d.inSeconds % 60;
      return s == 0 ? '${d.inMinutes} min' : '${d.inMinutes} min $s s';
    }
    return '${d.inSeconds} s';
  }

  // -- Posters ----------------------------------------------------------------

  /// Where a video's poster frame lives: next to it, with `.jpg` appended.
  static String posterPathFor(String videoPath) => '$videoPath.jpg';

  /// The poster for a local video, if one has been written.
  static String? posterFor(String videoPath) {
    final path = posterPathFor(videoPath);
    return File(path).existsSync() ? path : null;
  }

  // -- 360° pictures --------------------------------------------------------------

  /// A marker beside a picture that is a full 360° view, set from the file's
  /// own metadata on pick or by hand in the composer.
  static String panoPathFor(String imagePath) => '$imagePath.pano';

  static bool isPanorama(String imagePath) => File(panoPathFor(imagePath)).existsSync();

  static Future<void> setPanorama(String imagePath, bool on) async {
    final f = File(panoPathFor(imagePath));
    try {
      if (on) {
        await f.writeAsString('1');
      } else if (f.existsSync()) {
        await f.delete();
      }
    } catch (_) {}
  }

  // -- Trimming -----------------------------------------------------------------

  /// Where a clip's trim choice lives: next to it, with `.trim` appended.
  static String trimPathFor(String videoPath) => '$videoPath.trim';

  static VideoTrim? trimFor(String videoPath) {
    try {
      final f = File(trimPathFor(videoPath));
      if (!f.existsSync()) return null;
      return VideoTrim.fromJson(
          (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// Remember which part of the clip to send and which frame to show. The
  /// poster is redrawn from the chosen frame at once.
  static Future<void> writeTrim(String videoPath, VideoTrim trim) async {
    await File(trimPathFor(videoPath)).writeAsString(jsonEncode(trim.toJson()));
    await writePosterFor(videoPath, at: trim.posterAt ?? trim.start, replace: true);
  }

  static Future<void> clearTrim(String videoPath) async {
    try {
      await File(trimPathFor(videoPath)).delete();
    } catch (_) {}
    await writePosterFor(videoPath, replace: true);
  }

  /// Extract and write a poster frame for a local video. Never throws.
  static Future<void> writePosterFor(String videoPath,
      {Duration? at, bool replace = false}) async {
    if (!replace && File(posterPathFor(videoPath)).existsSync()) return;
    try {
      final jpeg = await transcoder.poster(videoPath, at: at);
      if (jpeg == null) return;
      final decoded = img.decodeImage(jpeg);
      if (decoded == null) return;
      final small = _fit(decoded, 640);
      await File(posterPathFor(videoPath))
          .writeAsBytes(img.encodeJpg(small, quality: 70));
    } catch (e) {
      DebugLogService().warn('Media', 'No poster for video: $e');
    }
  }

  // -- Preparing for the relay ------------------------------------------------

  /// Prepare local media for sending: compress or transcode, thumbnail,
  /// encrypt, upload.
  ///
  /// Returns a [BlobRef] string to put in the message, or null when the upload
  /// failed and should be retried. Throws [MediaRejectedException] when the
  /// media cannot be sent at all, so the caller reports it rather than quietly
  /// dropping the attachment.
  static Future<String?> prepareForRelay(
    String filePath, {
    Duration? videoLimit,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw const MediaRejectedException('That file is no longer available.');
    }

    Uint8List payload;
    String mimeType;
    String? thumbnail;

    if (looksLikeVideo(filePath)) {
      final trim = trimFor(filePath);
      final out = await transcoder.transcode(filePath,
          start: trim?.start, end: trim?.end);
      final duration = out.duration;
      if (videoLimit != null && duration != null && duration > videoLimit) {
        throw MediaRejectedException(
          'That video is ${_describe(duration)} long; the limit here is '
          '${_describe(videoLimit)}.',
        );
      }
      payload = await File(out.path).readAsBytes();
      mimeType = 'video/mp4';
      thumbnail = _thumbnailFromJpeg(out.posterJpeg);
    } else {
      final raw = await file.readAsBytes();
      final image = img.decodeImage(raw);
      if (image == null) {
        throw const MediaRejectedException('That file is not an image.');
      }

      // Resize to max 1600px on the longest side.
      final resized = _fit(image, 1600);
      payload = Uint8List.fromList(img.encodeJpg(resized, quality: 80));
      mimeType = 'image/jpeg';
      thumbnail = _thumbnailFor(image);
    }

    if (payload.length > maxMediaBytes) {
      throw MediaRejectedException(
        'That comes to ${payload.length ~/ (1024 * 1024)} MB after '
        'preparation; the limit is ${maxMediaBytes ~/ (1024 * 1024)} MB.',
      );
    }

    final ref = await BlobService().upload(
      bytes: payload,
      mimeType: mimeType,
      thumbnail: thumbnail,
    );
    if (ref == null) return null;

    DebugLogService().info('Media',
        'Prepared ${payload.length ~/ 1024}KB $mimeType blob');
    return ref.encode();
  }

  /// Upload a recorded voice note as an encrypted blob and return its
  /// reference. Audio is sent as recorded; there is no re-encoding step.
  /// Throws [MediaRejectedException] when the file is missing or too large,
  /// returns null when the upload failed and should be retried.
  static Future<String?> prepareAudioForRelay(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw const MediaRejectedException('That voice note is no longer available.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxMediaBytes) {
      throw MediaRejectedException(
          'That voice note is ${bytes.length ~/ (1024 * 1024)} MB; the limit is '
          '${maxMediaBytes ~/ (1024 * 1024)} MB.');
    }
    final ref = await BlobService().upload(bytes: bytes, mimeType: audioMimeFor(filePath));
    if (ref == null) return null;
    DebugLogService().info('Media', 'Prepared ${bytes.length ~/ 1024}KB voice note');
    return ref.encode();
  }

  static String audioMimeFor(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.ogg') || lower.endsWith('.opus')) return 'audio/ogg';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.wav')) return 'audio/wav';
    return 'audio/mp4';
  }

  static img.Image _fit(img.Image image, int longest) {
    if (image.width >= image.height) {
      return image.width > longest ? img.copyResize(image, width: longest) : image;
    }
    return image.height > longest ? img.copyResize(image, height: longest) : image;
  }

  /// A small inline preview, so a feed renders before any blob is fetched.
  static String? _thumbnailFor(img.Image image) {
    try {
      final thumb = _fit(image, 320);
      final bytes = img.encodeJpg(thumb, quality: 55);
      // Keep it genuinely small — this rides inside every message.
      if (bytes.length > 24 * 1024) return null;
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  static String? _thumbnailFromJpeg(Uint8List? jpeg) {
    if (jpeg == null) return null;
    final decoded = img.decodeImage(jpeg);
    return decoded == null ? null : _thumbnailFor(decoded);
  }

  static bool looksLikeVideo(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm');
  }

  // -- Receiving --------------------------------------------------------------

  /// Resolve a received media reference to a local file path.
  static Future<String?> decodeAndSaveImage(String reference) async {
    try {
      final ref = BlobRef.tryDecode(reference);
      if (ref == null) {
        DebugLogService()
            .warn('Media', 'Unrecognised media reference; ignoring');
        return null;
      }
      return BlobService().materialise(ref);
    } catch (e) {
      DebugLogService().error('Media', 'Failed to fetch media: $e');
      return null;
    }
  }

  /// The inline preview for a reference, if it has one.
  ///
  /// Lets a list render immediately and fetch the full blob lazily.
  static String? thumbnailOf(String reference) =>
      BlobRef.tryDecode(reference)?.thumbnail;

  Future<void> deleteMedia(String ref) async {
    try {
      final file = File(ref);
      if (file.existsSync()) {
        await file.delete();
      }
      final poster = File(posterPathFor(ref));
      if (poster.existsSync()) await poster.delete();
      final prov = File(provenancePathFor(ref));
      if (prov.existsSync()) await prov.delete();
    } catch (_) {}
  }
}
