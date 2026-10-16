import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/sphere_service.dart';
import '../../widgets/post_card.dart';

/// Every post of ours that is still around, newest first, from the profile.
class OwnPostsScreen extends StatelessWidget {
  const OwnPostsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = context.watch<IdentityService>().publicKey;
    final posts = context
        .watch<FeedService>()
        .posts
        .where((p) => p.authorId == me && !p.isStory)
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text('Your posts · ${posts.length}')),
      body: posts.isEmpty
          ? const Center(child: Text('Nothing posted yet.'))
          : ListView.builder(
              itemCount: posts.length,
              itemBuilder: (_, i) => PostCard(post: posts[i]),
            ),
    );
  }
}

/// What we did, in order: posts, comments and reactions, read off the posts
/// this device holds. Nothing here is fetched or sent; it is a view of what
/// is already on the phone.
class OwnActivityScreen extends StatelessWidget {
  const OwnActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = context.watch<IdentityService>().publicKey;
    final feed = context.watch<FeedService>();
    final spheres = context.watch<SphereService>();
    final items = <_Activity>[];
    String where(Post p) => p.sphereIds
        .map((id) => spheres.sphere(id)?.name)
        .whereType<String>()
        .join(', ');
    for (final p in feed.posts) {
      if (p.authorId == me) {
        items.add(_Activity(p.createdAt, p.isStory ? Icons.bolt_outlined : Icons.article_outlined,
            p.isStory ? 'You shared a flash in ${where(p)}' : 'You posted in ${where(p)}',
            p.content, p.id));
      }
      for (final c in p.comments) {
        if (c.authorId == me) {
          items.add(_Activity(c.createdAt, Icons.forum_outlined,
              'You commented on ${p.authorId == me ? 'your post' : "${p.authorName}'s post"}',
              c.text, p.id));
        }
      }
      for (final r in p.reactions) {
        if (r.reactorId == me) {
          items.add(_Activity(r.timestamp, Icons.add_reaction_outlined,
              'You reacted ${r.emoji} to ${p.authorId == me ? 'your post' : "${p.authorName}'s post"}',
              p.content, p.id));
        }
      }
    }
    items.sort((a, b) => b.at.compareTo(a.at));
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Your activity')),
      body: items.isEmpty
          ? const Center(child: Text('Nothing yet.'))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final a = items[i];
                return ListTile(
                  leading: Icon(a.icon, color: cs.primary),
                  title: Text(a.title),
                  subtitle: Text(
                    a.detail.trim().isEmpty ? _when(a.at) : '${_when(a.at)} · ${a.detail}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => context.push('/post/${a.postId}'),
                );
              },
            ),
    );
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return '${t.day}/${t.month}/${t.year}';
  }
}

class _Activity {
  final DateTime at;
  final IconData icon;
  final String title;
  final String detail;
  final String postId;
  _Activity(this.at, this.icon, this.title, this.detail, this.postId);
}
