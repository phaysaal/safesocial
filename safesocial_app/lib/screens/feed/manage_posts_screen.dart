import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';

/// Our posts in bulk: archive or delete several at once, see what is
/// archived, and bring back what was deleted within thirty days.
class ManagePostsScreen extends StatefulWidget {
  const ManagePostsScreen({super.key});

  @override
  State<ManagePostsScreen> createState() => _ManagePostsScreenState();
}

class _ManagePostsScreenState extends State<ManagePostsScreen> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<FeedService>();
    final me = context.watch<IdentityService>().publicKey;
    final mine = feed.posts.where((p) => p.authorId == me).toList();
    final archived = feed.archivedPosts.where((p) => p.authorId == me).toList();
    final trash = feed.trashedPosts;

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_selected.isEmpty ? 'Manage posts' : '${_selected.length} selected'),
          actions: [
            if (_selected.isNotEmpty) ...[
              IconButton(
                tooltip: 'Archive',
                icon: const Icon(Icons.archive_outlined),
                onPressed: () async {
                  for (final id in _selected.toList()) {
                    await feed.setArchived(id, true);
                  }
                  setState(_selected.clear);
                },
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(context, feed, _selected.toList()),
              ),
            ],
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Posts'),
            Tab(text: 'Archived'),
            Tab(text: 'Trash'),
          ]),
        ),
        body: TabBarView(
          children: [
            _list(
              mine,
              empty: 'No posts of yours',
              selectable: true,
              trailing: (p) => null,
            ),
            _list(
              archived,
              empty: 'Nothing archived. Archived posts stay in their spheres; only your feed hides them.',
              trailing: (p) => TextButton(
                onPressed: () => feed.setArchived(p.id, false),
                child: const Text('Unarchive'),
              ),
            ),
            _list(
              trash,
              empty: 'Trash is empty. A deleted post stays here for thirty days.',
              subtitle: (p) {
                final at = feed.trashedAt(p.id);
                if (at == null) return null;
                final left = FeedService.trashKeepsFor - DateTime.now().difference(at);
                return 'Gone for good in ${left.inDays} day${left.inDays == 1 ? '' : 's'}';
              },
              trailing: (p) => Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(
                  onPressed: () => feed.restoreFromTrash(p.id),
                  child: const Text('Restore'),
                ),
                IconButton(
                  tooltip: 'Delete forever',
                  icon: const Icon(Icons.delete_forever_outlined),
                  onPressed: () => feed.emptyTrash(onlyId: p.id),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(
    List<Post> posts, {
    required String empty,
    bool selectable = false,
    String? Function(Post)? subtitle,
    required Widget? Function(Post) trailing,
  }) {
    final theme = Theme.of(context);
    if (posts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(empty, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
        ),
      );
    }
    return ListView.builder(
      itemCount: posts.length,
      itemBuilder: (_, i) {
        final p = posts[i];
        final title = p.content.isNotEmpty
            ? p.content
            : (p.payload?['title'] as String?) ??
                (p.payload?['question'] as String?) ??
                (p.mediaRefs.isNotEmpty ? 'Photo post' : 'Post');
        final sub = subtitle?.call(p) ??
            '${p.createdAt.toLocal().toString().substring(0, 16)}'
                '${p.mediaRefs.isNotEmpty ? ' · ${p.mediaRefs.length} media' : ''}';
        return ListTile(
          leading: selectable
              ? Checkbox(
                  value: _selected.contains(p.id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(p.id);
                    } else {
                      _selected.remove(p.id);
                    }
                  }),
                )
              : null,
          title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(sub),
          trailing: trailing(p),
          onTap: selectable
              ? () => setState(() {
                    if (!_selected.remove(p.id)) _selected.add(p.id);
                  })
              : null,
        );
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, FeedService feed, List<String> ids) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${ids.length} post${ids.length == 1 ? '' : 's'}?'),
        content: const Text(
            'Everyone in their spheres is told to drop them. You can restore them from the trash for thirty days.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    for (final id in ids) {
      await feed.deletePost(id);
    }
    if (mounted) setState(_selected.clear);
  }
}
