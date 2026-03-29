import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/group_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../services/call_service.dart';
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

    _scrollToBottom();
  }

  void _scrollToBottom() {
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

  Future<void> _startGroupCall(CallType type) async {
    final groupService = context.read<GroupService>();
    final callService = context.read<CallService>();
    final group = groupService.getGroup(widget.dhtKey);
    if (group == null) return;

    final memberKeys = group.members.map((m) => m.publicKey).toList();
    await callService.startGroupCall(widget.dhtKey, memberKeys, type);
    
    if (mounted) {
      context.push('/call');
    }
  }

  Future<void> _joinActiveCall() async {
    final groupService = context.read<GroupService>();
    final callService = context.read<CallService>();
    final group = groupService.getGroup(widget.dhtKey);
    if (group == null) return;

    final memberKeys = group.members.map((m) => m.publicKey).toList();
    await callService.joinGroupCall(widget.dhtKey, memberKeys, CallType.video);
    
    if (mounted) {
      context.push('/call');
    }
  }

  Future<void> _attachMedia() async {
    final path = await context.read<MediaService>().pickAndStoreImage();
    if (path != null && mounted) {
      final identityService = context.read<IdentityService>();
      final senderId = identityService.publicKey ?? 'self';
      await context
          .read<GroupService>()
          .sendGroupMessage(widget.dhtKey, senderId, '[Image]');
      _scrollToBottom();
    }
  }

  String _senderName(String senderId, GroupService groupService) {
    final group = groupService.getGroup(widget.dhtKey);
    if (group == null) return senderId;
    try {
      final member = group.members.firstWhere((m) => m.publicKey == senderId);
      return member.displayName;
    } catch (_) {
      return senderId;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final groupService = context.watch<GroupService>();
    final identityService = context.watch<IdentityService>();
    final callService = context.watch<CallService>();

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
        titleSpacing: 0,
        title: GestureDetector(
          onTap: () => context.push('/group/${widget.dhtKey}/settings'),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: cs.secondary,
                child: Text(
                  group.name.isNotEmpty ? group.name[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    Text('${group.members.length} members', style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.call, color: cs.primary),
            onPressed: () => _startGroupCall(CallType.audio),
          ),
          IconButton(
            icon: Icon(Icons.videocam, color: cs.primary),
            onPressed: () => _startGroupCall(CallType.video),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => context.push('/group/${widget.dhtKey}/settings'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Active Call Banner
          if (callService.state == CallState.connected && callService.remoteStreams.isNotEmpty)
            GestureDetector(
              onTap: () => context.push('/call'),
              child: Container(
                color: Colors.green.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.video_call, color: Colors.green, size: 20),
                    const SizedBox(width: 12),
                    const Text('Active Group Call', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: _joinActiveCall,
                      child: const Text('Join'),
                    ),
                  ],
                ),
              ),
            ),
          
          Expanded(
            child: messages.isEmpty
                ? Center(child: Text('No messages yet', style: theme.textTheme.bodySmall))
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[messages.length - 1 - index];
                      final isMine = message.senderId == myPublicKey || message.senderId == 'self';

                      return Column(
                        crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [
                          if (!isMine)
                            Padding(
                              padding: const EdgeInsets.only(left: 4, top: 6, bottom: 2),
                              child: Text(
                                _senderName(message.senderId, groupService),
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.secondary),
                              ),
                            ),
                          MessageBubble(message: message, isMine: isMine),
                        ],
                      );
                    },
                  ),
          ),
          _buildInputBar(cs),
        ],
      ),
    );
  }

  Widget _buildInputBar(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outline.withValues(alpha: 0.1))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: _attachMedia, color: cs.primary),
            Expanded(
              child: TextField(
                controller: _messageController,
                decoration: InputDecoration(
                  hintText: 'Group message...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            IconButton(icon: Icon(Icons.send_rounded, color: cs.primary), onPressed: _sendMessage),
          ],
        ),
      ),
    );
  }
}
