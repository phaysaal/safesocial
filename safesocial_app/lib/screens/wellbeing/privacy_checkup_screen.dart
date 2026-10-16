import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/profile_about.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/library_service.dart';
import '../../services/notification_service.dart';
import '../../services/sphere_service.dart';

/// A walk through the choices that decide who sees and learns what, each
/// with its current value and a way to change it. Nothing here is a score;
/// it is the settings, in one place, in plain words.
class PrivacyCheckupScreen extends StatelessWidget {
  const PrivacyCheckupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<IdentityService>();
    final profile = identity.currentIdentity;
    final chat = context.watch<ChatService>();
    final feed = context.watch<FeedService>();
    final library = context.watch<LibraryService>();
    final contacts = context.watch<ContactService>();
    final spheres = context.watch<SphereService>();
    final notifications = context.watch<NotificationService>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final onlyMe = profile == null
        ? 0
        : profile.audience.values.where((a) => a.isMe).length;
    final toSpheres = profile == null
        ? 0
        : profile.audience.values.where((a) => a.isSpheres).length;
    final verified = contacts.contacts.where((c) => c.verifiedFingerprint != null).length;
    final unverified = contacts.contacts.length - verified;

    Widget step(IconData icon, String title, String value, String route, {String? note}) => Card(
          child: ListTile(
            leading: Icon(icon, color: cs.primary),
            title: Text(title),
            subtitle: Text(note == null ? value : '$value\n$note'),
            isThreeLine: note != null,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push(route),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy checkup')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Nothing in Spheres is public, and the relay cannot read anything. These are the choices that remain yours.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          step(
            Icons.badge_outlined,
            'Who sees which part of your profile',
            '${ProfileField.all.length} fields: $onlyMe only you, $toSpheres limited to named spheres, the rest to every contact.',
            '/profile/edit',
            note: 'Each field has an audience. "View as" on your profile shows what one contact gets.',
          ),
          step(
            Icons.verified_user_outlined,
            'Who you have verified',
            '$verified of ${contacts.contacts.length} contacts verified, $unverified not yet.',
            '/contacts',
            note: 'Comparing safety numbers in person rules out a relay in the middle.',
          ),
          step(
            Icons.done_all,
            'Read receipts and typing',
            'Read receipts ${chat.sendReadReceipts ? 'on' : 'off'}, typing ${chat.sendTypingSignals ? 'on' : 'off'}, flash views ${feed.sendViewReceipts ? 'on' : 'off'}.',
            '/settings',
          ),
          step(
            Icons.lock_outline,
            'Lock',
            'App lock ${library.appLock ? 'on' : 'off'}; ${library.lockedChatCount} locked chat${library.lockedChatCount == 1 ? '' : 's'}.',
            '/settings',
          ),
          step(
            Icons.notifications_outlined,
            'Notifications',
            notifications.preview ? 'Previews show the text on the lock screen.' : 'Previews hidden; only "New message" shows.',
            '/notifications',
          ),
          step(
            Icons.bubble_chart_outlined,
            'Your spheres',
            '${spheres.spheres.length} sphere${spheres.spheres.length == 1 ? '' : 's'}; every post goes to the members of one, never further.',
            '/spheres',
          ),
          step(
            Icons.backup_outlined,
            'Backup and recovery',
            'A passphrase backup and social recovery are the only ways back if this device is lost.',
            '/settings/recovery',
          ),
          step(
            Icons.self_improvement,
            'Your time here',
            'Breaks ${context.watch<LibraryService>().dataSaver ? '' : ''}and quiet hours live on the time page.',
            '/wellbeing',
          ),
        ],
      ),
    );
  }
}
