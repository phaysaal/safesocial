import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/media_provenance.dart';
import '../models/message.dart';
import '../models/post.dart';
import '../services/feed_service.dart';
import 'emoticon_picker.dart';
import 'media_preview.dart';
import 'media_thumb.dart';
import 'message_cards.dart';
import 'voice_note_player.dart';

/// Chat message bubble.
/// Sent: right-aligned, theme primary color.
/// Received: left-aligned, teal color.
///
/// Renders every kind of message: text, media, voice, polls, locations,
/// contact cards, view-once media, tombstones and system lines. The actions
/// offered on long press depend on which callbacks the screen supplies.
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  final void Function(Message)? onDelete;
  final void Function(Message)? onDeleteForEveryone;
  final void Function(Message)? onEdit;
  final void Function(Message)? onReply;
  final void Function(Message)? onForward;
  final void Function(Message)? onStar;
  final void Function(Message)? onPin;
  final void Function(Message, String emoji)? onReact;
  final void Function(Message, List<int> choices)? onVote;
  final void Function(Message)? onStopLiveLocation;
  final void Function(Message)? onAddContact;
  final void Function(Message)? onOpenViewOnce;
  final void Function(Message)? onJoinCall;

  /// Resolves a quoted message id to the message itself, so a reply can show
  /// what it answers.
  final Message? Function(String id)? resolveMessage;

  /// Display names, for mentions, poll voters and read-by.
  final String Function(String key)? nameFor;

  /// Our own identity key, for showing which reaction is ours.
  final String? myKey;

  final bool isStarred;
  final bool isPinned;
  final bool readByPeer;

  /// How many people have read it, for group threads; null hides the count.
  final int? readByCount;

  /// Blur pictures and videos until tapped (a per-chat or per-sphere choice).
  final bool blurMedia;

  static const List<String> quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.onDelete,
    this.onDeleteForEveryone,
    this.onEdit,
    this.onReply,
    this.onForward,
    this.onStar,
    this.onPin,
    this.onReact,
    this.onVote,
    this.onStopLiveLocation,
    this.onAddContact,
    this.onOpenViewOnce,
    this.onJoinCall,
    this.resolveMessage,
    this.nameFor,
    this.myKey,
    this.isStarred = false,
    this.isPinned = false,
    this.readByPeer = false,
    this.readByCount,
    this.blurMedia = false,
  });

  static const _teal = Color(0xFF009688);
  static const _tealDark = Color(0xFF00796B);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    if (message.isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(message.content,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center),
        ),
      );
    }

    // A sticker stands alone, without a bubble.
    if (message.kind == 'sticker' && message.mediaRefs.isNotEmpty && !message.isDeleted) {
      return Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: () => _showMessageOptions(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                MediaThumb(ref: message.mediaRefs.first, width: 140, height: 140,
                    fit: BoxFit.contain, showPlayBadge: false),
                Text(DateFormat.Hm().format(message.timestamp),
                    style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
                _buildReactions(context),
              ],
            ),
          ),
        ),
      );
    }

    final timeFormat = DateFormat.Hm();
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isMine ? cs.primary : (isDark ? _tealDark : _teal);
    const textColor = Colors.white;
    final timeColor = Colors.white.withValues(alpha: 0.7);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () => _showMessageOptions(context),
            child: Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
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
                  if (message.forwarded) ...[
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.forward, size: 12, color: timeColor),
                      const SizedBox(width: 4),
                      Text('Forwarded',
                          style: TextStyle(color: timeColor, fontSize: 11, fontStyle: FontStyle.italic)),
                    ]),
                    const SizedBox(height: 4),
                  ],
                  if (message.replyToMessageId != null) ...[
                    _QuotedMessage(
                      quoted: resolveMessage?.call(message.replyToMessageId!),
                      isMine: isMine,
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (message.replyToStoryId != null) ...[
                    _StoryReplyContext(storyId: message.replyToStoryId!, isMine: isMine),
                    const SizedBox(height: 6),
                  ],
                  ..._body(context, theme, textColor),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPinned) ...[
                        Icon(Icons.push_pin, size: 11, color: timeColor),
                        const SizedBox(width: 3),
                      ],
                      if (isStarred) ...[
                        Icon(Icons.star, size: 11, color: timeColor),
                        const SizedBox(width: 3),
                      ],
                      if (message.expiresAt != null) ...[
                        Icon(Icons.timer_outlined, size: 11, color: timeColor),
                        const SizedBox(width: 3),
                      ],
                      if (message.editedAt != null && !message.isDeleted) ...[
                        Text('edited · ', style: TextStyle(fontSize: 10, color: timeColor)),
                      ],
                      Text(timeFormat.format(message.timestamp),
                          style: TextStyle(fontSize: 10, color: timeColor)),
                      if (isMine && !message.isDeleted) ...[
                        const SizedBox(width: 4),
                        Icon(
                          message.delivered || readByPeer || (readByCount ?? 0) > 0
                              ? Icons.done_all
                              : Icons.done,
                          size: 14,
                          color: readByPeer || (readByCount ?? 0) > 0
                              ? const Color(0xFF8EE3FF)
                              : (message.delivered ? Colors.white : timeColor),
                        ),
                        if (readByCount != null && readByCount! > 0)
                          Text(' $readByCount', style: TextStyle(fontSize: 10, color: timeColor)),
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

  List<Widget> _body(BuildContext context, ThemeData theme, Color textColor) {
    if (message.isDeleted) {
      return [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.block, size: 14, color: Colors.white.withValues(alpha: 0.7)),
          const SizedBox(width: 6),
          Text(isMine ? 'You deleted this message' : 'This message was deleted',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7), fontStyle: FontStyle.italic, fontSize: 14)),
        ]),
      ];
    }
    if (message.isPoll) {
      return [
        PollCard(
          message: message,
          myKey: myKey,
          nameFor: nameFor,
          onVote: onVote == null ? null : (choices) => onVote!(message, choices),
        ),
      ];
    }
    if (message.isLocation) {
      return [
        LocationCard(
          message: message,
          isMine: isMine,
          onStop: onStopLiveLocation == null ? null : () => onStopLiveLocation!(message),
        ),
      ];
    }
    if (message.kind == 'call') {
      final p = message.payload ?? const {};
      return [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(p['type'] == 'video' ? Icons.videocam : Icons.call, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Text(message.content, style: const TextStyle(color: Colors.white)),
        ]),
        if (onJoinCall != null &&
            DateTime.now().difference(message.timestamp) < const Duration(hours: 2)) ...[
          const SizedBox(height: 6),
          ActionChip(
            avatar: const Icon(Icons.call_merge, size: 16),
            label: const Text('Join', style: TextStyle(fontSize: 12)),
            onPressed: () => onJoinCall!(message),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ];
    }
    if (message.isContactCard) {
      return [
        ContactCard(
          message: message,
          onAdd: onAddContact == null ? null : () => onAddContact!(message),
        ),
      ];
    }

    final widgets = <Widget>[];
    if (message.viewOnce) {
      final consumed = message.payload?['consumed'] == true || message.mediaRefs.isEmpty;
      widgets.add(InkWell(
        onTap: consumed || onOpenViewOnce == null ? null : () => onOpenViewOnce!(message),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(consumed ? Icons.visibility_off_outlined : Icons.looks_one_outlined,
                color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(consumed ? (isMine ? 'Opened' : 'Opened, no longer available') : 'View once',
                style: const TextStyle(color: Colors.white)),
          ]),
        ),
      ));
      widgets.add(const SizedBox(height: 6));
    } else if (message.mediaRefs.isNotEmpty) {
      widgets.add(Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < message.mediaRefs.length; i++)
            MediaPreview(
              mediaRef: message.mediaRefs[i],
              provenance: MediaProvenance.at(message.provenance, i),
              blurred: blurMedia,
            ),
        ],
      ));
      widgets.add(const SizedBox(height: 6));
    }
    if (message.audioRef != null) {
      widgets.add(VoiceNotePlayer(audioPath: message.audioRef!, isMine: isMine));
      widgets.add(const SizedBox(height: 6));
    }
    if (message.content.isNotEmpty && !(message.viewOnce && message.content == '[Image]')) {
      widgets.add(Align(
        alignment: Alignment.centerLeft,
        child: message.mentions.isEmpty
            ? buildEmoticonText(
                message.content, theme.textTheme.bodyMedium?.copyWith(color: textColor, fontSize: 15))
            : _mentionText(message.content, textColor),
      ));
    }
    return widgets;
  }

  /// `@Name` runs in bold; everything else as typed.
  Widget _mentionText(String text, Color color) {
    final spans = <TextSpan>[];
    final re = RegExp(r'@[^\s@]+(?: [^\s@]+)?');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(
          text: m.group(0),
          style: const TextStyle(fontWeight: FontWeight.w700, decoration: TextDecoration.underline)));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return RichText(
      text: TextSpan(style: TextStyle(color: color, fontSize: 15), children: spans),
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
            onTap: onReact == null ? null : () => onReact!(message, e.key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isMine ? cs.primary.withValues(alpha: 0.18) : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: isMine ? Border.all(color: cs.primary.withValues(alpha: 0.5)) : null,
              ),
              child: Text(e.value > 1 ? '${e.key} ${e.value}' : e.key,
                  style: const TextStyle(fontSize: 12)),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showMessageOptions(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canEdit = onEdit != null &&
        isMine &&
        !message.isDeleted &&
        message.kind == 'text' &&
        message.content.isNotEmpty &&
        DateTime.now().difference(message.timestamp) < const Duration(minutes: 15);
    final canUnsend = onDeleteForEveryone != null && !message.isDeleted;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onReact != null && !message.isDeleted)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                                child: Text(emoji, style: const TextStyle(fontSize: 26)),
                              ),
                            ))
                        .toList(),
                  ),
                ),
              if (onReply != null && !message.isDeleted)
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: const Text('Reply'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onReply!(message);
                  },
                ),
              if (message.content.isNotEmpty && !message.isDeleted)
                ListTile(
                  leading: const Icon(Icons.copy),
                  title: const Text('Copy'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: message.content));
                  },
                ),
              if (onForward != null && !message.isDeleted && !message.viewOnce && !message.isLocation)
                ListTile(
                  leading: const Icon(Icons.forward),
                  title: const Text('Forward'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onForward!(message);
                  },
                ),
              if (onStar != null && !message.isDeleted)
                ListTile(
                  leading: Icon(isStarred ? Icons.star : Icons.star_border),
                  title: Text(isStarred ? 'Unstar' : 'Star'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onStar!(message);
                  },
                ),
              if (onPin != null && !message.isDeleted)
                ListTile(
                  leading: Icon(isPinned ? Icons.push_pin_outlined : Icons.push_pin),
                  title: Text(isPinned ? 'Unpin' : 'Pin in this chat'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onPin!(message);
                  },
                ),
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onEdit!(message);
                  },
                ),
              if (onDelete != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Delete for me'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onDelete?.call(message);
                  },
                ),
              if (canUnsend)
                ListTile(
                  leading: Icon(Icons.delete_forever_outlined, color: cs.error),
                  title: Text(isMine ? 'Delete for everyone' : 'Remove for everyone',
                      style: TextStyle(color: cs.error)),
                  onTap: () {
                    Navigator.pop(ctx);
                    onDeleteForEveryone!(message);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The story a reply refers to.
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
        border: Border(left: BorderSide(color: Colors.white.withValues(alpha: 0.6), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_stories_outlined, size: 12, color: Colors.white70),
              const SizedBox(width: 5),
              Flexible(
                child: Text(label,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (preview != null && preview.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 11)),
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
    final q = quoted;
    final text = q == null
        ? 'Original message unavailable'
        : (q.isDeleted
            ? 'Deleted message'
            : (q.content.isNotEmpty
                ? q.content
                : (q.audioRef != null ? 'Voice note' : (q.isPoll ? 'Poll' : 'Photo'))));

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: Colors.white.withValues(alpha: 0.6), width: 3)),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white.withValues(alpha: q == null ? 0.5 : 0.75),
          fontSize: 12,
          fontStyle: q == null ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );
  }
}
