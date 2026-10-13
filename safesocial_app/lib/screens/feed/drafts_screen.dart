import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/feed_service.dart';
import '../../services/send_alarms.dart';
import '../../services/sphere_service.dart';
import 'compose_screen.dart';

/// Posts written but not yet sent: drafts, and ones scheduled for later.
class DraftsScreen extends StatelessWidget {
  const DraftsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final feed = context.watch<FeedService>();
    final spheres = context.watch<SphereService>();
    final drafts = feed.drafts;

    return Scaffold(
      appBar: AppBar(title: const Text('Drafts and scheduled')),
      body: drafts.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Nothing waiting. Save a draft or schedule a post from the composer.',
                    textAlign: TextAlign.center),
              ),
            )
          : ListView.separated(
              itemCount: drafts.length + 1,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == drafts.length) return const _AlarmNote();
                final d = drafts[i];
                final at = DateTime.tryParse(d['scheduledFor'] as String? ?? '');
                final names = (d['sphereIds'] as List)
                    .cast<String>()
                    .map((id) => spheres.sphere(id)?.name ?? 'a sphere you left')
                    .join(', ');
                final kind = d['kind'] as String? ?? 'post';
                return ListTile(
                  leading: Icon(at == null ? Icons.drafts_outlined : Icons.schedule),
                  title: Text(
                    (d['content'] as String?)?.isNotEmpty == true
                        ? d['content'] as String
                        : (kind == 'event'
                            ? 'Event: ${(d['payload'] as Map?)?['title'] ?? ''}'
                            : (kind == 'poll' ? 'Poll' : 'Media only')),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(at == null
                      ? 'Draft · $names'
                      : 'Posts ${at.toLocal().toString().substring(0, 16)} · $names'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ComposeScreen(draft: d))),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        if (action == 'post') await feed.publishDraft(d['id'] as String);
                        if (action == 'delete') await feed.deleteDraft(d['id'] as String);
                      } catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text('$e')));
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'post', child: Text('Post now')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

/// Whether a scheduled post will go at its minute with the app closed.
class _AlarmNote extends StatelessWidget {
  const _AlarmNote();

  @override
  Widget build(BuildContext context) {
    if (!context.watch<FeedService>().drafts.any((d) => d['scheduledFor'] != null)) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<bool>(
      future: SendAlarms.exactAllowed(),
      builder: (context, snap) {
        final exact = snap.data;
        if (exact == null) return const SizedBox.shrink();
        return ListTile(
          leading: Icon(exact ? Icons.alarm_on : Icons.alarm_off,
              color: exact ? null : Theme.of(context).colorScheme.error),
          title: Text(exact
              ? 'Scheduled posts go from this phone at their minute, even with the app closed.'
              : 'Android may delay scheduled posts until the app is opened.'),
          subtitle: exact ? null : const Text('Allow exact alarms for Spheres to send on time.'),
          onTap: exact ? null : SendAlarms.openSettings,
        );
      },
    );
  }
}
