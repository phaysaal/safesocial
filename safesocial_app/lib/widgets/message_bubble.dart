import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/message.dart';
import 'media_preview.dart';

/// Messenger-style chat message bubble.
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final timeFormat = DateFormat.Hm();

    final bgColor = isMine ? cs.primary : cs.surfaceContainerHighest;
    final textColor = isMine ? cs.onPrimary : cs.onSurface;
    final timeColor = isMine
        ? cs.onPrimary.withValues(alpha: 0.7)
        : cs.onSurfaceVariant;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
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

            // Message text
            if (message.content.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  message.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
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
                        ? (isMine ? cs.onPrimary : cs.primary)
                        : timeColor,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
