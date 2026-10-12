import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/comment_thread.dart';
import '../../models/post.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/library_service.dart';
import '../../widgets/author_name.dart';
import '../../widgets/avatar.dart';
import '../../widgets/reaction_picker.dart';

/// Full post detail screen with the complete comment thread.
///
/// Everything a comment can have done to it lives here: reply, react, edit
/// (with the earlier text kept), delete, and for the post's author or a
/// sphere admin, hide and pin. The thread can run oldest-first, the default,
/// or newest-first; pinned comments lead either way.
class PostDetailScreen extends StatefulWidget {
  final String postId;

  const PostDetailScreen({super.key, required this.postId});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final _commentController = TextEditingController();
  final _inputFocus = FocusNode();

  /// The comment a new one answers, if any.
  Comment? _replyTo;

  /// The comment whose text is being changed, if any.
  Comment? _editing;

  @override
  void dispose() {
    _commentController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _startReply(Comment c) {
    setState(() {
      _editing = null;
      _replyTo = c;
    });
    _inputFocus.requestFocus();
  }

  void _startEdit(Comment c) {
    setState(() {
      _replyTo = null;
      _editing = c;
      _commentController.text = c.text;
    });
    _inputFocus.requestFocus();
  }

  void _clearMode() {
    setState(() {
      _replyTo = null;
      _editing = null;
      _commentController.clear();
    });
  }

  Future<void> _submit(FeedService feed, Post post) async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    final editing = _editing;
    if (editing != null) {
      await feed.editComment(post.id, editing.id, text);
    } else {
      await feed.commentOnPost(post.id, text, replyToId: _replyTo?.id);
    }
    _clearMode();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final feedService = context.watch<FeedService>();
    final library = context.watch<LibraryService>();

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

    final myKey = context.watch<IdentityService>().publicKey;
    final authorName = post.authorId == myKey
        ? 'You'
        : (post.authorName.isNotEmpty ? post.authorName : post.authorId);
    final moderator = feedService.canModerateComments(post);
    final visible = post.visibleComments(myKey, moderator: moderator);
    final newestFirst = library.commentsNewestFirst;
    final threaded = threadComments(visible, newestFirst: newestFirst);
    final myReaction =
        post.reactions.where((r) => r.reactorId == myKey).firstOrNull;
    final canComment = !post.commentsOff || post.authorId == myKey;
    final following = feedService.postNotifies(post);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          post.authorId == myKey ? 'Your post' : "$authorName's post",
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
                    UserAvatar(displayName: authorName, identityKey: post.authorId, size: AvatarSize.medium),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            authorName,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(_timeAgo(post.createdAt),
                              style: theme.textTheme.bodySmall),
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

                // ── Reaction and comment counts ──────────────
                if (post.reactions.isNotEmpty || visible.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                            child: ReactionTally(reactions: post.reactions)),
                        if (visible.isNotEmpty)
                          Text(
                            '${visible.length} comment${visible.length == 1 ? '' : 's'}',
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),

                // ── Action row ───────────────────────────────
                const Divider(),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onLongPress: () => showReactionPicker(
                          context,
                          current: myReaction?.emoji,
                          onPick: (e) => feedService.reactToPost(post.id, e),
                        ),
                        child: _ActionButton(
                          icon: myReaction == null
                              ? Icons.thumb_up_outlined
                              : Icons.emoji_emotions,
                          label: myReaction == null
                              ? 'Like'
                              : ReactionKinds.labelFor(myReaction.emoji),
                          color: myReaction == null
                              ? cs.onSurfaceVariant
                              : cs.primary,
                          onTap: () => feedService.reactToPost(
                              post.id, myReaction?.emoji ?? '👍'),
                        ),
                      ),
                    ),
                    _ActionButton(
                      icon: Icons.chat_bubble_outline,
                      label: 'Comment',
                      color: cs.onSurfaceVariant,
                      onTap: canComment ? () => _inputFocus.requestFocus() : () {},
                    ),
                    _ActionButton(
                      icon: following
                          ? Icons.notifications_active
                          : Icons.notifications_none,
                      label: following ? 'Following' : 'Follow',
                      color: following ? cs.primary : cs.onSurfaceVariant,
                      onTap: () =>
                          feedService.setPostNotifications(post.id, !following),
                    ),
                  ],
                ),
                const Divider(),

                // ── Comments header ──────────────────────────
                Row(
                  children: [
                    Text('Comments',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () =>
                          library.setCommentsNewestFirst(!newestFirst),
                      icon: const Icon(Icons.swap_vert, size: 18),
                      label: Text(newestFirst ? 'Newest first' : 'Oldest first',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
                if (post.commentsOff)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(Icons.comments_disabled_outlined,
                            size: 16, color: cs.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            post.authorId == myKey
                                ? 'You turned comments off. Only you can comment.'
                                : 'The author turned comments off.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        if (post.authorId == myKey)
                          TextButton(
                            onPressed: () =>
                                feedService.setCommentsOff(post.id, false),
                            child: const Text('Turn on'),
                          ),
                      ],
                    ),
                  ),

                // ── Comments list ────────────────────────────
                if (threaded.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        post.commentsOff
                            ? 'No comments.'
                            : 'No comments yet. Be the first!',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                else
                  for (final t in threaded)
                    _CommentTile(
                      post: post,
                      comment: t.comment,
                      isReply: t.isReply,
                      myKey: myKey,
                      moderator: moderator,
                      canReply: canComment,
                      onReply: () => _startReply(t.comment),
                      onEdit: () => _startEdit(t.comment),
                    ),
              ],
            ),
          ),

          // ── Comment input ──────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(top: BorderSide(color: cs.outline)),
            ),
            child: SafeArea(
              top: false,
              child: !canComment
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('Comments are off for this post.',
                          style: theme.textTheme.bodySmall),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_replyTo != null || _editing != null)
                          Row(
                            children: [
                              Icon(
                                _editing != null ? Icons.edit : Icons.reply,
                                size: 16,
                                color: cs.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _editing != null
                                      ? 'Editing your comment'
                                      : 'Replying to ${authorNameFor(context, authorId: _replyTo!.authorId, carried: _replyTo!.authorName)}',
                                  style: theme.textTheme.bodySmall,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: _clearMode,
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _commentController,
                                focusNode: _inputFocus,
                                decoration: InputDecoration(
                                  hintText: _editing != null
                                      ? 'New text'
                                      : _replyTo != null
                                          ? 'Write a reply...'
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
                                textCapitalization: TextCapitalization.sentences,
                                minLines: 1,
                                maxLines: 4,
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              icon: Icon(
                                  _editing != null
                                      ? Icons.check_rounded
                                      : Icons.send_rounded,
                                  color: cs.primary),
                              onPressed: () => _submit(feedService, post),
                            ),
                          ],
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
              Text(label,
                  style: TextStyle(
                      color: color, fontSize: 13, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One comment: name, text, what it has had done to it, and a row of small
/// actions. Long-press for everything the viewer may do.
class _CommentTile extends StatelessWidget {
  final Post post;
  final Comment comment;
  final bool isReply;
  final String? myKey;
  final bool moderator;
  final bool canReply;
  final VoidCallback onReply;
  final VoidCallback onEdit;

  const _CommentTile({
    required this.post,
    required this.comment,
    required this.isReply,
    required this.myKey,
    required this.moderator,
    required this.canReply,
    required this.onReply,
    required this.onEdit,
  });

  bool get _mine => myKey != null && comment.authorId == myKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final feed = context.read<FeedService>();
    final name = authorNameFor(context,
        authorId: comment.authorId, carried: comment.authorName);
    final myReaction =
        comment.reactions.where((r) => r.reactorId == myKey).firstOrNull;

    return Padding(
      padding: EdgeInsets.only(bottom: 10, left: isReply ? 32 : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(displayName: name, identityKey: comment.authorId, size: AvatarSize.small),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onLongPress: () => _showMenu(context, feed),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: comment.hidden
                          ? cs.surfaceContainerLow
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: comment.pinned
                          ? Border.all(color: cs.primary.withValues(alpha: 0.4))
                          : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(name,
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                            ),
                            if (comment.pinned)
                              Icon(Icons.push_pin, size: 14, color: cs.primary),
                            if (comment.hidden) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.visibility_off,
                                  size: 14, color: cs.onSurfaceVariant),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(comment.text,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: comment.hidden ? cs.onSurfaceVariant : null,
                            )),
                        if (comment.hidden)
                          Text(
                            _mine
                                ? 'Hidden from others by the post\'s author or an admin.'
                                : 'Hidden; only you and the writer see it.',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontSize: 10, color: cs.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 6, top: 2),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: [
                      Text(_shortAgo(comment.createdAt),
                          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
                      if (comment.isEdited)
                        InkWell(
                          onTap: () => _showHistory(context),
                          child: Text('Edited',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 11,
                                  decoration: TextDecoration.underline)),
                        ),
                      InkWell(
                        onTap: () => feed.reactToComment(
                            post.id, comment.id, myReaction?.emoji ?? '👍'),
                        onLongPress: () => showReactionPicker(
                          context,
                          current: myReaction?.emoji,
                          onPick: (e) =>
                              feed.reactToComment(post.id, comment.id, e),
                        ),
                        child: Text(
                          myReaction == null
                              ? 'Like'
                              : ReactionKinds.labelFor(myReaction.emoji),
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: myReaction == null ? null : cs.primary),
                        ),
                      ),
                      if (canReply)
                        InkWell(
                          onTap: onReply,
                          child: Text('Reply',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 11, fontWeight: FontWeight.w600)),
                        ),
                      ReactionTally(
                        reactions: comment.reactions,
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showMenu(BuildContext context, FeedService feed) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canReply)
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(ctx);
                  onReply();
                },
              ),
            ListTile(
              leading: const Icon(Icons.add_reaction_outlined),
              title: const Text('React'),
              onTap: () {
                Navigator.pop(ctx);
                showReactionPicker(context,
                    onPick: (e) => feed.reactToComment(post.id, comment.id, e));
              },
            ),
            if (_mine)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(ctx);
                  onEdit();
                },
              ),
            if (moderator)
              ListTile(
                leading: Icon(comment.pinned
                    ? Icons.push_pin_outlined
                    : Icons.push_pin),
                title: Text(comment.pinned ? 'Unpin' : 'Pin to top'),
                onTap: () {
                  Navigator.pop(ctx);
                  feed.setCommentPinned(post.id, comment.id, !comment.pinned);
                },
              ),
            if (moderator && !_mine)
              ListTile(
                leading: Icon(comment.hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                title: Text(comment.hidden ? 'Unhide' : 'Hide'),
                subtitle: comment.hidden
                    ? null
                    : const Text(
                        'Still shown to the writer; everyone else sees nothing',
                        style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  feed.setCommentHidden(post.id, comment.id, !comment.hidden);
                },
              ),
            if (_mine || moderator)
              ListTile(
                leading: Icon(Icons.delete_outline, color: cs.error),
                title: Text('Delete', style: TextStyle(color: cs.error)),
                subtitle: const Text('Removed for everyone in the sphere',
                    style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  feed.deleteComment(post.id, comment.id);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showHistory(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            Text('Edit history',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final earlier in comment.history.reversed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(earlier,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            const Divider(),
            Text(comment.text, style: theme.textTheme.bodyMedium),
            Text('Current', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  static String _shortAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${diff.inDays ~/ 7}w';
  }
}
