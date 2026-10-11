import 'package:flutter/material.dart';

import '../../services/media_service.dart';

/// Where a story's picture or clip comes from.
///
/// Returns the stored local path and whether it is a short clip meant to
/// play round and round. The clip loops forward; the app has no way to play
/// a clip backwards and does not pretend to.
Future<({String path, bool loop})?> pickStorySource(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined),
          title: const Text('Take a photo'),
          onTap: () => Navigator.pop(ctx, 'camera'),
        ),
        ListTile(
          leading: const Icon(Icons.camera_front_outlined),
          title: const Text('Selfie'),
          subtitle: const Text('Front camera'),
          onTap: () => Navigator.pop(ctx, 'selfie'),
        ),
        ListTile(
          leading: const Icon(Icons.loop),
          title: const Text('Loop clip'),
          subtitle: const Text('Three seconds, plays round and round'),
          onTap: () => Navigator.pop(ctx, 'loop'),
        ),
        ListTile(
          leading: const Icon(Icons.grid_view_outlined),
          title: const Text('Collage'),
          subtitle: const Text('Two to four pictures laid out as one'),
          onTap: () => Navigator.pop(ctx, 'collage'),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Choose from library'),
          onTap: () => Navigator.pop(ctx, 'library'),
        ),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return null;
  final media = MediaService();
  final messenger = ScaffoldMessenger.of(context);
  String? path;
  var loop = false;
  try {
    switch (choice) {
      case 'camera':
        path = await media.captureImage();
      case 'selfie':
        path = await media.captureImage(front: true);
      case 'loop':
        path = await media.recordShortClip();
        loop = path != null;
      case 'collage':
        final picked = await media.pickAndStoreImages(max: 4);
        if (picked.isEmpty) return null;
        if (picked.length == 1) {
          messenger.showSnackBar(const SnackBar(content: Text('A collage needs at least two pictures.')));
          return null;
        }
        path = await MediaService.composeCollage(picked);
      default:
        path = await media.pickAndStoreImage();
    }
  } on MediaRejectedException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return null;
  }
  if (path == null) return null;
  return (path: path, loop: loop);
}
