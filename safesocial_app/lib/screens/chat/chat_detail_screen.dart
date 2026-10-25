import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/notification_service.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../crypto/safety_number.dart';
import '../../crypto/session_manager.dart';
import '../../models/contact.dart';
import '../../models/message.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../widgets/writing_guide_sheet.dart';
import '../../services/identity_service.dart';
import '../../services/call_service.dart';
import '../../services/app_lock_service.dart';
import '../../services/library_service.dart';
import '../../services/media_service.dart';
import '../../services/sphere_chat_service.dart';
import '../../services/sphere_service.dart';
import '../../services/video_transcoder.dart';
import '../../services/file_bridge.dart';
import '../../widgets/avatar.dart';
import '../../widgets/chat_themes.dart';
import '../../widgets/emoticon_picker.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/message_cards.dart';
import '../../widgets/media_thumb.dart';
import '../../services/send_alarms.dart';
import '../../widgets/protected_sheet.dart';

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
  late final RecorderController _recorderController;
  bool _isRecording = false;

  /// Message being replied to, shown above the composer until sent or cleared.
  Message? _replyingTo;

  /// Captured in initState: dispose() cannot safely read from context.
  ChatService? _chatService;

  /// A locked chat shows nothing until the device confirms it is its owner.
  bool _unlocked = true;

  @override
  void initState() {
    super.initState();
    // Opening the thread answers its notifications.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<NotificationService>().clearThread('chat:${widget.conversationId}');
    });
    _recorderController = RecorderController()
      ..androidEncoder = AndroidEncoder.aac
      ..androidOutputFormat = AndroidOutputFormat.mpeg4
      ..iosEncoder = IosEncoder.kAudioFormatMPEG4AAC
      ..sampleRate = 44100;

    _chatService = context.read<ChatService>();
    _chatService!.setActiveConversation(widget.conversationId);
    if (context.read<LibraryService>().isChatLocked(widget.conversationId)) {
      _unlocked = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _unlockChat());
    }
    _messageController.addListener(() {
      final has = _messageController.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);

      final chat = context.read<ChatService>();
      if (has) {
        // Throttled inside the service, so this is safe per keystroke.
        chat.notifyTyping(widget.conversationId);
      } else {
        chat.notifyTyping(widget.conversationId, stopped: true);
      }
    });
  }

  /// Let someone repair a conversation that has stopped working.
  ///
  /// The app now notices divergence on its own, but only once messages have
  /// started failing, and only for the side receiving them. Someone whose
  /// messages are vanishing into silence needs a way to act without waiting to
  /// be rescued — and it is the natural thing to reach for when a chat has
  /// gone quiet in a way that feels wrong.
  Future<void> _confirmSessionReset(
      BuildContext context, String displayName) async {
    final chat = context.read<ChatService>();
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Re-establish this session?'),
        content: Text(
          'Use this if messages with $displayName have stopped getting '
          'through. Both devices start a fresh encrypted session.\n\n'
          'Anything already sent but not yet delivered will be lost, and your '
          'existing conversation history stays exactly as it is.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Re-establish')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await chat.restartSessionManually(widget.conversationId);
      messenger.showSnackBar(const SnackBar(
        content: Text('Session re-established. Try sending again.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  void dispose() {
    // Otherwise the indicator lingers on their side until it times out.
    _chatService?.notifyTyping(widget.conversationId, stopped: true);
    _recorderController.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final replyId = _replyingTo?.id;
    _messageController.clear();
    setState(() => _replyingTo = null);

    await _send(() => context.read<ChatService>().sendMessage(
          widget.conversationId,
          text,
          replyToMessageId: replyId,
        ));
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _unlockChat() async {
    final ok = await context.read<AppLockService>().authenticate('Unlock this chat');
    if (!mounted) return;
    if (ok) {
      setState(() => _unlocked = true);
    } else {
      context.pop();
    }
  }

  Future<void> _toggleLock(BuildContext context) async {
    final lock = context.read<AppLockService>();
    final library = context.read<LibraryService>();
    final messenger = ScaffoldMessenger.of(context);
    if (!await lock.isAvailable) {
      messenger.showSnackBar(const SnackBar(
          content: Text('This device has no screen lock or biometrics to check against.')));
      return;
    }
    if (!await lock.authenticate('Confirm to change the lock on this chat')) return;
    await library.toggleChatLock(widget.conversationId);
    messenger.showSnackBar(SnackBar(
        content: Text(library.isChatLocked(widget.conversationId)
            ? 'This chat now asks for your fingerprint or PIN'
            : 'Chat unlocked')));
  }

  Widget _pinnedBanner(BuildContext context, ChatService chat, List<Message> messages) {
    final id = chat.pinnedMessageId(widget.conversationId);
    if (id == null) return const SizedBox.shrink();
    Message? pinned;
    for (final m in messages) {
      if (m.id == id) pinned = m;
    }
    if (pinned == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.push_pin, size: 18, color: cs.primary),
        title: Text(pinned.content.isNotEmpty ? pinned.content : ChatService.describeMessage(pinned),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => _guard(() => chat.pinMessage(widget.conversationId, null)),
        ),
      ),
    );
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
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (text == null || !mounted) return;
    await _guard(() => context.read<ChatService>().editMessage(widget.conversationId, msg.id, text));
  }

  Future<void> _forward(Message msg) async {
    if (msg.isProtected) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Protected media cannot be forwarded.')));
      return;
    }
    final contacts = context.read<ContactService>().contacts.where((c) => !c.blocked);
    final spheres = context.read<SphereService>().writable;
    final target = await showForwardSheet(
      context,
      contacts: contacts.map((c) => (id: c.publicKey, name: c.displayName)).toList(),
      spheres: spheres.map((s) => (id: s.id, name: s.name)).toList(),
    );
    if (target == null || !mounted) return;
    await _guard(() async {
      if (target.isSphere) {
        await context.read<SphereChatService>().sendMessage(
              target.id,
              msg.content,
              forwarded: true,
              mediaRefs: msg.mediaRefs,
              provenance: msg.provenance,
              kind: msg.isPoll ? 'poll' : msg.kind,
              payload: msg.isPoll
                  ? (Map<String, dynamic>.from(msg.payload ?? {})..remove('votes'))
                  : msg.payload,
            );
      } else {
        await context.read<ChatService>().forwardMessage(target.id, msg);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Forwarded')));
      }
    });
  }

  Future<void> _sendSticker() async {
    final stickers = context.read<LibraryService>().stickers;
    if (stickers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No stickers yet. Open any photo and choose "Save as sticker".')));
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: GridView.count(
          crossAxisCount: 4,
          padding: const EdgeInsets.all(12),
          children: [
            for (final path in stickers)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, path),
                onLongPress: () {
                  context.read<LibraryService>().removeSticker(path);
                  Navigator.pop(ctx);
                },
                child: Padding(padding: const EdgeInsets.all(6), child: MediaThumb(ref: path)),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _send(() async {
      await context.read<ChatService>().sendMessage(widget.conversationId, '',
          mediaRefs: [picked], kind: 'sticker');
    });
  }

  Future<void> _sendPoll() async {
    final poll = await showCreatePollDialog(context);
    if (poll == null || !mounted) return;
    await _send(() => context.read<ChatService>().sendPoll(
          widget.conversationId,
          poll.question,
          poll.options,
          multiple: poll.multiple,
          anonymous: poll.anonymous,
        ));
  }

  Future<void> _shareLocation() async {
    final duration = await showDialog<Duration>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Share live location for'),
        children: [
          for (final d in const [Duration(minutes: 15), Duration(hours: 1), Duration(hours: 8)])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, d),
              child: Text(ChatService.describeDuration(d)),
            ),
        ],
      ),
    );
    if (duration == null || !mounted) return;
    await _send(() async {
      await context.read<ChatService>().startLiveLocation(widget.conversationId, duration);
    });
  }

  Future<void> _shareContact() async {
    final contacts = context.read<ContactService>().contacts
        .where((c) => !c.blocked && c.publicKey != widget.conversationId)
        .toList();
    final picked = await showModalBottomSheet<Contact>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Share a contact', style: TextStyle(fontWeight: FontWeight.w700))),
            for (final c in contacts)
              ListTile(title: Text(c.displayName), onTap: () => Navigator.pop(ctx, c)),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _send(() async {
      await context.read<ChatService>().sendContactCard(widget.conversationId, {
        'publicKey': picked.publicKey,
        'name': picked.displayName,
        if (picked.keyExchangePublicKey != null) 'exchangeKey': picked.keyExchangePublicKey,
        if (picked.relayHost != null) 'relay': picked.relayHost,
      });
    });
  }

  Future<void> _sendFile() async {
    final messenger = ScaffoldMessenger.of(context);
    final PickedFile? picked;
    try {
      picked = await FileBridge.pick();
    } on UnsupportedError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message ?? 'Not available here')));
      return;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not pick a file: $e')));
      return;
    }
    if (picked == null || !mounted) return;
    final file = picked;
    await _send(() => context.read<ChatService>().sendFile(widget.conversationId,
        path: file.path, name: file.name, mime: file.mime, size: file.size));
  }

  Future<void> _openFile(Message m) => openFileMessage(context, m);

  Future<void> _chatLook() async {
    final library = context.read<LibraryService>();
    final id = widget.conversationId;
    final nickname = TextEditingController(text: library.chatNickname(id) ?? '');
    var theme = library.chatTheme(id);
    var emoji = library.chatEmoji(id);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Chat look', style: Theme.of(ctx).textTheme.titleMedium),
            Text('Only on this device. The other side sees nothing of it.',
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final (tid, label) in ChatThemes.all)
                ChoiceChip(
                  label: Text(label),
                  avatar: CircleAvatar(backgroundColor: ChatThemes.mine(tid) ?? Theme.of(ctx).colorScheme.primary, radius: 8),
                  selected: theme == tid,
                  onSelected: (_) {
                    setSheet(() => theme = tid);
                    library.setChatLook(id, theme: tid);
                  },
                ),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: nickname,
              decoration: const InputDecoration(labelText: 'Nickname for them here', hintText: 'Leave empty for their name'),
              onChanged: (v) => library.setChatLook(id, nickname: v),
            ),
            const SizedBox(height: 12),
            Text('Chat emoji', style: Theme.of(ctx).textTheme.labelLarge),
            Wrap(spacing: 6, children: [
              for (final e in const ['🙌', '❤️', '🔥', '😂', '🎉', '🙏', '👀', '💯'])
                ChoiceChip(
                  label: Text(e),
                  selected: emoji == e,
                  onSelected: (_) {
                    setSheet(() => emoji = e);
                    library.setChatLook(id, emoji: e);
                  },
                ),
            ]),
            const SizedBox(height: 8),
            Text('One tap on it sends it; it leads the reactions.', style: Theme.of(ctx).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }

  Future<void> _sendLater() async {
    var text = _messageController.text.trim();
    if (text.isEmpty) {
      // Reached from the attach sheet with nothing typed yet.
      final typed = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final c = TextEditingController();
          return AlertDialog(
            title: const Text('Send later'),
            content: TextField(
                controller: c,
                autofocus: true,
                maxLines: 4,
                minLines: 1,
                decoration: const InputDecoration(hintText: 'What to send')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Pick a time')),
            ],
          );
        },
      );
      if (typed == null || typed.trim().isEmpty || !mounted) return;
      text = typed.trim();
    }
    final now = DateTime.now();
    final date = await showDatePicker(
        context: context, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)));
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))));
    if (time == null || !mounted) return;
    final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final chat = context.read<ChatService>();
      await chat.scheduleMessage(widget.conversationId, text, at);
      _messageController.clear();
      final exact = await SendAlarms.exactAllowed();
      messenger.showSnackBar(SnackBar(
          content: Text(exact
              ? 'Will be sent ${_fmtWhen(at)} from this phone, even with the app closed'
              : 'Will be sent ${_fmtWhen(at)} from this phone; Android may delay it unless '
                  'exact alarms are allowed for Spheres'),
          action: exact ? null : const SnackBarAction(label: 'Allow', onPressed: SendAlarms.openSettings)));
    } on ArgumentError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${e.message}')));
    }
  }

  static String _fmtWhen(DateTime at) =>
      '${at.day}/${at.month} at ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

  /// A photo or video shown only while held; see [MediaProtection].
  Future<void> _sendProtected() async {
    final choice = await showProtectedMediaSheet(context);
    if (choice == null || !mounted) return;
    final media = context.read<MediaService>();
    final messenger = ScaffoldMessenger.of(context);
    String? path;
    try {
      path = switch (choice.source) {
        'video' => await media.pickVideo(limit: MediaService.chatVideoLimit),
        'camera' => await media.captureImage(),
        _ => await media.pickAndStoreImage(),
      };
    } on MediaRejectedException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on UnsupportedVideoException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (path == null || !mounted) return;
    final chosen = path;
    await _send(() => context.read<ChatService>().sendMessage(
          widget.conversationId,
          choice.source == 'video' ? '[Video]' : '[Image]',
          mediaRefs: [chosen],
          payload: {'protected': choice.protection.toJson()},
        ));
  }

  Future<void> _sendViewOnce() async {
    final path = await context.read<MediaService>().pickAndStoreImage();
    if (path == null || !mounted) return;
    await _send(() async {
      await context.read<ChatService>().sendMessage(widget.conversationId, '[Image]',
          mediaRefs: [path], viewOnce: true);
    });
  }

  Future<void> _openViewOnce(Message msg) async {
    if (msg.mediaRefs.isEmpty) return;
    await context.push('/media/view?ref=${Uri.encodeComponent(msg.mediaRefs.first)}');
    if (!mounted) return;
    // Our own copy stays until they open theirs; theirs goes after one look.
    if (msg.senderId != context.read<IdentityService>().publicKey) {
      await context.read<ChatService>().consumeViewOnce(widget.conversationId, msg.id);
    }
  }

  Future<void> _addFromCard(Message msg) async {
    final p = msg.payload ?? const {};
    final key = p['publicKey'];
    if (key is! String) return;
    await _guard(() => context.read<ContactService>().addContact(
          key,
          p['name'] as String? ?? 'Contact',
          keyExchangePublicKey: p['exchangeKey'] as String?,
          relayHost: p['relay'] as String?,
        ));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Request sent')));
    }
  }

  Future<void> _chooseDisappearing(BuildContext context) async {
    final chat = context.read<ChatService>();
    final chosen = await showDisappearingDialog(context, chat.disappearAfter(widget.conversationId));
    if (chosen == null) return;
    await _guard(() => chat.setDisappearing(
        widget.conversationId, chosen == const Duration() ? null : chosen));
  }

  Future<void> _exportChat(BuildContext context, String displayName) async {
    final chat = context.read<ChatService>();
    final me = context.read<IdentityService>().publicKey;
    final text = chat.exportConversation(
        widget.conversationId, (k) => k == me ? 'You' : displayName);
    final dir = await getApplicationDocumentsDirectory();
    final out = Directory('${dir.path}/exports');
    if (!out.existsSync()) await out.create(recursive: true);
    final file = File('${out.path}/chat_${displayName.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}_'
        '${DateTime.now().millisecondsSinceEpoch}.txt');
    await file.writeAsString(text);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Exported as plain text to ${file.path}'), duration: const Duration(seconds: 6)));
  }

  /// Run a send, surfacing the reason if it could not be encrypted.
  ///
  /// A message that cannot be sealed is not shown as sent — the user is told
  /// why instead, which is the difference between "not delivered" and
  /// "silently delivered in the clear".
  /// A line under the app bar when keys were verified and have since changed.
  /// Silent otherwise: an unverified chat is the normal state, not a warning.
  Widget _verificationBanner(
      BuildContext context, ContactService contacts, IdentityService identity) {
    final me = identity.publicKey;
    final contact = contacts.getContact(widget.conversationId);
    if (me == null || contact == null || contact.verifiedFingerprint == null) {
      return const SizedBox.shrink();
    }
    if (contact.allDeviceKeys.isEmpty) return const SizedBox.shrink();
    final number = SafetyNumber.compute(
      myIdentity: me,
      myDeviceKeys: identity.deviceExchangeKeys,
      peerIdentity: contact.publicKey,
      peerDeviceKeys: contact.allDeviceKeys,
    );
    if (contacts.verificationOf(contact.publicKey, number) != ContactVerification.changed) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: InkWell(
        onTap: () => context.push('/contact/${widget.conversationId}/verify'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.gpp_maybe_outlined, color: cs.onErrorContainer, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Their encryption keys changed since you verified them. Tap to compare again.',
                  style: TextStyle(color: cs.onErrorContainer, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _send(Future<void> Function() action) async {
    try {
      await action();
      _scrollToBottom();
    } on NoSessionException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cannot encrypt to this contact yet — their encryption key has not '
            'arrived. Ask them to open the app, then try again.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not send: $e')));
    }
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
        
        await _recorderController.record(path: path);
        
        setState(() {
          _isRecording = true;
        });
      }
    } catch (e) {
      debugPrint('[VoiceNote] Error starting recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    try {
      final path = await _recorderController.stop();
      setState(() {
        _isRecording = false;
      });

      if (path != null) {
        await _send(() => context.read<ChatService>().sendMessage(
              widget.conversationId,
              '[Voice Note]',
              audioRef: path,
            ));
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
    final choice = await showModalBottomSheet<String>(
      context: context,
      // Scrolls: on shorter screens the last entries ran off the bottom.
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              subtitle: const Text('Carries the strongest origin score'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Video'),
              subtitle: const Text('Up to 3 minutes'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.video_camera_front_outlined),
              title: const Text('Record a video note'),
              subtitle: const Text('Up to 60 seconds'),
              onTap: () => Navigator.pop(ctx, 'video_note'),
            ),
            ListTile(
              leading: const Icon(Icons.looks_one_outlined),
              title: const Text('Photo, view once'),
              subtitle: const Text('Gone from their device after one look'),
              onTap: () => Navigator.pop(ctx, 'view_once'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Write for an occasion'),
              subtitle: const Text('Questions to help you find your own words; nothing is written for you'),
              onTap: () => Navigator.pop(ctx, 'guide'),
            ),
            ListTile(
              leading: const Icon(Icons.schedule_send_outlined),
              title: const Text('Send later'),
              subtitle: const Text('At a day and time you choose, even with the app closed'),
              onTap: () => Navigator.pop(ctx, 'later'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Protected photo or video'),
              subtitle: const Text('Shown only while held, never saved or shared'),
              onTap: () => Navigator.pop(ctx, 'protected'),
            ),
            ListTile(
              leading: const Icon(Icons.poll_outlined),
              title: const Text('Poll'),
              onTap: () => Navigator.pop(ctx, 'poll'),
            ),
            ListTile(
              leading: const Icon(Icons.emoji_emotions_outlined),
              title: const Text('Sticker'),
              onTap: () => Navigator.pop(ctx, 'sticker'),
            ),
            ListTile(
              leading: const Icon(Icons.my_location),
              title: const Text('Live location'),
              subtitle: const Text('Sealed like a message; the relay never sees it'),
              onTap: () => Navigator.pop(ctx, 'location'),
            ),
            ListTile(
              leading: const Icon(Icons.contact_page_outlined),
              title: const Text('Contact card'),
              onTap: () => Navigator.pop(ctx, 'contact'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('File'),
              subtitle: const Text('Any type, sent as it is, encrypted'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'file') return _sendFile();
    if (choice == 'poll') return _sendPoll();
    if (choice == 'sticker') return _sendSticker();
    if (choice == 'location') return _shareLocation();
    if (choice == 'contact') return _shareContact();
    if (choice == 'view_once') return _sendViewOnce();
    if (choice == 'protected') return _sendProtected();
    if (choice == 'later') return _sendLater();
    if (choice == 'guide') {
      final name = context.read<ContactService>().getContact(widget.conversationId)?.displayName ?? 'them';
      final words = await showWritingGuide(
        context,
        name: name,
        initial: _messageController.text,
        onSpeakInstead: _startRecording,
      );
      if (words != null) {
        // Into the box, not sent: one more look is the writer's.
        _messageController.text = words;
        _messageController.selection = TextSelection.collapsed(offset: words.length);
      }
      return;
    }
    if (choice == 'video_note') {
      final messenger = ScaffoldMessenger.of(context);
      try {
        final path = await context.read<MediaService>().recordVideoNote();
        if (path != null && mounted) {
          await _send(() => context.read<ChatService>().sendMessage(
                widget.conversationId, '[Video]', mediaRefs: [path], kind: 'video_note'));
        }
      } on MediaRejectedException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      } on UnsupportedVideoException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }

    final media = context.read<MediaService>();
    final messenger = ScaffoldMessenger.of(context);
    String? path;
    String label;
    try {
      if (choice == 'video') {
        path = await media.pickVideo(limit: MediaService.chatVideoLimit);
        label = '[Video]';
      } else if (choice == 'camera') {
        path = await media.captureImage();
        label = '[Image]';
      } else {
        path = await media.pickAndStoreImage();
        label = '[Image]';
      }
    } on MediaRejectedException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } on UnsupportedVideoException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (path != null && mounted) {
      final chosen = path;
      await _send(() => context.read<ChatService>().sendMessage(
            widget.conversationId,
            label,
            mediaRefs: [chosen],
          ));
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
    final library = context.watch<LibraryService>();
    final displayName = library.chatNickname(widget.conversationId) ??
        contact?.displayName ??
        widget.conversationId;
    final myPublicKey = identityService.publicKey ?? 'self';
    final look = library.chatTheme(widget.conversationId);
    final isDark = theme.brightness == Brightness.dark;
    final wash = ChatThemes.wash(look, dark: isDark);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Stack(
              children: [
                InkWell(
                  onTap: () => context.push('/contact/${widget.conversationId}'),
                  borderRadius: BorderRadius.circular(20),
                  child: UserAvatar(
                    displayName: displayName,
                    identityKey: widget.conversationId,
                    size: AvatarSize.small,
                  ),
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
                  if ((contact?.activeNote ?? '').isNotEmpty)
                    Text('💬 ${contact!.activeNote}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
                  Builder(builder: (ctx) {
                    final typing =
                        chatService.isTyping(widget.conversationId);
                    if (typing) {
                      return Text(
                        'typing…',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: cs.primary,
                          fontStyle: FontStyle.italic,
                        ),
                      );
                    }
                    final connected =
                        chatService.isRelayConnected(widget.conversationId);
                    return Text(
                      connected
                          ? 'Relay Connected'
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
              } else if (value == 'reset') {
                _confirmSessionReset(context, displayName);
              } else if (value == 'verify') {
                context.push('/contact/${widget.conversationId}/verify');
              } else if (value == 'disappear') {
                _chooseDisappearing(context);
              } else if (value == 'export') {
                _exportChat(context, displayName);
              } else if (value == 'lock') {
                _toggleLock(context);
              } else if (value == 'blur') {
                context.read<LibraryService>().toggleBlurMedia(widget.conversationId);
              } else if (value == 'look') {
                _chatLook();
              } else if (value == 'vanish') {
                final chat = context.read<ChatService>();
                _guard(() => chat.setVanish(widget.conversationId, !chat.isVanish(widget.conversationId)));
              } else if (value == 'ignore') {
                context.read<LibraryService>().toggleIgnoreChat(widget.conversationId);
              } else if (value == 'poke') {
                _send(() => context.read<ChatService>().poke(widget.conversationId));
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'look', child: Text('Chat look: theme, nickname, emoji')),
              const PopupMenuItem(value: 'poke', child: Text('Poke 👉')),
              PopupMenuItem(
                value: 'vanish',
                child: Text(chatService.isVanish(widget.conversationId)
                    ? 'Vanish mode: on (5 minutes)'
                    : 'Vanish mode: off'),
              ),
              PopupMenuItem(
                value: 'ignore',
                child: Text(library.isChatIgnored(widget.conversationId)
                    ? 'Stop ignoring this chat'
                    : 'Ignore this chat'),
              ),
              PopupMenuItem(
                value: 'disappear',
                child: Text(chatService.disappearAfter(widget.conversationId) == null
                    ? 'Disappearing messages: off'
                    : 'Disappearing: ${ChatService.describeDuration(chatService.disappearAfter(widget.conversationId)!)}'),
              ),
              PopupMenuItem(
                value: 'lock',
                child: Text(context.read<LibraryService>().isChatLocked(widget.conversationId)
                    ? 'Unlock this chat'
                    : 'Lock this chat'),
              ),
              PopupMenuItem(
                value: 'blur',
                child: Text(context.read<LibraryService>().isMediaBlurred(widget.conversationId)
                    ? 'Show media directly'
                    : 'Blur media until tapped'),
              ),
              const PopupMenuItem(value: 'export', child: Text('Export chat')),
              const PopupMenuItem(
                  value: 'verify', child: Text('Verify encryption')),
              const PopupMenuItem(
                  value: 'reset', child: Text('Re-establish secure session')),
              const PopupMenuItem(value: 'delete', child: Text('Delete contact')),
            ],
          ),
        ],
      ),
      backgroundColor: wash == null ? null : Color.alphaBlend(wash, cs.surface),
      body: !_unlocked
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 56, color: cs.outline),
                  const SizedBox(height: 12),
                  const Text('This chat is locked'),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _unlockChat, child: const Text('Unlock')),
                ],
              ),
            )
          : Column(
        children: [
          _verificationBanner(context, contactService, identityService),
          _pinnedBanner(context, chatService, messages),
          if (chatService.wasRecentlyReset(widget.conversationId))
            MaterialBanner(
              backgroundColor: cs.tertiaryContainer,
              content: Text(
                'The secure session with $displayName was re-established. '
                'Messages either of you sent in the last few moments may not '
                'have arrived — check anything important got through.',
                style: TextStyle(color: cs.onTertiaryContainer),
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      chatService.acknowledgeReset(widget.conversationId),
                  child: const Text('Got it'),
                ),
              ],
            ),
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
                      final i = messages.length - 1 - index;
                      final newDay = i == 0 || !DateChip.sameDay(messages[i - 1].timestamp, message.timestamp);
                      // Their face once per run of their messages, on the
                      // newest one, like every messenger does it.
                      final endOfRun = i == messages.length - 1 ||
                          messages[i + 1].senderId != message.senderId ||
                          messages[i + 1].isSystem;

                      final library = context.watch<LibraryService>();
                      final bubble = MessageBubble(
                        myKey: myPublicKey,
                        avatarGutter: !isMine,
                        avatar: !isMine && endOfRun
                            ? UserAvatar(
                                displayName: displayName,
                                identityKey: widget.conversationId,
                                size: AvatarSize.small,
                              )
                            : null,
                        nameFor: (key) => key == myPublicKey ? 'You' : displayName,
                        resolveMessage: (id) {
                          for (final m in messages) {
                            if (m.id == id) return m;
                          }
                          return null;
                        },
                        onReply: (msg) => setState(() => _replyingTo = msg),
                        onReact: (msg, emoji) => context
                            .read<ChatService>()
                            .reactToMessage(
                                widget.conversationId, msg.id, emoji),
                        message: message,
                        isMine: isMine,
                        mineColor: ChatThemes.mine(look),
                        theirsColor: ChatThemes.theirs(look, dark: isDark),
                        favouriteEmoji: library.chatEmoji(widget.conversationId),
                        onOpenFile: _openFile,
                        isStarred: library.isStarred(message.id),
                        blurMedia: !isMine && library.isMediaBlurred(widget.conversationId),
                        isPinned: chatService.pinnedMessageId(widget.conversationId) == message.id,
                        readByPeer: chatService.isReadByPeer(widget.conversationId, message),
                        onDelete: (msg) {
                          chatService.deleteMessage(
                            widget.conversationId, msg.id);
                        },
                        onDeleteForEveryone: isMine
                            ? (msg) => _guard(() =>
                                chatService.deleteForEveryone(widget.conversationId, msg.id))
                            : null,
                        onEdit: (msg) => _editMessage(msg),
                        onForward: _forward,
                        onStar: (msg) => library.toggleStar(widget.conversationId, msg.id),
                        onPin: (msg) => _guard(() => chatService.pinMessage(
                            widget.conversationId,
                            chatService.pinnedMessageId(widget.conversationId) == msg.id
                                ? null
                                : msg.id)),
                        onVote: (msg, choices) =>
                            _guard(() => chatService.votePoll(widget.conversationId, msg.id, choices)),
                        onStopLiveLocation: (msg) =>
                            _guard(() => chatService.stopLiveLocation(widget.conversationId, msg.id)),
                        onAddContact: _addFromCard,
                        onOpenViewOnce: _openViewOnce,
                      );
                      return newDay
                          ? Column(children: [DateChip(day: message.timestamp), bubble])
                          : bubble;
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // What we're replying to, dismissable.
                  if (_replyingTo != null)
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                        border: Border(
                          left: BorderSide(color: cs.primary, width: 3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _replyingTo!.senderId == myPublicKey
                                      ? 'Replying to yourself'
                                      : 'Replying to $displayName',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: cs.primary),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _replyingTo!.content.isNotEmpty
                                      ? _replyingTo!.content
                                      : (_replyingTo!.audioRef != null
                                          ? 'Voice note'
                                          : 'Photo'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurfaceVariant),
                                ),
                              ],
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
                  if (chatService.isVanish(widget.conversationId))
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      color: cs.tertiaryContainer,
                      child: Text('Vanish mode: every message here disappears 5 minutes after it is sent, for both of you.',
                          style: theme.textTheme.bodySmall?.copyWith(color: cs.onTertiaryContainer)),
                    ),
                  if (library.isChatIgnored(widget.conversationId))
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      color: cs.surfaceContainerHighest,
                      child: Text('Ignored: no notifications, and they are not told when you read or type.',
                          style: theme.textTheme.bodySmall),
                    ),
                  for (final s in chatService.scheduledFor(widget.conversationId))
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.schedule_send_outlined, color: cs.primary),
                      title: Text(s.content, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('Sends ${_fmtWhen(s.at)} from this device'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Cancel',
                        onPressed: () => context.read<ChatService>().cancelScheduled(s.id),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                  if (!_isRecording)
                    // Attachments. The emoticon picker and the chat emoji
                    // live inside the field, so the field gets the width.
                    IconButton(
                      tooltip: 'Attach',
                      icon: Icon(Icons.add_circle,
                          color: cs.primary, size: 28),
                      onPressed: _attachMedia,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                    ),

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
                              decoration: InputDecoration(
                                hintText: 'Aa',
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                isDense: true,
                                suffixIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Emoticons',
                                      icon: Icon(Icons.emoji_emotions_outlined,
                                          color: cs.onSurfaceVariant, size: 22),
                                      onPressed: () => _showEmoticonPicker(context),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                    ),
                                    if (!_hasText)
                                      IconButton(
                                        tooltip: 'Send the chat emoji',
                                        icon: Text(library.chatEmoji(widget.conversationId),
                                            style: const TextStyle(fontSize: 20)),
                                        onPressed: () => _send(() => context
                                            .read<ChatService>()
                                            .sendMessage(widget.conversationId,
                                                library.chatEmoji(widget.conversationId))),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                      ),
                                    const SizedBox(width: 4),
                                  ],
                                ),
                              ),
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sendMessage(),
                              maxLines: 4,
                              minLines: 1,
                            ),
                          ),
                  ),

                  // Send or mic. One widget for every state, so the long
                  // press that started a recording still gets its release:
                  // swapping the button out mid-gesture meant letting go did
                  // nothing and the recording ran until "send" was tapped.
                  GestureDetector(
                    onLongPressStart: _hasText ? (_) => _sendLater() : (_) => _startRecording(),
                    onLongPressEnd: _hasText ? null : (_) => _stopRecording(),
                    child: IconButton(
                      icon: _isRecording
                          ? const Icon(Icons.send_rounded, color: Colors.green, size: 24)
                          : _hasText
                              ? Icon(Icons.send_rounded, color: cs.primary, size: 24)
                              : Icon(Icons.mic_none_rounded, color: cs.primary, size: 26),
                      onPressed: _isRecording
                          ? _stopRecording
                          : _hasText
                              ? _sendMessage
                              : () {
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
          AudioWaveforms(
            size: const Size(100, 30),
            recorderController: _recorderController,
            enableGesture: false,
            waveStyle: WaveStyle(
              waveColor: Colors.red,
              showMiddleLine: false,
              spacing: 4,
              extendWaveform: true,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () async {
              await _recorderController.stop();
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
            UserAvatar(displayName: name, identityKey: widget.conversationId, size: AvatarSize.large),
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
