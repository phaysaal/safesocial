import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../services/feed_service.dart';
import '../../widgets/post_card.dart';

/// Screen to display historical posts from "On This Day".
class MemoriesScreen extends StatelessWidget {
  const MemoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final feedService = context.watch<FeedService>();
    final memories = feedService.memories;

    return Scaffold(
      appBar: AppBar(
        title: const Text('On This Day'),
      ),
      body: memories.isEmpty
          ? const Center(child: Text('No memories for today.'))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: memories.length,
              itemBuilder: (context, index) {
                final post = memories[index];
                final yearsAgo = DateTime.now().year - post.createdAt.year;
                
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        '$yearsAgo ${yearsAgo == 1 ? 'year' : 'years'} ago today',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    PostCard(post: post),
                    const Divider(height: 32),
                  ],
                );
              },
            ),
    );
  }
}
