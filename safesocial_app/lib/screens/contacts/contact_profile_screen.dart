import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../widgets/profile_view.dart';

/// A contact's profile, exactly as they let us see it. Nothing here is
/// fetched: it is what their last profile message carried.
class ContactProfileScreen extends StatelessWidget {
  final String contactKey;

  const ContactProfileScreen({super.key, required this.contactKey});

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactService>();
    final contact =
        contacts.contacts.where((c) => c.publicKey == contactKey).firstOrNull;
    if (contact == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const Center(child: Text('Not a contact')),
      );
    }
    String? resolve(String key) => contacts.contacts
        .where((c) => c.publicKey == key)
        .map((c) => c.displayName)
        .firstOrNull;

    final feed = context.watch<FeedService>();
    final pinned = [
      for (final id in contact.pinnedPostIds) ...feed.posts.where((p) => p.id == id),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(contact.displayName)),
      body: ProfileView(
        data: ProfileData.contact(contact),
        resolveName: resolve,
        pinnedPosts: pinned,
        note: contact.namedMeLegacy
            ? '${contact.displayName} named you their legacy contact.'
            : null,
        actions: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => context.push('/chat/${contact.publicKey}'),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Message'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => context.push('/contact/${contact.publicKey}/verify'),
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: const Text('Verify'),
            ),
          ],
        ),
      ),
    );
  }
}
