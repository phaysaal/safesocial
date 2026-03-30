import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

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
  static Future<String?> encodeImageForRelay(String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;

      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return null;

      // Resize to max 1024px on the longest side
      final resized = (image.width > image.height)
          ? (image.width > 1024 ? img.copyResize(image, width: 1024) : image)
          : (image.height > 1024 ? img.copyResize(image, height: 1024) : image);

      // Encode as JPEG quality 70 (~50–150KB for typical photos)
      final compressed = Uint8List.fromList(img.encodeJpg(resized, quality: 70));

      DebugLogService().info('Media', 'Image compressed: ${bytes.length ~/ 1024}KB → ${compressed.length ~/ 1024}KB');
      return 'data:image/jpeg;base64,${base64Encode(compressed)}';
    } catch (e) {
      DebugLogService().error('Media', 'Failed to encode image: $e');
      return null;
    }
  }

  /// Decode a base64 data URI and save to local storage.
  /// Returns the local file path.
  static Future<String?> decodeAndSaveImage(String dataUri) async {
    try {
      if (!dataUri.startsWith('data:image/')) return null;

      final parts = dataUri.split(',');
      if (parts.length != 2) return null;

      final bytes = base64Decode(parts[1]);
      final ext = dataUri.contains('png') ? 'png' : 'jpg';
      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'media_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);

      DebugLogService().info('Media', 'Saved received image: $fileName');
      return file.path;
    } catch (e) {
      DebugLogService().error('Media', 'Failed to decode image: $e');
      return null;
    }
  }

  Future<void> deleteMedia(String ref) async {
    try {
      final file = File(ref);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
