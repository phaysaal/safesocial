import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../services/feed_service.dart';
import '../../widgets/avatar.dart';

/// Full post detail screen with complete comment thread.
class PostDetailScreen extends StatefulWidget {
  final String postId;

  const PostDetailScreen({super.key, required this.postId});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final _commentController = TextEditingController();

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final feedService = context.watch<FeedService>();

    final post = feedService.posts.cast<Post?>().firstWhere(
          (p) => p?.id == widget.postId,
          orElse: () => null,
        );

    if (post == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Post')),
        body: const Center(child: Text('Post not found')),
      );
    }

    final authorName = post.authorId == 'self'
        ? 'You'
        : (post.authorName.isNotEmpty ? post.authorName : post.authorId);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          "$authorName's Post",
          style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Author header ────────────────────────────
                Row(
                  children: [
                    UserAvatar(
                      displayName: authorName,
                      size: AvatarSize.medium,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            authorName,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _timeAgo(post.createdAt),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── Content ──────────────────────────────────
                if (post.content.isNotEmpty) ...[
                  Text(post.content, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 16),
                ],

                // ── Like / reaction counts ───────────────────
                if (post.likes.isNotEmpty || post.comments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        if (post.likes.isNotEmpty) ...[
                          Icon(Icons.thumb_up, size: 16, color: cs.primary),
                          const SizedBox(width: 4),
                          Text('${post.likes.length}',
                              style: theme.textTheme.bodySmall),
                        ],
                        const Spacer(),
                        if (post.comments.isNotEmpty)
                          Text(
                            '${post.comments.length} comment${post.comments.length == 1 ? '' : 's'}',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),

                // ── Action row ───────────────────────────────
                const Divider(),
                Row(
                  children: [
                    _ActionButton(
                      icon: post.isLikedBySelf
                          ? Icons.thumb_up
                          : Icons.thumb_up_outlined,
                      label: 'Like',
                      color: post.isLikedBySelf
                          ? cs.primary
                          : cs.onSurfaceVariant,
                      onTap: () =>
                          feedService.toggleLike(post.id),
                    ),
                    _ActionButton(
                      icon: Icons.chat_bubble_outline,
                      label: 'Comment',
                      color: cs.onSurfaceVariant,
                      onTap: () {
                        // Focus comment input
                        FocusScope.of(context).requestFocus(FocusNode());
                      },
                    ),
                    _ActionButton(
                      icon: Icons.share_outlined,
                      label: 'Share',
                      color: cs.onSurfaceVariant,
                      onTap: () {},
                    ),
                  ],
                ),
                const Divider(),
                const SizedBox(height: 8),

                // ── Comments list ────────────────────────────
                if (post.comments.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No comments yet. Be the first!',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  )
                else
                  for (final c in post.comments) _CommentTile(comment: c),
              ],
            ),
          ),

          // ── Comment input ──────────────────────────────────
          Container(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              8,
              MediaQuery.of(context).viewInsets.bottom + 8,
            ),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(top: BorderSide(color: cs.outline)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentController,
                      decoration: InputDecoration(
                        hintText: 'Write a comment...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: cs.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      textCapitalization: TextCapitalization.sentences,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.send_rounded, color: cs.primary),
                    onPressed: () {
                      final text = _commentController.text.trim();
                      if (text.isEmpty) return;
                      feedService.commentOnPost(post.id, text);
                      _commentController.clear();
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${diff.inDays ~/ 7}w ago';
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  final Comment comment;

  const _CommentTile({required this.comment});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = comment.authorName.isNotEmpty
        ? comment.authorName
        : comment.authorId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(displayName: name, size: AvatarSize.small),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(comment.text, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
