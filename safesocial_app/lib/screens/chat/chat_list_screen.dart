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
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  /// Archived chats stay out of the way until asked for.
  bool _showArchived = false;

  /// all · unread · people · spheres
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chatService = context.watch<ChatService>();
    final contactService = context.watch<ContactService>();

    final library = context.watch<LibraryService>();

    // Pinned conversations first; the service keeps the user's pin order.
    final conversationIds =
        library.sortChats(chatService.getConversationIds()
            .where((k) => _showArchived || (!library.isChatArchived(k) && !library.isChatIgnored(k)))
            .where((k) => _filter != 'spheres')
            .where((k) => _filter != 'unread' || chatService.unreadCount(k) > 0)
            .toList());
    final archivedCount = library.archivedChatCount + library.ignoredChatCount;

    // Sphere threads sit alongside people. A group conversation is not a
    // separate place in this app — it is addressed to a sphere instead of a
    // person, and belongs in the same list.
    final sphereChat = context.watch<SphereChatService>();
    final spheres = context.watch<SphereService>();
    final sphereThreads = sphereChat.activeThreads
        .where((id) => spheres.sphere(id) != null)
        .where((id) => _filter != 'people')
        .where((id) => _filter != 'unread' || sphereChat.unreadIn(id) > 0)
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
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final f in const [('all', 'All'), ('unread', 'Unread'), ('people', 'People'), ('spheres', 'Spheres')])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(f.$2),
                      selected: _filter == f.$1,
                      onSelected: (_) => setState(() => _filter = f.$1),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(Icons.star_outline, size: 16),
                    label: const Text('Starred'),
                    onPressed: () => context.push('/starred'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(Icons.call_outlined, size: 16),
                    label: const Text('Calls'),
                    onPressed: () => context.push('/calls'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _list(context, theme, conversationIds, sphereThreads, archivedCount,
              chatService, contactService, library, spheres, sphereChat)),
        ],
      ),
    );
  }

  Widget _list(
    BuildContext context,
    ThemeData theme,
    List<String> conversationIds,
    List<String> sphereThreads,
    int archivedCount,
    ChatService chatService,
    ContactService contactService,
    LibraryService library,
    SphereService spheres,
    SphereChatService sphereChat,
  ) {
    final conversations = chatService.conversations;
    return conversationIds.isEmpty && sphereThreads.isEmpty
          ? _buildEmptyState(theme)
          : ListView.builder(
              itemCount: sphereThreads.length +
                  conversationIds.length +
                  (archivedCount > 0 ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == sphereThreads.length + conversationIds.length) {
                  return ListTile(
                    leading: Icon(Icons.archive_outlined,
                        color: theme.colorScheme.onSurfaceVariant),
                    title: Text(_showArchived
                        ? 'Hide archived chats'
                        : 'Archived ($archivedCount)'),
                    onTap: () => setState(() => _showArchived = !_showArchived),
                  );
                }
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
                
                final displayName = library.chatNickname(contactKey) ?? contact?.displayName ?? contactKey;
                final lastMessage = messages.isNotEmpty ? messages.last : null;
                final pinned = library.isPinned(contactKey);

                final unread = chatService.unreadCount(contactKey) > 0;
                return ListTile(
                  leading: UserAvatar(
                    displayName: displayName,
                    imageRef: contact?.avatarRef,
                    size: AvatarSize.medium,
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: unread ? FontWeight.w800 : FontWeight.w600),
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
                          lastMessage == null
                              ? 'No messages yet'
                              : (lastMessage.content.isNotEmpty ? lastMessage.content : ChatService.describeMessage(lastMessage)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                            color: unread ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (lastMessage != null)
                        Text(_formatTime(lastMessage.timestamp), style: theme.textTheme.bodySmall),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (library.isChatLocked(contactKey))
                            Icon(Icons.lock_outline, size: 14, color: theme.colorScheme.outline),
                          if (chatService.unreadCount(contactKey) > 0) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text('${chatService.unreadCount(contactKey)}',
                                  style: TextStyle(
                                      color: theme.colorScheme.onPrimary, fontSize: 11)),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                  onTap: () => context.push('/chat/$contactKey'),
                  onLongPress: () =>
                      _showChatActions(context, library, contactKey, pinned),
                );
              },
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
            ListTile(
              leading: Icon(library.isChatIgnored(contactKey)
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              title: Text(library.isChatIgnored(contactKey) ? 'Stop ignoring' : 'Ignore'),
              subtitle: const Text('No notifications; they are not told you read or type'),
              onTap: () {
                Navigator.pop(sheetContext);
                library.toggleIgnoreChat(contactKey);
              },
            ),
            ListTile(
              leading: Icon(library.isChatArchived(contactKey)
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined),
              title: Text(library.isChatArchived(contactKey)
                  ? 'Unarchive chat'
                  : 'Archive chat'),
              subtitle: const Text('Out of the list; nothing is deleted'),
              onTap: () {
                Navigator.pop(sheetContext);
                library.toggleArchiveChat(contactKey);
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
