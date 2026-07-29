import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/blob.dart';
import 'blob_service.dart';
import 'debug_log_service.dart';

/// Handles media picking, local storage, and base64 encoding for relay transfer.
///
/// Images are compressed and stored locally. For relay transfer, small images
/// are encoded as base64 data URIs. Received images are decoded and saved locally.
class MediaService extends ChangeNotifier {
  final ImagePicker _picker = ImagePicker();

  /// Pick an image from gallery and return its local path.
  Future<String?> pickAndStoreImage() async {
    try {
      final image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (image == null) return null;

      // Privacy: Strip metadata (EXIF/GPS) before storage
      final strippedPath = await _stripMetadata(image.path);
      return strippedPath;
    } catch (e) {
      DebugLogService().error('Media', 'Error picking image: $e');
      return null;
    }
  }

  /// Strip all metadata from an image by re-encoding it.
  Future<String?> _stripMetadata(String filePath) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return filePath;

      // Re-encoding as JPEG or PNG without EXIF
      final ext = filePath.split('.').last.toLowerCase();
      Uint8List strippedBytes;
      if (ext == 'png') {
        strippedBytes = Uint8List.fromList(img.encodePng(image));
      } else {
        strippedBytes = Uint8List.fromList(img.encodeJpg(image, quality: 85));
      }

      // Overwrite or create new temp file
      final dir = await getTemporaryDirectory();
      final fileName = 'stripped_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final strippedFile = File('${dir.path}/$fileName');
      await strippedFile.writeAsBytes(strippedBytes);
      
      DebugLogService().success('Media', 'Image metadata stripped successfully');
      return strippedFile.path;
    } catch (e) {
      DebugLogService().error('Media', 'Failed to strip metadata: $e');
      return filePath; // Fallback to original if stripping fails
    }
  }

  /// Pick a video from gallery and return its local path.
  Future<String?> pickAndStoreVideo() async {
    try {
      final video = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      return video?.path;
    } catch (e) {
      DebugLogService().error('Media', 'Error picking video: $e');
      return null;
    }
  }

  /// Encode a local image file as a base64 data URI for relay transfer.
  /// Resizes to max 1024px and compresses to JPEG quality 70 before encoding.
  /// Maximum media we will upload. Roughly 512 chunks of 48 KB.
  static const int maxMediaBytes = 24 * 1024 * 1024;

  /// Prepare local media for sending: compress, thumbnail, encrypt, upload.
  ///
  /// Returns a [BlobRef] string to put in the message. Media used to be inlined
  /// as a base64 data URI, so every photo counted against the message size cap
  /// and was re-encrypted and re-sent once per recipient. Now the bytes are
  /// uploaded once and the message carries a reference plus a small thumbnail.
  static Future<String?> encodeImageForRelay(String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;

      final raw = await file.readAsBytes();
      final isVideo = _looksLikeVideo(filePath);

      Uint8List payload;
      String mimeType;
      String? thumbnail;

      if (isVideo) {
        // No transcoding: there is no video codec in the dependency set, so we
        // send what the camera produced. Large clips are refused rather than
        // silently truncated, and there is no thumbnail because extracting a
        // frame also needs a decoder we do not have.
        payload = raw;
        mimeType = 'video/mp4';
      } else {
        final image = img.decodeImage(raw);
        if (image == null) return null;

        // Resize to max 1600px on the longest side. Larger than the old 1024
        // because the size cap no longer applies once media is out of band.
        final resized = (image.width > image.height)
            ? (image.width > 1600 ? img.copyResize(image, width: 1600) : image)
            : (image.height > 1600 ? img.copyResize(image, height: 1600) : image);

        payload = Uint8List.fromList(img.encodeJpg(resized, quality: 80));
        mimeType = 'image/jpeg';
        thumbnail = _thumbnailFor(image);
      }

      if (payload.length > maxMediaBytes) {
        DebugLogService().error('Media',
            'Media is ${payload.length ~/ (1024 * 1024)}MB; limit is '
            '${maxMediaBytes ~/ (1024 * 1024)}MB');
        return null;
      }

      final ref = await BlobService().upload(
        bytes: payload,
        mimeType: mimeType,
        thumbnail: thumbnail,
      );
      if (ref == null) return null;

      DebugLogService().info('Media',
          'Prepared ${raw.length ~/ 1024}KB as ${payload.length ~/ 1024}KB blob');
      return ref.encode();
    } catch (e) {
      DebugLogService().error('Media', 'Failed to prepare media: $e');
      return null;
    }
  }

  /// A small inline preview, so a feed renders before any blob is fetched.
  static String? _thumbnailFor(img.Image image) {
    try {
      final thumb = (image.width > image.height)
          ? img.copyResize(image, width: 320)
          : img.copyResize(image, height: 320);
      final bytes = img.encodeJpg(thumb, quality: 55);
      // Keep it genuinely small — this rides inside every message.
      if (bytes.length > 24 * 1024) return null;
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  static bool _looksLikeVideo(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm');
  }

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
    } catch (_) {}
  }
}
