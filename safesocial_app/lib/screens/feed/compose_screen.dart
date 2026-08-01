import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../services/sphere_service.dart';
import '../../widgets/avatar.dart';

/// Writing a post.
///
/// A whole screen rather than a sheet. A sheet has to stay short, which forces
/// everything that matters — what you are writing, what you attached, who will
/// see it — to compete for a few hundred pixels above the keyboard. Attached
/// photos in particular were not shown at all, so the only evidence a picture
/// had been chosen was that the picker had closed.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key});

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  final _controller = TextEditingController();
  final _media = <String>[];
  final _targets = <String>{};
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    final writable = context.read<SphereService>().writable;
    if (writable.isNotEmpty) _targets.add(writable.first.id);
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canPost =>
      !_posting &&
      _targets.isNotEmpty &&
      (_controller.text.trim().isNotEmpty || _media.isNotEmpty);

  Future<void> _addImage() async {
    final path = await context.read<MediaService>().pickAndStoreImage();
    // setState was the missing half before: the picker returned a path, it was
    // added to a list, and nothing rebuilt or displayed it.
    if (path != null && mounted) setState(() => _media.add(path));
  }

  Future<void> _addVideo() async {
    final path = await context.read<MediaService>().pickAndStoreVideo();
    if (path != null && mounted) setState(() => _media.add(path));
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
      );
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
        title: const Text('New post'),
        actions: [
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
                      if (_media.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _attachments(cs),
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
                        tooltip: 'Add a video',
                        icon: Icon(Icons.videocam_outlined,
                            color: Colors.red[400]),
                        onPressed: _posting ? null : _addVideo,
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
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(path),
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                  // A video has no thumbnail here; showing that something is
                  // attached still beats showing nothing at all.
                  errorBuilder: (_, __, ___) => Container(
                    width: 120,
                    height: 120,
                    color: cs.surfaceContainerHighest,
                    child: Icon(Icons.movie_outlined, color: cs.onSurfaceVariant),
                  ),
                ),
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
