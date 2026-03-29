import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../../services/album_service.dart';
import '../../services/media_service.dart';
import '../../services/contact_service.dart';
import '../../widgets/avatar.dart';

/// Screen displaying the photos within a shared album.
class AlbumDetailScreen extends StatelessWidget {
  final String albumId;
  const AlbumDetailScreen({super.key, required this.albumId});

  @override
  Widget build(BuildContext context) {
    final album = context.watch<AlbumService>().getAlbum(albumId);
    if (album == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Album not found')));
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(album.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text('${album.items.length} items', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            onPressed: () => _showInviteDialog(context, albumId),
          ),
        ],
      ),
      body: album.items.isEmpty
          ? _buildEmptyAlbum(context, theme)
          : GridView.builder(
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: album.items.length,
              itemBuilder: (ctx, i) {
                final item = album.items[i];
                return GestureDetector(
                  onTap: () => context.push('/media/view?ref=${Uri.encodeComponent(item.mediaRef)}'),
                  child: Hero(
                    tag: item.mediaRef,
                    child: Image.file(File(item.mediaRef), fit: BoxFit.cover),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addPhoto(context),
        child: const Icon(Icons.add_a_photo),
      ),
    );
  }

  Widget _buildEmptyAlbum(BuildContext context, ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_photo_alternate_outlined, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          const Text('This album is empty'),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => _addPhoto(context),
            child: const Text('Add your first photo'),
          ),
        ],
      ),
    );
  }

  Future<void> _addPhoto(BuildContext context) async {
    final mediaService = context.read<MediaService>();
    final albumService = context.read<AlbumService>();
    
    final path = await mediaService.pickAndStoreImage();
    if (path != null) {
      await albumService.addMediaToAlbum(albumId, path, 'image');
    }
  }

  void _showInviteDialog(BuildContext context, String albumId) {
    final contactService = context.read<ContactService>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('Invite to Album', style: Theme.of(context).textTheme.titleMedium),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: contactService.contacts.length,
              itemBuilder: (ctx, i) {
                final c = contactService.contacts[i];
                return ListTile(
                  leading: UserAvatar(displayName: c.displayName, size: AvatarSize.small),
                  title: Text(c.displayName),
                  onTap: () {
                    // FUTURE: Implement album invitation handshake
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invitation sent!')));
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
