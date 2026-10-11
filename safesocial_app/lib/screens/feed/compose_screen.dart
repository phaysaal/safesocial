import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../services/sphere_service.dart';
import '../../services/video_transcoder.dart';
import '../../widgets/avatar.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/provenance_badge.dart';
import '../../widgets/message_cards.dart';
import '../../widgets/post_extras.dart';
import '../../services/contact_service.dart';
import 'package:go_router/go_router.dart';

/// Writing a post.
///
/// A whole screen rather than a sheet. A sheet has to stay short, which forces
/// everything that matters — what you are writing, what you attached, who will
/// see it — to compete for a few hundred pixels above the keyboard. Attached
/// photos in particular were not shown at all, so the only evidence a picture
/// had been chosen was that the picker had closed.
class ComposeScreen extends StatefulWidget {
  /// Media to start with, e.g. when re-sharing from the viewer.
  final List<String> initialMedia;

  /// A saved draft to continue.
  final Map<String, dynamic>? draft;

  const ComposeScreen({super.key, this.initialMedia = const [], this.draft});

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  final _controller = TextEditingController();
  final _media = <String>[];
  final _altTexts = <String, String>{};
  final _targets = <String>{};
  final _coAuthors = <String>{};
  bool _posting = false;

  /// 'post' | 'event' | 'poll'
  String _kind = 'post';
  Map<String, dynamic>? _payload;
  String? _draftId;

  @override
  void initState() {
    super.initState();
    _media.addAll(widget.initialMedia);
    final draft = widget.draft;
    if (draft != null) {
      _draftId = draft['id'] as String?;
      _controller.text = draft['content'] as String? ?? '';
      _media.addAll((draft['mediaRefs'] as List?)?.cast<String>() ?? const []);
      _targets.addAll((draft['sphereIds'] as List?)?.cast<String>() ?? const []);
      _kind = draft['kind'] as String? ?? 'post';
      _payload = (draft['payload'] as Map?)?.cast<String, dynamic>();
      final alts = (draft['altTexts'] as List?)?.cast<String>() ?? const [];
      for (var i = 0; i < alts.length && i < _media.length; i++) {
        if (alts[i].isNotEmpty) _altTexts[_media[i]] = alts[i];
      }
    }
    final writable = context.read<SphereService>().writable;
    if (_targets.isEmpty && writable.isNotEmpty) _targets.add(writable.first.id);
    _controller.addListener(() => setState(() {}));
  }

  List<String> get _altList => _media.map((m) => _altTexts[m] ?? '').toList();

  Future<void> _saveDraft({DateTime? scheduledFor}) async {
    final feed = context.read<FeedService>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await feed.saveDraft(
      id: _draftId,
      content: _controller.text.trim(),
      mediaRefs: List.of(_media),
      sphereIds: _targets,
      scheduledFor: scheduledFor,
      kind: _kind,
      payload: _payload,
      altTexts: _altList,
    );
    messenger.showSnackBar(SnackBar(
        content: Text(scheduledFor == null
            ? 'Saved as a draft'
            : 'Scheduled for ${scheduledFor.toLocal().toString().substring(0, 16)}. Keep the app '
                'installed; it posts from this device.')));
    navigator.pop();
  }

