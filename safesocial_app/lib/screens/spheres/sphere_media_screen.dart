import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/album_service.dart';
import '../../services/feed_service.dart';
import '../../services/sphere_chat_service.dart';
import '../../services/sphere_service.dart';
import '../../widgets/media_thumb.dart';

/// Every photo and video that has passed through one sphere: posts, stories
/// still live, album items and chat attachments, newest first.
///
/// Entirely local — it is a different view of what this device already holds,
/// so no one is asked for anything and nothing leaves.
class SphereMediaScreen extends StatelessWidget {
  final String sphereId;
  const SphereMediaScreen({super.key, required this.sphereId});

  @override
  Widget build(BuildContext context) {
    final sphere = context.watch<SphereService>().sphere(sphereId);
    final feed = context.watch<FeedService>();
    final albums = context.watch<AlbumService>();
    final chat = context.watch<SphereChatService>();

    final items = <_Item>[];
    for (final post in feed.postsIn(sphereId)) {
      for (final ref in post.mediaRefs) {
        items.add(_Item(ref, post.createdAt, 'Post by ${post.authorName}'));
      }
    }
    for (final album in albums.albums.where((a) => a.sphereId == sphereId)) {
      for (final item in album.items) {
        items.add(_Item(item.mediaRef, item.addedAt, album.name));
      }
    }
    for (final message in chat.messagesIn(sphereId)) {
      for (final ref in message.mediaRefs) {
        items.add(_Item(ref, message.timestamp, 'Sphere chat'));
      }
    }
    final seen = <String>{};
    final unique = items.where((i) => seen.add(i.ref)).toList()
      ..sort((a, b) => b.at.compareTo(a.at));

    return Scaffold(
      appBar: AppBar(
        title: Text(sphere == null ? 'Media' : '${sphere.name} · media'),
      ),
      body: unique.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nothing shared here yet. Photos and videos from posts, '
                  'albums and the sphere chat will collect on this page.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: unique.length,
              itemBuilder: (context, i) {
                final item = unique[i];
                return GestureDetector(
                  onTap: () => context.push(
                      '/media/view?ref=${Uri.encodeComponent(item.ref)}'),
                  onLongPress: () => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(item.source), duration: const Duration(seconds: 2))),
                  child: MediaThumb(ref: item.ref, fit: BoxFit.cover),
                );
              },
            ),
    );
  }
}

class _Item {
  final String ref;
  final DateTime at;
  final String source;
  const _Item(this.ref, this.at, this.source);
}
