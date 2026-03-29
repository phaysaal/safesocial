import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../../services/album_service.dart';
import '../../widgets/avatar.dart';

/// Screen displaying all shared photo albums.
class AlbumListScreen extends StatelessWidget {
  const AlbumListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final albumService = context.watch<AlbumService>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Shared Albums',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      body: albumService.albums.isEmpty
          ? _buildEmptyState(theme)
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.85,
              ),
              itemCount: albumService.albums.length,
              itemBuilder: (context, index) {
                final album = albumService.albums[index];
                return _AlbumCard(albumId: album.dhtKey);
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateAlbumDialog(context, albumService),
        label: const Text('New Album'),
        icon: const Icon(Icons.add_a_photo_outlined),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          const Text('No shared albums yet'),
          const SizedBox(height: 8),
          const Text('Create one to share photos with your close circle.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  void _showCreateAlbumDialog(BuildContext context, AlbumService service) {
    final nameController = TextEditingController();
    final descController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Shared Album'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Album Name'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descController,
              decoration: const InputDecoration(labelText: 'Description (optional)'),
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                service.createAlbum(name, descController.text.trim());
              }
              Navigator.pop(ctx);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final String albumId;
  const _AlbumCard({required this.albumId});

  @override
  Widget build(BuildContext context) {
    final album = context.watch<AlbumService>().getAlbum(albumId);
    if (album == null) return const SizedBox();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return InkWell(
      onTap: () => context.push('/album/$albumId'),
      borderRadius: BorderRadius.circular(16),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outline.withValues(alpha: 0.1)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: cs.surfaceContainerHighest,
                child: album.items.isEmpty
                    ? Icon(Icons.image_outlined, color: cs.onSurfaceVariant, size: 32)
                    : const Icon(Icons.collections, color: Colors.blue, size: 32), // FUTURE: Show first image thumbnail
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  Text(
                    '${album.items.length} items',
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
