import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/message.dart';
import 'media_preview.dart';

/// Chat message bubble.
/// Sent: right-aligned, theme primary color.
/// Received: left-aligned, teal color.
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  final void Function(Message)? onDelete;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.onDelete,
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
      child: GestureDetector(
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
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                // Copy is handled by Flutter's text selection
              },
            ),
            if (isMine)
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
