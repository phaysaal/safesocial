import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../widgets/media_thumb.dart';
import 'story_viewer_screen.dart';

/// Our own stories, kept on this device after their day is over. From here a
/// picture goes into a highlight on the profile.
class StoryArchiveScreen extends StatelessWidget {
  const StoryArchiveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<FeedService>();
    final theme = Theme.of(context);
    final stories = feed.storyArchive;
    return Scaffold(
      appBar: AppBar(title: const Text('Story archive')),
      body: stories.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Stories you share are kept here, on this device only, after they disappear from the sphere. Pick one to put it in a highlight on your profile.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 9 / 16),
              itemCount: stories.length,
              itemBuilder: (context, i) {
                final s = stories[i];
                return InkWell(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => StoryViewerScreen(stories: [s], authorName: 'You'))),
                  onLongPress: () => _menu(context, s),
                  child: Stack(fit: StackFit.expand, children: [
                    if (s.mediaRefs.isNotEmpty)
                      MediaThumb(ref: s.mediaRefs.first, fit: BoxFit.cover)
                    else
                      Container(color: Colors.deepPurple.shade900),
                    Positioned(
                      left: 4,
                      bottom: 4,
                      right: 4,
                      child: Text(
                        '${s.createdAt.day}/${s.createdAt.month}/${s.createdAt.year}',
                        style: const TextStyle(color: Colors.white, fontSize: 11, shadows: [Shadow(blurRadius: 4)]),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        icon: const Icon(Icons.more_vert, color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                        onPressed: () => _menu(context, s),
                      ),
                    ),
                  ]),
                );
              },
            ),
    );
  }

  Future<void> _menu(BuildContext context, Post s) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (s.mediaRefs.isNotEmpty && File(s.mediaRefs.first).existsSync() && !MediaService.looksLikeVideo(s.mediaRefs.first))
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Add to a highlight'),
              onTap: () => Navigator.pop(ctx, 'highlight'),
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Remove from archive'),
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'remove') {
      await context.read<FeedService>().removeFromStoryArchive(s.id);
    } else if (choice == 'highlight') {
      await showHighlightPicker(context, s.mediaRefs.first);
    }
  }
}

/// Put one picture into an existing highlight or a new one.
Future<void> showHighlightPicker(BuildContext context, String ref) async {
  final identity = context.read<IdentityService>();
  final existing = identity.currentIdentity?.highlights ?? const [];
  final title = TextEditingController();
  final chosen = await showDialog<String?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Add to a highlight'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final h in existing)
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: Text(h.title),
              subtitle: Text('${h.refs.length} picture${h.refs.length == 1 ? '' : 's'}'),
              onTap: () => Navigator.pop(ctx, h.id),
            ),
          TextField(
            controller: title,
            decoration: const InputDecoration(labelText: 'New highlight'),
            textCapitalization: TextCapitalization.sentences,
            onSubmitted: (_) => Navigator.pop(ctx, ''),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Create')),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (chosen.isEmpty && title.text.trim().isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('Give the highlight a name.')));
    return;
  }
  await identity.addToHighlight(
      highlightId: chosen.isEmpty ? null : chosen, title: title.text, ref: ref);
  messenger.showSnackBar(const SnackBar(content: Text('Added to your profile. Contacts see it with your next profile update.')));
}
