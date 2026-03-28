import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../widgets/avatar.dart';

/// Screen displaying a list of active chat conversations.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final chatService = context.watch<ChatService>();
    final contactService = context.watch<ContactService>();

    final conversations = chatService.conversations;
    final conversationIds = chatService.getConversationIds();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Chats',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () => context.push('/contacts'),
          ),
        ],
      ),
      body: conversationIds.isEmpty
          ? _buildEmptyState(theme)
          : ListView.builder(
              itemCount: conversationIds.length,
              itemBuilder: (context, index) {
                final contactKey = conversationIds[index];
                final messages = conversations[contactKey]!;
                final contact = contactService.getContact(contactKey);
                
                final displayName = contact?.displayName ?? contactKey;
                final lastMessage = messages.isNotEmpty ? messages.last : null;

                return ListTile(
                  leading: UserAvatar(
                    displayName: displayName,
                    size: AvatarSize.medium,
                  ),
                  title: Text(
                    displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    lastMessage?.content ?? 'No messages yet',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: lastMessage != null
                      ? Text(
                          _formatTime(lastMessage.timestamp),
                          style: theme.textTheme.bodySmall,
                        )
                      : null,
                  onTap: () => context.push('/chat/$contactKey'),
                );
              },
            ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          const Text('No conversations yet'),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {}, // Handled by App Router or FAB
            child: const Text('Start a new chat'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (now.difference(dt).inDays == 0) {
      return '${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.day}/${dt.month}';
  }
}
