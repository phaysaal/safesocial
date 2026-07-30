import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:provider/provider.dart';

import '../models/message.dart';
import '../models/post.dart';
import '../services/feed_service.dart';
import 'emoticon_picker.dart';
import 'media_preview.dart';
import 'voice_note_player.dart';

/// Chat message bubble.
/// Sent: right-aligned, theme primary color.
/// Received: left-aligned, teal color.
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  final void Function(Message)? onDelete;
  final void Function(Message)? onReply;
  final void Function(Message, String emoji)? onReact;

  /// Resolves a quoted message id to the message itself, so a reply can show
  /// what it answers.
  final Message? Function(String id)? resolveMessage;

  /// Our own identity key, for showing which reaction is ours.
  final String? myKey;

  static const List<String> quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.onDelete,
    this.onReply,
    this.onReact,
    this.resolveMessage,
    this.myKey,
  });

  static const _teal = Color(0xFF009688);
  static const _tealDark = Color(0xFF00796B);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final timeFormat = DateFormat.Hm();
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isMine
        ? cs.primary
        : (isDark ? _tealDark : _teal);
    const textColor = Colors.white;
    final timeColor = Colors.white.withValues(alpha: 0.7);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () => _showMessageOptions(context),
            child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isMine ? 18 : 4),
              bottomRight: Radius.circular(isMine ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // The message this one replies to.
              if (message.replyToMessageId != null) ...[
                _QuotedMessage(
                  quoted: resolveMessage?.call(message.replyToMessageId!),
                  isMine: isMine,
                ),
                const SizedBox(height: 6),
              ],

              // Story context, when this message answers one.
              if (message.replyToStoryId != null) ...[
                _StoryReplyContext(
                  storyId: message.replyToStoryId!,
                  isMine: isMine,
                ),
                const SizedBox(height: 6),
              ],

              // Media previews
              if (message.mediaRefs.isNotEmpty) ...[
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: message.mediaRefs
                      .map((ref) => MediaPreview(mediaRef: ref))
                      .toList(),
                ),
                const SizedBox(height: 6),
              ],

              // Voice note
              if (message.audioRef != null) ...[
                VoiceNotePlayer(
                  audioPath: message.audioRef!,
                  isMine: isMine,
                ),
                const SizedBox(height: 6),
              ],

              // Message text (with emoticon support)
              if (message.content.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: buildEmoticonText(
                    message.content,
                    theme.textTheme.bodyMedium?.copyWith(
                      color: textColor,
                      fontSize: 15,
                    ),
                  ),
                ),

              // Timestamp + delivery status
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    timeFormat.format(message.timestamp),
                    style: TextStyle(fontSize: 10, color: timeColor),
                  ),
                  if (isMine) ...[
                    const SizedBox(width: 4),
                    Icon(
                      message.delivered ? Icons.done_all : Icons.done,
                      size: 14,
                      color: message.delivered
                          ? Colors.white
                          : timeColor,
                    ),
                  ],
                ],
              ),
            ],
          ),
            ),
          ),
          _buildReactions(context),
        ],
      ),
    );
  }

  /// Reaction chips under the bubble, grouped by emoji.
  Widget _buildReactions(BuildContext context) {
    if (message.reactions.isEmpty) return const SizedBox.shrink();

    final counts = <String, int>{};
    final mine = <String>{};
    for (final r in message.reactions) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
      if (r.reactorId == myKey) mine.add(r.emoji);
    }

    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        children: counts.entries.map((e) {
          final isMine = mine.contains(e.key);
          return GestureDetector(
            // Tapping your own reaction removes it, as people expect.
            onTap: onReact == null ? null : () => onReact!(message, e.key),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isMine
                    ? cs.primary.withValues(alpha: 0.18)
                    : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: isMine
                    ? Border.all(color: cs.primary.withValues(alpha: 0.5))
                    : null,
              ),
              child: Text(
                e.value > 1 ? '${e.key} ${e.value}' : e.key,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showMessageOptions(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Quick reactions first: this is the common action.
            if (onReact != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: quickReactions
                      .map((emoji) => InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () {
                              Navigator.pop(ctx);
                              onReact!(message, emoji);
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(emoji,
                                  style: const TextStyle(fontSize: 26)),
                            ),
                          ))
                      .toList(),
                ),
              ),
            if (onReply != null)
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(ctx);
                  onReply!(message);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                // Copy is handled by Flutter's text selection
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: cs.error),
              title: Text('Delete', style: TextStyle(color: cs.error)),
              onTap: () {
                Navigator.pop(ctx);
                onDelete?.call(message);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The story a reply refers to.
///
/// Stories expire, and the reply deliberately does not copy the content in, so
/// this says so plainly rather than showing a blank quote or resurrecting
/// something that was meant to disappear.
class _StoryReplyContext extends StatelessWidget {
  final String storyId;
  final bool isMine;

  const _StoryReplyContext({required this.storyId, required this.isMine});

  @override
  Widget build(BuildContext context) {
    final posts = context.watch<FeedService>().allPosts;
    Post? story;
    for (final post in posts) {
      if (post.id == storyId) story = post;
    }

    final expired = story == null ||
        (story.expiresAt != null && story.expiresAt!.isBefore(DateTime.now()));

    final label = expired
        ? 'Replied to a story that has expired'
        : (isMine ? 'You replied to a story' : 'Replied to your story');

    final preview = expired ? null : story.content;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: Colors.white.withValues(alpha: 0.6), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_stories_outlined,
                  size: 12, color: Colors.white70),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (preview != null && preview.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}


/// The message a reply is answering, shown above it.
class _QuotedMessage extends StatelessWidget {
  final Message? quoted;
  final bool isMine;

  const _QuotedMessage({required this.quoted, required this.isMine});

  @override
  Widget build(BuildContext context) {
    // A quoted message can be missing: the other side may have deleted it, or
    // it may predate this conversation on this device.
    final text = quoted == null
        ? 'Original message unavailable'
        : (quoted!.content.isNotEmpty
            ? quoted!.content
            : (quoted!.audioRef != null ? 'Voice note' : 'Photo'));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: Colors.white.withValues(alpha: 0.6), width: 3),
        ),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white.withValues(alpha: quoted == null ? 0.5 : 0.75),
          fontSize: 12,
          fontStyle: quoted == null ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }
}
