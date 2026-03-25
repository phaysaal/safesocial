import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Thumbnail preview for a media item (image or video).
///
/// Shows a placeholder icon when the media file is not available locally.
/// Tappable to open the full MediaViewerScreen.
class MediaPreview extends StatelessWidget {
  final String mediaRef;

  const MediaPreview({super.key, required this.mediaRef});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isLocalFile = File(mediaRef).existsSync();
    final isVideo = mediaRef.endsWith('.mp4') ||
        mediaRef.endsWith('.mov') ||
        mediaRef.endsWith('.avi');

    return GestureDetector(
      onTap: () {
        context.push('/media/view?ref=${Uri.encodeComponent(mediaRef)}');
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 120,
          height: 120,
          child: isLocalFile
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(mediaRef),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildPlaceholder(colorScheme, isVideo),
                    ),
                    if (isVideo)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                  ],
                )
              : _buildPlaceholder(colorScheme, isVideo),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(ColorScheme colorScheme, bool isVideo) {
    return Container(
      color: colorScheme.surface,
      child: Center(
        child: Icon(
          isVideo ? Icons.videocam_outlined : Icons.image_outlined,
          size: 32,
          color: colorScheme.onSurface.withOpacity(0.3),
        ),
      ),
    );
  }
}
