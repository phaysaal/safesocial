import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/feed_service.dart';
import '../../services/library_service.dart';
import '../../widgets/post_card.dart';

/// Posts the user has saved.
///
/// Entirely local — saving tells nobody, and on a network with no server there
/// is nothing that could learn it.
class SavedScreen extends StatelessWidget {
  const SavedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final library = context.watch<LibraryService>();
    final feed = context.watch<FeedService>();

    final collections = library.collectionNames;

    return DefaultTabController(
      length: collections.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Saved'),
          bottom: collections.length > 1
              ? TabBar(
                  isScrollable: true,
                  tabs: collections.map((c) => Tab(text: c)).toList(),
                )
              : null,
        ),
        body: TabBarView(
          children: collections.map((collection) {
            final ids = library.postsIn(collection).toSet();
            // Resolve against the feed, so a post from a sphere you left
            // stops appearing here too.
            final posts =
                feed.allPosts.where((p) => ids.contains(p.id)).toList();

            if (posts.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bookmark_border,
                          size: 48, color: cs.onSurfaceVariant),
                      const SizedBox(height: 12),
                      Text(
                        ids.isEmpty
                            ? 'Nothing saved yet'
                            : 'The posts saved here are no longer available',
                        style: TextStyle(color: cs.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Saving is private — it stays on this device.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }

            return ListView.builder(
              itemCount: posts.length,
              itemBuilder: (context, i) => PostCard(post: posts[i]),
            );
          }).toList(),
        ),
      ),
    );
  }
}
