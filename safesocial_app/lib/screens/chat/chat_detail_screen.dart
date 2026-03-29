import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/message.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/call_service.dart';
import '../../services/media_service.dart';
import '../../services/veilid_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/emoticon_picker.dart';
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

  // Voice Note
  late AudioRecorder _audioRecorder;
  bool _isRecording = false;
  String? _audioPath;

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
    context.read<ChatService>().setActiveConversation(widget.conversationId);
    _messageController.addListener(() {
      final has = _messageController.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
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

  Future<void> _startRecording() async {
    try {
      if (await Permission.microphone.request().isGranted) {
        final dir = await getApplicationDocumentsDirectory();
        final path = '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        
        const config = RecordConfig();
        await _audioRecorder.start(config, path: path);
        
        setState(() {
          _isRecording = true;
          _audioPath = path;
        });
      }
    } catch (e) {
      debugPrint('[VoiceNote] Error starting recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      final path = await _audioRecorder.stop();
      setState(() {
        _isRecording = false;
      });

      if (path != null) {
        await context.read<ChatService>().sendMessage(
          widget.conversationId,
          '[Voice Note]',
          audioRef: path,
        );
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('[VoiceNote] Error stopping recording: $e');
    }
  }

  void _showEmoticonPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => EmoticonPicker(
        onSelected: (code) {
          // Insert #code# at cursor position
          final text = _messageController.text;
          final selection = _messageController.selection;
          final insert = '#$code#';

          if (selection.isValid) {
            final newText = text.replaceRange(selection.start, selection.end, insert);
            _messageController.text = newText;
            _messageController.selection = TextSelection.collapsed(
              offset: selection.start + insert.length,
            );
          } else {
            _messageController.text = '$text$insert';
          }
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Future<void> _attachMedia() async {
    final path = await context.read<MediaService>().pickAndStoreImage();
    if (path != null && mounted) {
      await context.read<ChatService>().sendMessage(
            widget.conversationId,
            '[Image]',
            mediaRefs: [path],
          );
      _scrollToBottom();
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
                  Builder(builder: (ctx) {
                    final veilidOk = ctx.watch<VeilidService>().isAttached;
                    final relayOk = chatService.isRelayConnected(widget.conversationId);
                    final connected = veilidOk || relayOk;
                    return Text(
                      connected
                          ? (veilidOk ? 'P2P Connected' : 'Relay Connected')
                          : 'Not connected',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: connected ? Colors.green : cs.onSurfaceVariant,
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.call, color: cs.primary),
            onPressed: () {
              final callService = context.read<CallService>();
              callService.startCall(
                widget.conversationId,
                displayName,
                CallType.audio,
              );
              context.push('/call');
            },
          ),
          IconButton(
            icon: Icon(Icons.videocam, color: cs.primary),
            onPressed: () {
              final callService = context.read<CallService>();
              callService.startCall(
                widget.conversationId,
                displayName,
                CallType.video,
              );
              context.push('/call');
            },
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
                        onDelete: (msg) {
                          chatService.deleteMessage(
                            widget.conversationId, msg.id);
                        },
                      );
                    },
                  ),
          ),

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
                  if (!_isRecording) ...[
                    // Emoticon picker
                    IconButton(
                      icon: Icon(Icons.emoji_emotions_outlined,
                          color: cs.primary, size: 26),
                      onPressed: () => _showEmoticonPicker(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                    ),
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
                  ],

                  // Text input or recording state
                  Expanded(
                    child: _isRecording
                        ? _buildRecordingStatus(theme, cs)
                        : Container(
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

                  // Send, like or Mic button
                  if (_isRecording)
                    IconButton(
                      icon: const Icon(Icons.send_rounded, color: Colors.green, size: 24),
                      onPressed: _stopRecording,
                    )
                  else if (_hasText)
                    IconButton(
                      icon: Icon(Icons.send_rounded,
                          color: cs.primary, size: 24),
                      onPressed: _sendMessage,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                    )
                  else
                    GestureDetector(
                      onLongPressStart: (_) => _startRecording(),
                      onLongPressEnd: (_) => _stopRecording(),
                      child: IconButton(
                        icon: Icon(Icons.mic_none_rounded,
                            color: cs.primary, size: 26),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Hold to record voice note')),
                          );
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
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

  Widget _buildRecordingStatus(ThemeData theme, ColorScheme cs) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.fiber_manual_record, color: Colors.red, size: 12),
          const SizedBox(width: 8),
          const Text('Recording...', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          const Spacer(),
          TextButton(
            onPressed: () async {
              await _audioRecorder.stop();
              setState(() => _isRecording = false);
            },
            child: const Text('Cancel'),
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
