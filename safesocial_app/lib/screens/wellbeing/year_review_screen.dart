import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/call_service.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/sphere_chat_service.dart';
import '../../services/sphere_service.dart';

/// The year so far, counted from what this device holds. Nothing is fetched,
/// nothing is sent, nobody is told.
class YearReviewScreen extends StatelessWidget {
  const YearReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final me = context.watch<IdentityService>().publicKey;
    final feed = context.watch<FeedService>();
    final chat = context.watch<ChatService>();
    final sphereChat = context.watch<SphereChatService>();
    final spheres = context.watch<SphereService>();
    final contacts = context.watch<ContactService>();
    final calls = context.watch<CallService>();
    final year = DateTime.now().year;
    bool thisYear(DateTime d) => d.year == year;

    final mine = feed.posts.where((p) => p.authorId == me && thisYear(p.createdAt)).toList();
    final photos = mine.fold<int>(0, (n, p) => n + p.mediaRefs.length);
    final comments = feed.posts.fold<int>(0, (n, p) => n + p.comments.where((c) => c.authorId == me && thisYear(c.createdAt)).length);
    final reactionsGot = mine.fold<int>(0, (n, p) => n + p.reactions.length);
    var messages = 0;
    for (final thread in chat.conversations.values) {
      messages += thread.where((m) => m.senderId == me && thisYear(m.timestamp)).length;
    }
    for (final s in spheres.spheres) {
      messages += sphereChat.messagesIn(s.id).where((m) => m.senderId == me && thisYear(m.timestamp)).length;
    }
    final newContacts = contacts.contacts.where((c) => thisYear(c.addedAt)).length;
    final newSpheres = spheres.spheres.where((s) => thisYear(s.createdAt)).length;
    final callLog = calls.callLog.where((c) => thisYear(DateTime.tryParse('${c['at']}') ?? DateTime(1970))).toList();
    final callMinutes = callLog.fold<int>(0, (n, c) => n + ((c['seconds'] as int?) ?? 0)) ~/ 60;
    final events = mine.where((p) => p.isEvent).length;
    final stories = feed.storyArchive.where((p) => thisYear(p.createdAt)).length;

    final theme = Theme.of(context);
    final rows = <(IconData, String, String)>[
      (Icons.article_outlined, '${mine.length}', 'posts written'),
      (Icons.photo_outlined, '$photos', 'photos and clips shared'),
      (Icons.auto_stories_outlined, '$stories', 'stories told'),
      (Icons.mode_comment_outlined, '$comments', 'comments left'),
      (Icons.favorite_outline, '$reactionsGot', 'reactions received on your posts'),
      (Icons.chat_bubble_outline, '$messages', 'messages sent'),
      (Icons.call_outlined, '${callLog.length}', 'calls, $callMinutes minutes in all'),
      (Icons.person_add_alt_1_outlined, '$newContacts', 'new contacts'),
      (Icons.bubble_chart_outlined, '$newSpheres', 'spheres started'),
      (Icons.event_outlined, '$events', 'events made'),
    ];
    return Scaffold(
      appBar: AppBar(title: Text('$year so far')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Counted on this device, from what it holds. Nothing here leaves it.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          for (final (icon, n, label) in rows)
            ListTile(
              leading: Icon(icon, color: theme.colorScheme.primary),
              title: Text(n, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              subtitle: Text(label),
            ),
        ],
      ),
    );
  }
}
