import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/post.dart';
import '../services/contact_service.dart';
import '../services/feed_service.dart';
import 'avatar.dart';

/// Instagram / Facebook style post card.
class PostCard extends StatefulWidget {
  final Post post;

  const PostCard({super.key, required this.post});

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  bool _showHeart = false;

  void _onDoubleTap() {
    if (!widget.post.isLikedBySelf) {
      context.read<FeedService>().toggleLike(widget.post.id);
    }
    setState(() => _showHeart = true);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showHeart = false);
    });
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${diff.inDays ~/ 7}w';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final post = widget.post;
    final authorName =
        post.authorId == 'self' ? 'You' : (post.authorName.isNotEmpty ? post.authorName : post.authorId);

    return Container(
      color: cs.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Author header ──────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                UserAvatar(displayName: authorName, size: AvatarSize.medium),
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
                      Row(
                        children: [
                          Text(
                            _timeAgo(post.createdAt),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.public, size: 12, color: cs.onSurfaceVariant),
                          if (post.editedAt != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              'Edited',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (post.audience == PostAudience.closeFriends)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Close Friends',
                        style: TextStyle(fontSize: 10, color: Colors.green)),
                  ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, color: cs.onSurfaceVariant),
                  onSelected: (value) => _handlePostMenu(context, value, post),
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(value: 'hide', child: Text('Hide post')),
                    if (post.authorId != 'self') ...[
                      const PopupMenuItem(value: 'mute', child: Text('Mute this person')),
                      const PopupMenuItem(value: 'unfollow', child: Text('Unfollow')),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // ── Content text ───────────────────────────────────
          if (post.content.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(post.content, style: theme.textTheme.bodyMedium),
            ),

          // ── Media ──────────────────────────────────────────
          if (post.mediaRefs.isNotEmpty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onDoubleTap: _onDoubleTap,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _buildMediaSection(post.mediaRefs),
                  if (_showHeart)
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.5, end: 1.0),
                      duration: const Duration(milliseconds: 300),
                      builder: (context, scale, child) {
                        return Transform.scale(scale: scale, child: child);
                      },
                      child: Icon(
                        Icons.favorite,
                        color: Colors.white.withValues(alpha: 0.9),
                        size: 80,
                      ),
                    ),
                ],
              ),
            ),
          ],

          // ── Like / reaction counts ─────────────────────────
          if (post.likes.isNotEmpty || post.reactions.isNotEmpty || post.comments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  if (post.likes.isNotEmpty || post.reactions.isNotEmpty) ...[
                    // Show emoji summary
                    if (post.reactions.isNotEmpty) ...[
                      for (final emoji in _uniqueEmojis(post))
                        Text(emoji, style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 4),
                    ] else ...[
                      Icon(Icons.thumb_up, size: 16, color: cs.primary),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      '${post.likes.length + post.reactions.length}',
                      style: theme.textTheme.bodySmall,
                    ),
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

          // ── Divider ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(color: cs.outline, height: 20),
          ),

          // ── Like / Comment / Share action row ──────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                // Like button — tap to like, long-press for emoji picker
                Expanded(
                  child: GestureDetector(
                    onLongPress: () => _showEmojiPicker(context, post),
                    child: _ActionButton(
                      icon: _selfReactionIcon(post),
                      label: _selfReactionLabel(post),
                      color: (post.isLikedBySelf || _hasSelfReaction(post))
                          ? cs.primary
                          : cs.onSurfaceVariant,
                      onTap: () => context.read<FeedService>().toggleLike(post.id),
                    ),
                  ),
                ),
                _ActionButton(
                  icon: Icons.chat_bubble_outline,
                  label: 'Comment',
                  color: cs.onSurfaceVariant,
                  onTap: () => _showCommentSheet(context, post),
                ),
                _ActionButton(
                  icon: Icons.share_outlined,
                  label: 'Share',
                  color: cs.onSurfaceVariant,
                  onTap: () {},
                ),
              ],
            ),
          ),

          // ── Comments preview ───────────────────────────────
          if (post.comments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in post.comments.reversed.take(2))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: RichText(
                        text: TextSpan(
                          style: theme.textTheme.bodyMedium,
                          children: [
                            TextSpan(
                              text: '${c.authorName.isNotEmpty ? c.authorName : c.authorId} ',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            TextSpan(text: c.text),
                          ],
                        ),
                      ),
                    ),
                  if (post.comments.length > 2)
                    GestureDetector(
                      onTap: () => _showCommentSheet(context, post),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'View all ${post.comments.length} comments',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                ],
              ),
            ),

          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildMediaSection(List<String> refs) {
    if (refs.length == 1) {
      return _mediaImage(refs[0], width: double.infinity, height: 350);
    }
    // Grid for multiple images
    return SizedBox(
      height: 300,
      child: Row(
        children: [
          Expanded(child: _mediaImage(refs[0], height: 300)),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _mediaImage(refs.length > 1 ? refs[1] : refs[0])),
                if (refs.length > 2) ...[
                  const SizedBox(height: 2),
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _mediaImage(refs[2]),
                        if (refs.length > 3)
                          Container(
                            color: Colors.black45,
                            alignment: Alignment.center,
                            child: Text(
                              '+${refs.length - 3}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaImage(String ref, {double? width, double? height}) {
    final file = File(ref);
    if (file.existsSync()) {
      return Image.file(
        file,
        width: width,
        height: height,
        fit: BoxFit.cover,
      );
    }
    return Container(
      width: width,
      height: height,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.image, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  void _handlePostMenu(BuildContext context, String action, Post post) {
    switch (action) {
      case 'hide':
        context.read<FeedService>().hidePost(post.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Post hidden'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => context.read<FeedService>().unhidePost(post.id),
            ),
          ),
        );
      case 'mute':
        context.read<ContactService>().toggleMute(post.authorId);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Contact muted')),
        );
      case 'unfollow':
        context.read<ContactService>().toggleFollow(post.authorId);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unfollowed')),
        );
    }
  }

  // ── Emoji / reaction helpers ──────────────────────────────

  static const _emojis = ['👍', '❤️', '😂', '🔥', '👏', '💯'];

  List<String> _uniqueEmojis(Post post) {
    final seen = <String>{};
    for (final r in post.reactions) {
      seen.add(r.emoji);
      if (seen.length >= 3) break;
    }
    return seen.toList();
  }

  bool _hasSelfReaction(Post post) =>
      post.reactions.any((r) => r.reactorId == 'self');

  IconData _selfReactionIcon(Post post) {
    if (post.isLikedBySelf) return Icons.thumb_up;
    if (_hasSelfReaction(post)) return Icons.emoji_emotions;
    return Icons.thumb_up_outlined;
  }

  String _selfReactionLabel(Post post) {
    final selfReaction = post.reactions
        .where((r) => r.reactorId == 'self')
        .toList();
    if (selfReaction.isNotEmpty) return selfReaction.first.emoji;
    return 'Like';
  }

  void _showEmojiPicker(BuildContext context, Post post) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: _emojis
                .map(
                  (emoji) => InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () {
                      context.read<FeedService>().reactToPost(post.id, emoji);
                      Navigator.pop(ctx);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(emoji, style: const TextStyle(fontSize: 28)),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }

  // ── Comment sheet with reply threading ──────────────────

  void _showCommentSheet(BuildContext context, Post post) {
    final controller = TextEditingController();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    String? replyToId;
    String? replyToName;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            // Build threaded comment list: top-level first, then replies indented
            final topLevel =
                post.comments.where((c) => c.replyToId == null).toList();

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              builder: (ctx, scrollController) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text('Comments',
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontSize: 16)),
                    const Divider(),
                    Expanded(
                      child: post.comments.isEmpty
                          ? Center(
                              child: Text('No comments yet. Be the first!',
                                  style: theme.textTheme.bodySmall),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: topLevel.length,
                              itemBuilder: (ctx, i) {
                                final c = topLevel[i];
                                final replies = post.comments
                                    .where((r) => r.replyToId == c.id)
                                    .toList();
                                return _CommentThread(
                                  comment: c,
                                  replies: replies,
                                  onReply: (comment) {
                                    setSheetState(() {
                                      replyToId = comment.id;
                                      replyToName = comment.authorName
                                              .isNotEmpty
                                          ? comment.authorName
                                          : comment.authorId;
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                    // Reply indicator
                    if (replyToId != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        color: cs.surfaceContainerHighest,
                        child: Row(
                          children: [
                            Text('Replying to $replyToName',
                                style: theme.textTheme.bodySmall),
                            const Spacer(),
                            GestureDetector(
                              onTap: () => setSheetState(() {
                                replyToId = null;
                                replyToName = null;
                              }),
                              child: Icon(Icons.close,
                                  size: 16, color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    // Input
                    Container(
                      padding: EdgeInsets.fromLTRB(
                          16, 8, 8, MediaQuery.of(ctx).viewInsets.bottom + 8),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        border: Border(top: BorderSide(color: cs.outline)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              decoration: InputDecoration(
                                hintText: replyToId != null
                                    ? 'Reply to $replyToName...'
                                    : 'Write a comment...',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: cs.surfaceContainerHighest,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                              ),
                              textCapitalization:
                                  TextCapitalization.sentences,
                              autofocus: true,
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon:
                                Icon(Icons.send_rounded, color: cs.primary),
                            onPressed: () {
                              final text = controller.text.trim();
                              if (text.isEmpty) return;
                              context.read<FeedService>().commentOnPost(
                                    post.id,
                                    text,
                                    replyToId: replyToId,
                                  );
                              controller.clear();
                              setSheetState(() {
                                replyToId = null;
                                replyToName = null;
                              });
                              Navigator.pop(ctx);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

// ─── Comment thread widget ───────────────────────────────────────────────────

class _CommentThread extends StatelessWidget {
  final Comment comment;
  final List<Comment> replies;
  final void Function(Comment) onReply;

  const _CommentThread({
    required this.comment,
    required this.replies,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name =
        comment.authorName.isNotEmpty ? comment.authorName : comment.authorId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top-level comment
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserAvatar(displayName: name, size: AvatarSize.small),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(comment.text,
                              style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                    // Reply button
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 4),
                      child: GestureDetector(
                        onTap: () => onReply(comment),
                        child: Text('Reply',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            )),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Threaded replies (indented)
          for (final reply in replies)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UserAvatar(
                    displayName: reply.authorName.isNotEmpty
                        ? reply.authorName
                        : reply.authorId,
                    size: AvatarSize.small,
                  ),
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
                            reply.authorName.isNotEmpty
                                ? reply.authorName
                                : reply.authorId,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(reply.text,
                              style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Action button ───────────────────────────────────────────────────────────

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
    return InkWell(
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
    );
  }
}
