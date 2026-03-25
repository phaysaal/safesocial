import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// Handles media picking, storage, and retrieval.
///
/// Currently uses image_picker and stores files locally. In production,
/// media will be chunked and stored in Veilid's block store, with
/// references (hashes) shared in messages and posts.
class MediaService extends ChangeNotifier {
  final ImagePicker _picker = ImagePicker();

  /// Pick an image from the gallery or camera and return its local path.
  ///
  /// TODO: After picking, chunk the image and store in Veilid block store.
  /// Return the block store reference instead of a local path.
  Future<String?> pickAndStoreImage() async {
    try {
      final image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      return image?.path;
    } catch (e) {
      debugPrint('[MediaService] Error picking image: $e');
      return null;
    }
  }

  /// Pick a video from the gallery or camera and return its local path.
  ///
  /// TODO: After picking, chunk the video and store in Veilid block store.
  /// Return the block store reference instead of a local path.
  Future<String?> pickAndStoreVideo() async {
    try {
      final video = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      return video?.path;
    } catch (e) {
      debugPrint('[MediaService] Error picking video: $e');
      return null;
    }
  }

  /// Delete a media item by its reference.
  ///
  /// TODO: Implement block store deletion.
  Future<void> deleteMedia(String ref) async {
    debugPrint('[MediaService] Delete media requested for: $ref (placeholder).');
  }
}
