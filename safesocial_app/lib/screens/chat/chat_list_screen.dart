import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../widgets/avatar.dart';

/// Messenger-style chat list screen.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final chatService = context.watch<ChatService>();
    final contactService = context.watch<ContactService>();
    final conversationIds = chatService.getConversationIds();

    // Filter by search
    final filtered = _searchQuery.isEmpty
        ? conversationIds
        : conversationIds.where((id) {
            final contact = contactService.getContact(id);
            final name = contact?.displayName ?? id;
            return name.toLowerCase().contains(_searchQuery.toLowerCase());
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Chats',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            fontSize: 24,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_square),
            onPressed: () => context.push('/contacts'),
            tooltip: 'New message',
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Search bar ──────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Search',
                prefixIcon: Icon(Icons.search, color: cs.onSurfaceVariant),
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),

          // ── Active contacts row ─────────────────────────
          _ActiveContactsRow(),

          // ── Conversation list ───────────────────────────
          Expanded(
            child: filtered.isEmpty
                ? _buildEmptyState(theme, conversationIds.isEmpty)
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final recipientId = filtered[index];
                      final messages =
                          chatService.conversations[recipientId] ?? [];
                      final lastMessage =
                          messages.isNotEmpty ? messages.last : null;
                      final contact =
                          contactService.getContact(recipientId);
                      final displayName =
                          contact?.displayName ?? _truncateKey(recipientId);

                      return _ConversationTile(
                        displayName: displayName,
                        lastMessageText: lastMessage?.content,
                        timestamp: lastMessage?.timestamp,
                        onTap: () => context.push('/chat/$recipientId'),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/contacts/add'),
        tooltip: 'New conversation',
        child: const Icon(Icons.chat_outlined),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, bool noConversations) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              noConversations
                  ? Icons.chat_bubble_outline
                  : Icons.search_off,
              size: 64,
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              noConversations ? 'No conversations yet' : 'No results',
              style: theme.textTheme.headlineMedium?.copyWith(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              noConversations
                  ? 'Add a contact to start chatting.'
                  : 'Try a different search.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _truncateKey(String key) {
    if (key.length <= 12) return key;
    return '${key.substring(0, 6)}...${key.substring(key.length - 4)}';
  }
}

// ─── Active contacts row (Messenger style) ───────────────────────────────────

class _ActiveContactsRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final contacts = context.watch<ContactService>().contacts;
    final active = contacts.where((c) => !c.blocked).toList();

    if (active.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 90,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: active.length,
        itemBuilder: (context, index) {
          final c = active[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: GestureDetector(
              onTap: () => context.push('/chat/${c.publicKey}'),
              child: Column(
                children: [
                  Stack(
                    children: [
                      UserAvatar(
                        displayName: c.displayName,
                        size: AvatarSize.medium,
                      ),
                      // Online indicator
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: cs.secondary,
                            shape: BoxShape.circle,
                            border: Border.all(color: cs.surface, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: 56,
                    child: Text(
                      c.displayName.split(' ').first,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Conversation tile ───────────────────────────────────────────────────────

class _ConversationTile extends StatelessWidget {
  final String displayName;
  final String? lastMessageText;
  final DateTime? timestamp;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.displayName,
    this.lastMessageText,
    this.timestamp,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Avatar with online dot
            Stack(
              children: [
                UserAvatar(
                  displayName: displayName,
                  size: AvatarSize.medium,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: cs.secondary,
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.surface, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            // Name + last message
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (lastMessageText != null) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            lastMessageText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        if (timestamp != null) ...[
                          Text(' · ', style: theme.textTheme.bodySmall),
                          Text(
                            _timeAgo(timestamp!),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${dt.month}/${dt.day}';
  }
}
