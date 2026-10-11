import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../crypto/blob.dart';
import '../services/media_service.dart';

/// A thumbnail for any media reference the app holds.
///
/// A reference is one of three things, and every list used to handle only
/// one: a local image path, a local video path (shown by its poster frame),
/// or a [BlobRef] that has not been fetched yet (shown by its inline
/// thumbnail). This widget handles all three so feed, chat, albums and the
/// composer agree on what a video looks like.
class MediaThumb extends StatelessWidget {
  final String ref;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;

  /// Overlay a play badge on video.
  final bool showPlayBadge;

  const MediaThumb({
    super.key,
    required this.ref,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.showPlayBadge = true,
  });

  /// Whether [ref] names a video, however it is stored.
  static bool isVideo(String ref) =>
      BlobRef.tryDecode(ref)?.isVideo ?? MediaService.looksLikeVideo(ref);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pending = BlobRef.tryDecode(ref);

    Widget image;
    bool video;

    if (pending != null) {
      video = pending.isVideo;
      final thumb = pending.thumbnail;
      image = thumb != null
          ? Image.memory(
              base64Decode(thumb.split(',').last),
              width: width,
              height: height,
              fit: fit,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _placeholder(cs, video),
            )
          : _placeholder(cs, video);
    } else if (File(ref).existsSync()) {
      video = MediaService.looksLikeVideo(ref);
      final source = video ? MediaService.posterFor(ref) : ref;
      image = source == null
          ? _placeholder(cs, video)
          : Image.file(
              File(source),
              width: width,
              height: height,
              fit: fit,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _placeholder(cs, video),
            );
    } else {
      video = MediaService.looksLikeVideo(ref);
      image = _placeholder(cs, video);
    }

    Widget child = image;
    if (video && showPlayBadge) {
      child = Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.center,
        children: [
          image,
          Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 24),
            ),
          ),
        ],
      );
    }

    if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius!, child: child);
    }
    if (width != null || height != null) {
      child = SizedBox(width: width, height: height, child: child);
    }
    return child;
  }

  Widget _placeholder(ColorScheme cs, bool video) {
    return Container(
      width: width,
      height: height,
      color: cs.surfaceContainerHighest,
      child: Center(
        child: Icon(
          video ? Icons.videocam_outlined : Icons.image_outlined,
          size: 32,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
