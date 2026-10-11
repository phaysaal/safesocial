import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/notification_service.dart';

import '../../models/message.dart';
import '../../models/sphere.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/call_service.dart';
import '../../services/chat_service.dart';
import '../../services/sphere_chat_service.dart';
import '../../services/sphere_service.dart';
import '../../services/library_service.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/message_cards.dart';

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

  /// Members mentioned while composing, by identity key.
  final Set<String> _mentions = {};
  bool _showMentionPicker = false;

  @override
  void initState() {
    super.initState();
    // Opening the thread answers its notifications.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<NotificationService>().clearThread('sphere:${widget.sphereId}');
    });
    _chat = context.read<SphereChatService>();
    // Stops what is on screen being counted as unread.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chat?.setOpenThread(widget.sphereId);
      _chat?.markRead(widget.sphereId);
    });
    _controller.addListener(() {
      final text = _controller.text;
      final show = text.endsWith('@');
      if (show != _showMentionPicker) setState(() => _showMentionPicker = show);
    });
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _editMessage(Message msg) async {
    final controller = TextEditingController(text: msg.content);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(controller: controller, autofocus: true, maxLines: null),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (text == null || !mounted) return;
    await _guard(() => context.read<SphereChatService>().editMessage(widget.sphereId, msg.id, text));
  }

  Future<void> _sendPoll() async {
    final poll = await showCreatePollDialog(context);
    if (poll == null || !mounted) return;
    await _guard(() => context.read<SphereChatService>().sendPoll(
        widget.sphereId, poll.question, poll.options,
        multiple: poll.multiple, anonymous: poll.anonymous));
  }

  Future<void> _chooseDisappearing() async {
    final chat = context.read<SphereChatService>();
    final chosen = await showDisappearingDialog(context, chat.disappearAfter(widget.sphereId));
    if (chosen == null) return;
    await _guard(() => chat.setDisappearing(
        widget.sphereId, chosen == const Duration() ? null : chosen));
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
        mentions: _mentions.toList(),
      );
      _controller.clear();
      _mentions.clear();
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
          if (me != null && sphere.isAdmin(me))
            IconButton(
              icon: const Icon(Icons.timer_outlined),
              tooltip: 'Disappearing messages',
              onPressed: _chooseDisappearing,
            ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Sphere details',
            onPressed: () => context.push('/sphere/${widget.sphereId}'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'blur') {
                context.read<LibraryService>().toggleBlurMedia(widget.sphereId);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'blur',
                child: Text(context.read<LibraryService>().isMediaBlurred(widget.sphereId)
                    ? 'Show media directly'
                    : 'Blur media until tapped'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (chat.pinnedMessageId(widget.sphereId) != null)
            Builder(builder: (context) {
              Message? pinned;
              for (final m in messages) {
                if (m.id == chat.pinnedMessageId(widget.sphereId)) pinned = m;
              }
              if (pinned == null) return const SizedBox.shrink();
              return Material(
                color: cs.surfaceContainerHighest,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.push_pin, size: 18, color: cs.primary),
                  title: Text(
                      pinned.content.isNotEmpty ? pinned.content : ChatService.describeMessage(pinned),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(nameFor(pinned.senderId), style: const TextStyle(fontSize: 11)),
                ),
              );
            }),
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
                            nameFor: nameFor,
                            isStarred: context.watch<LibraryService>().isStarred(message.id),
                            blurMedia: !isMe &&
                                context.watch<LibraryService>().isMediaBlurred(widget.sphereId),
                            isPinned: chat.pinnedMessageId(widget.sphereId) == message.id,
                            readByCount: isMe ? message.readBy.length : null,
                            onReply: (m) => setState(() => _replyingTo = m),
                            onReact: null,
                            onStar: (m) => context
                                .read<LibraryService>()
                                .toggleStar(widget.sphereId, m.id),
                            onEdit: isMe ? _editMessage : null,
                            onDeleteForEveryone: (isMe || (me != null && sphere.isAdmin(me)))
                                ? (m) => _guard(() => chat.deleteForEveryone(widget.sphereId, m.id))
                                : null,
                            onPin: (me != null && sphere.isAdmin(me))
                                ? (m) => _guard(() => chat.pinMessage(widget.sphereId,
                                    chat.pinnedMessageId(widget.sphereId) == m.id ? null : m.id))
                                : null,
                            onVote: (m, choices) =>
                                _guard(() => chat.votePoll(widget.sphereId, m.id, choices)),
                            onJoinCall: (m) async {
                              final calls = context.read<CallService>();
                              final type = m.payload?['type'] == 'video' ? CallType.video : CallType.audio;
                              await calls.joinGroupCall(widget.sphereId,
                                  sphere.members.map((x) => x.identityKey).toList(), type);
                              if (context.mounted) context.push('/call');
                            },
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
                  if (_showMentionPicker)
                    SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          for (final m in sphere.members.where((m) => m.identityKey != me))
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ActionChip(
                                label: Text(nameFor(m.identityKey)),
                                onPressed: () {
                                  final text = _controller.text;
                                  _controller.text =
                                      '${text.substring(0, text.length - 1)}@${nameFor(m.identityKey)} ';
                                  _controller.selection = TextSelection.collapsed(
                                      offset: _controller.text.length);
                                  _mentions.add(m.identityKey);
                                  setState(() => _showMentionPicker = false);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Poll',
                          icon: Icon(Icons.poll_outlined, color: cs.primary),
                          onPressed: _sending ? null : _sendPoll,
                        ),
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
