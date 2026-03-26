import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/message.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../services/veilid_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/message_bubble.dart';

/// Messenger-style chat conversation detail view.
class ChatDetailScreen extends StatefulWidget {
  final String conversationId;

  const ChatDetailScreen({super.key, required this.conversationId});

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    context.read<ChatService>().setActiveConversation(widget.conversationId);
    _messageController.addListener(() {
      final has = _messageController.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    await context
        .read<ChatService>()
        .sendMessage(widget.conversationId, text);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _attachMedia() async {
    final path = await context.read<MediaService>().pickAndStoreImage();
    if (path != null && mounted) {
      await context.read<ChatService>().sendMessage(
            widget.conversationId,
            '[Image]',
            mediaRefs: [path],
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final chatService = context.watch<ChatService>();
    final contactService = context.watch<ContactService>();
    final identityService = context.watch<IdentityService>();

    final messages =
        chatService.conversations[widget.conversationId] ?? <Message>[];
    final contact = contactService.getContact(widget.conversationId);
    final displayName = contact?.displayName ?? widget.conversationId;
    final myPublicKey = identityService.publicKey ?? 'self';

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Stack(
              children: [
                UserAvatar(
                  displayName: displayName,
                  size: AvatarSize.small,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: cs.secondary,
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.surface, width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    context.watch<VeilidService>().isAttached
                        ? 'P2P Connected'
                        : 'Local mode (not connected)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: context.watch<VeilidService>().isAttached
                          ? Colors.green
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.call, color: cs.primary),
            onPressed: () {},
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant),
            onSelected: (value) {
              if (value == 'delete') {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete Contact'),
                    content: Text('Remove $displayName and all messages?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () {
                          context.read<ContactService>().removeContact(widget.conversationId);
                          context.read<ChatService>().removeConversation(widget.conversationId);
                          Navigator.pop(ctx);
                          context.pop();
                        },
                        child: Text('Delete', style: TextStyle(color: cs.error)),
                      ),
                    ],
                  ),
                );
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'delete', child: Text('Delete contact')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Messages ────────────────────────────────────
          Expanded(
            child: messages.isEmpty
                ? _buildEmptyChat(theme, displayName)
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message =
                          messages[messages.length - 1 - index];
                      final isMine = message.senderId == myPublicKey ||
                          message.senderId == 'self';

                      return MessageBubble(
                        message: message,
                        isMine: isMine,
                      );
                    },
                  ),
          ),

          // ── Typing indicator placeholder ────────────────
          // Padding(
          //   padding: const EdgeInsets.only(left: 16, bottom: 4),
          //   child: _TypingIndicator(),
          // ),

          // ── Input bar ───────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                top: BorderSide(color: cs.outline.withValues(alpha: 0.3)),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Attachment buttons
                  IconButton(
                    icon: Icon(Icons.add_circle,
                        color: cs.primary, size: 28),
                    onPressed: _attachMedia,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.camera_alt_outlined,
                        color: cs.primary, size: 24),
                    onPressed: _attachMedia,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),

                  // Text input
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: TextField(
                        controller: _messageController,
                        decoration: const InputDecoration(
                          hintText: 'Aa',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          isDense: true,
                        ),
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                        maxLines: 4,
                        minLines: 1,
                      ),
                    ),
                  ),

                  // Send or like button
                  _hasText
                      ? IconButton(
                          icon: Icon(Icons.send_rounded,
                              color: cs.primary, size: 24),
                          onPressed: _sendMessage,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        )
                      : IconButton(
                          icon: Icon(Icons.thumb_up,
                              color: cs.primary, size: 24),
                          onPressed: () {
                            context.read<ChatService>().sendMessage(
                                  widget.conversationId,
                                  '\u{1F44D}',
                                );
                          },
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 36,
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyChat(ThemeData theme, String name) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(displayName: name, size: AvatarSize.large),
            const SizedBox(height: 16),
            Text(
              name,
              style: theme.textTheme.headlineMedium?.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 8),
            Text(
              'Say hi! Messages are end-to-end encrypted.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
