import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/feed_service.dart';
import '../../widgets/avatar.dart';

/// Facebook-style notifications screen showing activity on posts.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final feedService = context.watch<FeedService>();

    // Build notification items from reactions and comments on the user's posts.
    final notifications = <_NotificationItem>[];
    for (final post in feedService.posts.where((p) => p.authorId == 'self')) {
      for (final r in post.reactions) {
        if (r.reactorId != 'self') {
          notifications.add(_NotificationItem(
            actorName: r.reactorId,
            action: 'reacted ${r.emoji} to your post',
            postPreview: post.content,
            timestamp: r.timestamp,
            icon: Icons.emoji_emotions_outlined,
            iconColor: Colors.amber,
          ));
        }
      }
      for (final c in post.comments) {
        if (c.authorId != 'self') {
          notifications.add(_NotificationItem(
            actorName: c.authorName.isNotEmpty ? c.authorName : c.authorId,
            action: 'commented on your post',
            postPreview: c.text,
            timestamp: c.createdAt,
            icon: Icons.chat_bubble_outline,
            iconColor: cs.primary,
          ));
        }
      }
      for (final like in post.likes) {
        if (like != 'self') {
          notifications.add(_NotificationItem(
            actorName: like,
            action: 'liked your post',
            postPreview: post.content,
            timestamp: post.createdAt,
            icon: Icons.thumb_up_outlined,
            iconColor: cs.primary,
          ));
        }
      }
    }

    // Sort by most recent first.
    notifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Notifications',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 24,
          ),
        ),
      ),
      body: notifications.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size: 64,
                    color: cs.primary.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No notifications yet',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Activity on your posts will show up here.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 80),
              itemCount: notifications.length,
              itemBuilder: (context, index) {
                final n = notifications[index];
                return _NotificationTile(item: n);
              },
            ),
    );
  }
}

class _NotificationItem {
  final String actorName;
  final String action;
  final String postPreview;
  final DateTime timestamp;
  final IconData icon;
  final Color iconColor;

  _NotificationItem({
    required this.actorName,
    required this.action,
    required this.postPreview,
    required this.timestamp,
    required this.icon,
    required this.iconColor,
  });
}

class _NotificationTile extends StatelessWidget {
  final _NotificationItem item;

  const _NotificationTile({required this.item});

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${diff.inDays ~/ 7}w ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return InkWell(
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                UserAvatar(
                  displayName: item.actorName,
                  size: AvatarSize.medium,
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: item.iconColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.surface, width: 1.5),
                    ),
                    child: Icon(item.icon, size: 10, color: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RichText(
                    text: TextSpan(
                      style: theme.textTheme.bodyMedium,
                      children: [
                        TextSpan(
                          text: item.actorName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: ' ${item.action}'),
                      ],
                    ),
                  ),
                  if (item.postPreview.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '"${item.postPreview}"',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    _timeAgo(item.timestamp),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.primary,
                      fontSize: 11,
                    ),
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
