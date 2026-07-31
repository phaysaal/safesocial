import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/message.dart';
import '../../models/sphere.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/sphere_chat_service.dart';
import '../../services/sphere_service.dart';
import '../../widgets/message_bubble.dart';

/// The conversation belonging to one sphere.
///
/// Deliberately the same bubbles, replies and reactions as a direct message —
/// a group thread is not a different kind of thing here, only a different
/// recipient.
class SphereChatScreen extends StatefulWidget {
  final String sphereId;
  const SphereChatScreen({super.key, required this.sphereId});

  @override
  State<SphereChatScreen> createState() => _SphereChatScreenState();
}

class _SphereChatScreenState extends State<SphereChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  Message? _replyingTo;
  bool _sending = false;
  SphereChatService? _chat;

  @override
  void initState() {
    super.initState();
    _chat = context.read<SphereChatService>();
    // Stops what is on screen being counted as unread.
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _chat?.setOpenThread(widget.sphereId));
  }

  @override
  void dispose() {
    _chat?.setOpenThread(null);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    final chat = context.read<SphereChatService>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await chat.sendMessage(
        widget.sphereId,
        text,
        replyToMessageId: _replyingTo?.id,
      );
      _controller.clear();
      if (mounted) setState(() => _replyingTo = null);
    } catch (e) {
      // Sealing can fail while waiting for an epoch key. Saying so beats
      // leaving a message sitting there looking sent.
      messenger.showSnackBar(SnackBar(content: Text('Could not send: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final chat = context.watch<SphereChatService>();
    final sphere = context.watch<SphereService>().sphere(widget.sphereId);
    final me = context.watch<IdentityService>().publicKey;
    final contacts = context.watch<ContactService>();

    if (sphere == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This sphere is no longer available.')),
      );
    }

    String nameFor(String key) {
      if (key == me) return 'You';
      for (final contact in contacts.contacts) {
        if (contact.publicKey == key) return contact.displayName;
      }
      return '${key.substring(0, 8)}…';
    }

    final messages = chat.messagesIn(widget.sphereId);
    final readOnly = sphere.kind == SphereKind.broadcast &&
        (me == null || !sphere.isAdmin(me));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(sphere.name),
            Text(
              '${sphere.members.length} members',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Sphere details',
            onPressed: () => context.push('/sphere/${widget.sphereId}'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'No messages yet. Everything here is visible only to '
                        'the ${sphere.members.length} people in this sphere.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[messages.length - 1 - index];
                      final isMe = message.senderId == me;
                      return Column(
                        crossAxisAlignment: isMe
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          // Who said it matters in a group in a way it never
                          // does in a one-to-one thread.
                          if (!isMe)
                            Padding(
                              padding:
                                  const EdgeInsets.only(left: 12, bottom: 2),
                              child: Text(
                                nameFor(message.senderId),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.primary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          MessageBubble(
                            message: message,
                            isMine: isMe,
                            myKey: me,
                            onReply: (m) => setState(() => _replyingTo = m),
                            resolveMessage: (id) {
                              for (final m in messages) {
                                if (m.id == id) return m;
                              }
                              return null;
                            },
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (readOnly)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: cs.surfaceContainerHighest,
              child: Text(
                'Only admins post in this sphere.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            SafeArea(
              child: Column(
                children: [
                  if (_replyingTo != null)
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      color: cs.surfaceContainerHighest,
                      child: Row(
                        children: [
                          Icon(Icons.reply, size: 16, color: cs.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Replying to ${nameFor(_replyingTo!.senderId)}: '
                              '${_replyingTo!.content}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () =>
                                setState(() => _replyingTo = null),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            textCapitalization: TextCapitalization.sentences,
                            minLines: 1,
                            maxLines: 4,
                            decoration: InputDecoration(
                              hintText: 'Message ${sphere.name}',
                              filled: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _sending ? null : _send,
                          icon: _sending
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
