import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/group_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../widgets/message_bubble.dart';

/// Group chat view — similar to ChatDetailScreen but for group conversations.
class GroupDetailScreen extends StatefulWidget {
  final String dhtKey;

  const GroupDetailScreen({super.key, required this.dhtKey});

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final identityService = context.read<IdentityService>();
    final senderId = identityService.publicKey ?? 'self';

    _messageController.clear();
    await context
        .read<GroupService>()
        .sendGroupMessage(widget.dhtKey, senderId, text);

    // Scroll to bottom after sending.
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
      final identityService = context.read<IdentityService>();
      final senderId = identityService.publicKey ?? 'self';
      await context
          .read<GroupService>()
          .sendGroupMessage(widget.dhtKey, senderId, '[Image]');
    }
  }

  /// Find the display name for a sender within the group members.
  String _senderName(String senderId, GroupService groupService) {
    final group = groupService.getGroup(widget.dhtKey);
    if (group == null) return senderId;
    try {
      final member =
          group.members.firstWhere((m) => m.publicKey == senderId);
      return member.displayName;
    } catch (_) {
      return senderId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final groupService = context.watch<GroupService>();
    final identityService = context.watch<IdentityService>();

    final group = groupService.getGroup(widget.dhtKey);
    final messages = groupService.getGroupMessages(widget.dhtKey);
    final myPublicKey = identityService.publicKey ?? 'self';

    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Group')),
        body: const Center(child: Text('Group not found.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => context.push('/group/${widget.dhtKey}/settings'),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: colorScheme.secondary,
                child: Text(
                  group.name.isNotEmpty ? group.name[0].toUpperCase() : '?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      style: const TextStyle(fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${group.members.length} member${group.members.length == 1 ? '' : 's'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.primary.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      'Send a message to start the group conversation.',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      // Reversed list, so newest is at index 0.
                      final message =
                          messages[messages.length - 1 - index];
                      final isMine =
                          message.senderId == myPublicKey ||
                          message.senderId == 'self';

                      return Column(
                        crossAxisAlignment: isMine
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          // Show sender name for received messages
                          if (!isMine)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 4,
                                top: 6,
                                bottom: 2,
                              ),
                              child: Text(
                                _senderName(
                                    message.senderId, groupService),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: colorScheme.secondary,
                                ),
                              ),
                            ),
                          MessageBubble(
                            message: message,
                            isMine: isMine,
                          ),
                        ],
                      );
                    },
                  ),
          ),

          // Input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: colorScheme.onSurface.withOpacity(0.1),
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _attachMedia,
                    color: colorScheme.onSurface.withOpacity(0.5),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor:
                            colorScheme.onSurface.withOpacity(0.05),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(
                      Icons.send_rounded,
                      color: colorScheme.primary,
                    ),
                    onPressed: _sendMessage,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