  Future<void> _schedule() async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(hours: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(DateTime.now().add(const Duration(hours: 1))));
    if (time == null || !mounted) return;
    await _saveDraft(scheduledFor: DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _makeEvent() async {
    final event = await showEventDialog(context);
    if (event == null) return;
    setState(() {
      _kind = 'event';
      _payload = {
        'title': event.title,
        'starts_at': event.startsAt.toIso8601String(),
        if (event.endsAt != null) 'ends_at': event.endsAt!.toIso8601String(),
        'place': event.place,
        'rsvps': <String, dynamic>{},
      };
    });
  }

  Future<void> _makePoll() async {
    final poll = await showCreatePollDialog(context);
    if (poll == null) return;
    setState(() {
      _kind = 'poll';
      _payload = {
        'question': poll.question,
        'options': poll.options,
        'multiple': poll.multiple,
        'anonymous': poll.anonymous,
        'votes': <String, dynamic>{},
      };
      if (_controller.text.trim().isEmpty) _controller.text = poll.question;
    });
  }

  Future<void> _editAltText(String path) async {
    final controller = TextEditingController(text: _altTexts[path] ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Describe this image'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'For people who cannot see it'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (text == null) return;
    setState(() {
      if (text.isEmpty) {
        _altTexts.remove(path);
      } else {
        _altTexts[path] = text;
      }
    });
  }

  Future<void> _pickCoAuthors() async {
    final spheres = context.read<SphereService>();
    final contacts = context.read<ContactService>();
    final me = context.read<IdentityService>().publicKey;
    final members = <String>{};
    for (final id in _targets) {
      members.addAll(spheres.sphere(id)?.members.map((m) => m.identityKey) ?? const []);
    }
    members.remove(me);
    if (members.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Co-authors', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('They are shown as authors once they confirm.', style: TextStyle(fontSize: 12)),
              ),
              for (final key in members)
                CheckboxListTile(
                  value: _coAuthors.contains(key),
                  title: Text(contacts.getContact(key)?.displayName ?? '${key.substring(0, 8)}…'),
                  onChanged: (v) {
                    setSheet(() => v == true ? _coAuthors.add(key) : _coAuthors.remove(key));
                    setState(() {});
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canPost =>
      !_posting &&
      _targets.isNotEmpty &&
      (_controller.text.trim().isNotEmpty || _media.isNotEmpty || _payload != null);

  Future<void> _addImage() async {
    final path = await context.read<MediaService>().pickAndStoreImage();
    // setState was the missing half before: the picker returned a path, it was
    // added to a list, and nothing rebuilt or displayed it.
    if (path != null && mounted) setState(() => _media.add(path));
  }

  Future<void> _takePhoto() async {
    final path = await context.read<MediaService>().captureImage();
    if (path != null && mounted) setState(() => _media.add(path));
  }

  Future<void> _addVideo() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await context
          .read<MediaService>()
          .pickVideo(limit: MediaService.feedVideoLimit);
      if (path != null && mounted) setState(() => _media.add(path));
    } on MediaRejectedException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } on UnsupportedVideoException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _post() async {
    if (!_canPost) return;
    final feed = context.read<FeedService>();
    final spheres = context.read<SphereService>();
    final identity = context.read<IdentityService>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    setState(() => _posting = true);
    try {
      // Everyone who will receive it, across every sphere chosen.
      final audience = <String>{};
      for (final id in _targets) {
        final sphere = spheres.sphere(id);
        if (sphere != null) {
          audience.addAll(sphere.members.map((m) => m.identityKey));
        }
      }

      await feed.createPost(
        _controller.text.trim(),
        sphereIds: _targets,
        audienceMembers: audience.toList(),
        mediaRefs: _media.isEmpty ? null : List.of(_media),
        authorName: identity.currentIdentity?.displayName ?? 'You',
        kind: _kind,
        payload: _payload,
        altTexts: _altList,
        coAuthors: _coAuthors.toList(),
      );
      if (_draftId != null) await feed.deleteDraft(_draftId!);
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _posting = false);
      messenger.showSnackBar(SnackBar(content: Text('Could not post: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final identity = context.watch<IdentityService>();
    final writable = context.watch<SphereService>().writable;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(_kind == 'event' ? 'New event' : (_kind == 'poll' ? 'New poll' : 'New post')),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'draft') _saveDraft();
              if (v == 'schedule') _schedule();
              if (v == 'drafts') context.push('/drafts');
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'draft', enabled: _canPost, child: const Text('Save as draft')),
              PopupMenuItem(value: 'schedule', enabled: _canPost, child: const Text('Schedule…')),
              const PopupMenuItem(value: 'drafts', child: Text('Drafts and scheduled')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: FilledButton(
              onPressed: _canPost ? _post : null,
              child: _posting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Post'),
            ),
          ),
        ],
      ),
      body: writable.isEmpty
          ? _noSpheres(theme, cs)
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Row(
                        children: [
                          UserAvatar(
                            displayName:
                                identity.currentIdentity?.displayName ?? 'You',
                            size: AvatarSize.medium,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            identity.currentIdentity?.displayName ?? 'You',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _controller,
                        autofocus: true,
                        minLines: 4,
                        maxLines: null,
                        textCapitalization: TextCapitalization.sentences,
                        style: theme.textTheme.bodyLarge,
                        decoration: InputDecoration(
                          hintText: "What's on your mind?",
                          border: InputBorder.none,
                          hintStyle: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                      if (_kind == 'event' && _payload != null)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.event, color: cs.primary),
                          title: Text(_payload!['title'] as String? ?? 'Event'),
                          subtitle: Text(
                              '${_payload!['starts_at']}'.replaceAll('T', ' ').substring(0, 16) +
                                  ((_payload!['place'] as String?)?.isNotEmpty == true
                                      ? ' · ${_payload!['place']}'
                                      : '')),
                          trailing: IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                    _kind = 'post';
                                    _payload = null;
                                  })),
                        ),
                      if (_kind == 'poll' && _payload != null)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.poll_outlined, color: cs.primary),
                          title: Text(_payload!['question'] as String? ?? 'Poll'),
                          subtitle: Text(((_payload!['options'] as List?) ?? []).join(' · ')),
                          trailing: IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => setState(() {
                                    _kind = 'post';
                                    _payload = null;
                                  })),
                        ),
                      if (_coAuthors.isNotEmpty)
                        Text('With ${_coAuthors.length} co-author${_coAuthors.length == 1 ? '' : 's'}, pending their confirmation',
                            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      if (_media.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _attachments(cs),
                        Text('Long-press a photo to describe it for screen readers',
                            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                      const SizedBox(height: 24),
                      Text('Who can see this', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(
                        _targets.length <= 1
                            ? 'Only the people in the sphere you choose.'
                            : 'It goes to each sphere separately. Nobody can '
                                'tell it was also shared somewhere else.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: writable
                            .map((sphere) => _sphereChip(sphere, cs))
                            .toList(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                SafeArea(
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Add a photo',
                        icon: Icon(Icons.photo_library_outlined,
                            color: Colors.green[600]),
                        onPressed: _posting ? null : _addImage,
                      ),
                      IconButton(
                        tooltip: 'Take a photo',
                        icon: Icon(Icons.photo_camera_outlined,
                            color: Colors.green[800]),
                        onPressed: _posting ? null : _takePhoto,
                      ),
                      IconButton(
                        tooltip: 'Add a video',
                        icon: Icon(Icons.videocam_outlined,
                            color: Colors.red[400]),
                        onPressed: _posting ? null : _addVideo,
                      ),
                      IconButton(
                        tooltip: 'Event',
                        icon: Icon(Icons.event_outlined, color: cs.primary),
                        onPressed: _posting ? null : _makeEvent,
                      ),
                      IconButton(
                        tooltip: 'Poll',
                        icon: Icon(Icons.poll_outlined, color: cs.primary),
                        onPressed: _posting ? null : _makePoll,
                      ),
                      IconButton(
                        tooltip: 'Co-authors',
                        icon: Icon(Icons.group_add_outlined, color: cs.primary),
                        onPressed: _posting || _targets.isEmpty ? null : _pickCoAuthors,
                      ),
                      const Spacer(),
                      if (_media.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: Text(
                            '${_media.length} attached',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sphereChip(Sphere sphere, ColorScheme cs) {
    final selected = _targets.contains(sphere.id);
    return FilterChip(
      selected: selected,
      label: Text('${sphere.name} · ${sphere.members.length}'),
      onSelected: (on) => setState(() {
        if (on) {
          _targets.add(sphere.id);
        } else {
          _targets.remove(sphere.id);
        }
      }),
    );
  }

  Widget _attachments(ColorScheme cs) {
    return SizedBox(
      height: 120,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _media.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final path = _media[index];
          return Stack(
            children: [
              GestureDetector(
                onLongPress: () => _editAltText(path),
                child: Stack(children: [
                  MediaThumb(
                    ref: path,
                    width: 120,
                    height: 120,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  if (_altTexts[path]?.isNotEmpty == true)
                    const Positioned(
                      left: 4,
                      bottom: 4,
                      child: Icon(Icons.closed_caption, color: Colors.white, size: 18),
                    ),
                  // The score that will travel with this picture, so the
                  // sender sees it before anyone else does.
                  if (MediaService.provenanceFor(path) != null)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: ProvenanceBadge(
                          provenance: MediaService.provenanceFor(path)!, compact: true),
                    ),
                ]),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: () => setState(() => _media.removeAt(index)),
                  child: CircleAvatar(
                    radius: 12,
                    backgroundColor: Colors.black54,
                    child: const Icon(Icons.close, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _noSpheres(ThemeData theme, ColorScheme cs) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.blur_circular, size: 56, color: cs.outline),
              const SizedBox(height: 16),
              Text(
                'You need a sphere first',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Everything here is addressed to a named group of people. '
                'There is no public option to fall back on.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
}
