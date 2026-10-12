import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/media_protection.dart';
import '../../services/album_service.dart';
import '../../services/feed_service.dart';
import '../../services/sphere_chat_service.dart';
import '../../services/sphere_service.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/protected_veil.dart';
import '../../widgets/message_cards.dart';

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
        items.add(_Item(ref, post.createdAt, 'Post by ${post.authorName}', post.protection));
      }
    }
    for (final album in albums.albums.where((a) => a.sphereId == sphereId)) {
      for (final item in album.items) {
        items.add(_Item(item.mediaRef, item.addedAt, album.name));
      }
    }
    for (final message in chat.messagesIn(sphereId)) {
      for (final ref in message.mediaRefs) {
        items.add(_Item(ref, message.timestamp, 'Sphere chat', message.protection));
      }
    }
    final seen = <String>{};
    final unique = items.where((i) => seen.add(i.ref)).toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    final files = chat.filesIn(sphereId);

    return Scaffold(
      appBar: AppBar(
        title: Text(sphere == null ? 'Media' : '${sphere.name} · media'),
      ),
      body: unique.isEmpty && files.isEmpty
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
          : ListView(
              children: [
                if (files.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text('Files', style: Theme.of(context).textTheme.titleMedium),
                  ),
                  for (final f in files)
                    ListTile(
                      leading: Icon(FileCard.iconFor(f.payload?['mime'] as String? ?? '')),
                      title: Text(f.payload?['name'] as String? ?? f.content, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${FileCard.describeSize(f.payload?['size'] is int ? f.payload!['size'] as int : 0)} · ${f.timestamp.day}/${f.timestamp.month}'),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => openFileMessage(context, f),
                    ),
                  const Divider(),
                ],
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
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
                          '/media/view?ref=${Uri.encodeComponent(item.ref)}${item.protection?.query ?? ''}'),
                      onLongPress: () => ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(item.source), duration: const Duration(seconds: 2))),
                      child: item.protection == null
                          ? MediaThumb(ref: item.ref, fit: BoxFit.cover)
                          : Stack(fit: StackFit.expand, children: [
                              MediaThumb(ref: item.ref, fit: BoxFit.cover),
                              const Positioned(right: 4, top: 4, child: ProtectedMark()),
                            ]),
                    );
                  },
                ),
              ],
            ),
    );
  }
}

class _Item {
  final String ref;
  final DateTime at;
  final String source;
  final MediaProtection? protection;
  const _Item(this.ref, this.at, this.source, [this.protection]);
}
