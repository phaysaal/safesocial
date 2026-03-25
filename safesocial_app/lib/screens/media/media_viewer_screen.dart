import 'dart:io';

import 'package:flutter/material.dart';

/// Full-screen media viewer with pinch-to-zoom support.
///
/// Currently handles local file paths. Will be extended to load media
/// from Veilid's block store via content-addressed references.
class MediaViewerScreen extends StatelessWidget {
  final String? mediaRef;

  const MediaViewerScreen({super.key, this.mediaRef});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () {
              // TODO: Implement sharing via Veilid.
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Sharing coming soon')),
              );
            },
            tooltip: 'Share',
          ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: () {
              // TODO: Implement download/save to gallery.
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Download coming soon')),
              );
            },
            tooltip: 'Download',
          ),
        ],
      ),
      body: Center(
        child: mediaRef != null && File(mediaRef!).existsSync()
            ? InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(
                  File(mediaRef!),
                  fit: BoxFit.contain,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image_outlined,
                    size: 80,
                    color: colorScheme.onSurface.withOpacity(0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No media to display',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Media viewer will display images and videos\n'
                    'from the decentralized block store.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withOpacity(0.3),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
