import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/library_service.dart';
import '../../services/sphere_chat_service.dart';
import '../../services/sphere_service.dart';
import '../../widgets/avatar.dart';

/// Screen displaying a list of active chat conversations.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chatService = context.watch<ChatService>();
    final contactService = context.watch<ContactService>();

    final library = context.watch<LibraryService>();

    final conversations = chatService.conversations;
    // Pinned conversations first; the service keeps the user's pin order.
    final conversationIds =
        library.sortChats(chatService.getConversationIds());

    // Sphere threads sit alongside people. A group conversation is not a
    // separate place in this app — it is addressed to a sphere instead of a
    // person, and belongs in the same list.
    final sphereChat = context.watch<SphereChatService>();
    final spheres = context.watch<SphereService>();
    final sphereThreads = sphereChat.activeThreads
        .where((id) => spheres.sphere(id) != null)
        .toList();

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
      body: conversationIds.isEmpty && sphereThreads.isEmpty
          ? _buildEmptyState(theme)
          : ListView.builder(
              itemCount: sphereThreads.length + conversationIds.length,
              itemBuilder: (context, index) {
                if (index < sphereThreads.length) {
                  return _sphereTile(
                    context,
                    theme,
                    spheres.sphere(sphereThreads[index])!,
                    sphereChat,
                  );
                }
                final contactKey = conversationIds[index - sphereThreads.length];
                final messages = conversations[contactKey]!;
                final contact = contactService.getContact(contactKey);
                
                final displayName = contact?.displayName ?? contactKey;
                final lastMessage = messages.isNotEmpty ? messages.last : null;
                final pinned = library.isPinned(contactKey);

                return ListTile(
                  leading: UserAvatar(
                    displayName: displayName,
                    size: AvatarSize.medium,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (pinned) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.push_pin,
                          size: 13,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ],
                  ),
                  subtitle: chatService.isTyping(contactKey)
                      ? Text(
                          'typing…',
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      : Text(
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
                  onLongPress: () =>
                      _showChatActions(context, library, contactKey, pinned),
                );
              },
            ),
    );
  }

  Widget _sphereTile(
    BuildContext context,
    ThemeData theme,
    Sphere sphere,
    SphereChatService sphereChat,
  ) {
    final cs = theme.colorScheme;
    final last = sphereChat.lastMessageIn(sphere.id);
    final unread = sphereChat.unreadIn(sphere.id);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: cs.primaryContainer,
        child: Icon(Icons.forum_outlined, color: cs.onPrimaryContainer),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              sphere.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${sphere.members.length}',
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
        ],
      ),
      subtitle: Text(
        last?.content ?? 'No messages yet',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: unread > 0
          ? Badge(label: Text('$unread'))
          : (last == null
              ? null
              : Text(_formatTime(last.timestamp),
                  style: theme.textTheme.bodySmall)),
      onTap: () => context.push('/sphere/${sphere.id}/chat'),
    );
  }

  void _showChatActions(
    BuildContext context,
    LibraryService library,
    String contactKey,
    bool pinned,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(pinned ? 'Unpin chat' : 'Pin chat'),
              onTap: () {
                Navigator.pop(sheetContext);
                library.togglePin(contactKey);
              },
            ),
          ],
        ),
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
