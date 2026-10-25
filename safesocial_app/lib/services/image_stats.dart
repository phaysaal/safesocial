import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import '../crypto/blob.dart';
import '../models/look.dart';
import 'media_service.dart';

/// Reads [ImageStats] from a picture on this phone: a local file, or the
/// inline thumbnail of a blob not fetched yet (small, and good enough for a
/// white balance). Nothing leaves the phone and no face is looked for.
class ImageStatsLoader {
  ImageStatsLoader._();

  static ImageStats of(img.Image image) {
    final small = image.width > 48 ? img.copyResize(image, width: 48) : image;
    final rgb = <int>[];
    for (final p in small) {
      rgb
        ..add(p.r.toInt())
        ..add(p.g.toInt())
        ..add(p.b.toInt());
    }
    return ImageStats.fromSamples(rgb);
  }

  /// Null when there is nothing on the phone to read.
  static Future<ImageStats?> forRef(String ref) async {
    try {
      final pending = BlobRef.tryDecode(ref);
      if (pending != null) {
        final thumb = pending.thumbnail;
        if (thumb == null) return null;
        final decoded = img.decodeImage(base64Decode(thumb.split(',').last));
        return decoded == null ? null : of(decoded);
      }
      if (!File(ref).existsSync()) return null;
      final source = MediaService.looksLikeVideo(ref) ? MediaService.posterFor(ref) : ref;
      if (source == null) return null;
      final decoded = img.decodeImage(await File(source).readAsBytes());
      return decoded == null ? null : of(decoded);
    } catch (_) {
      return null;
    }
  }
}
