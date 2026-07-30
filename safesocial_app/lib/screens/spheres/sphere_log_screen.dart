import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/sphere_event.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/sphere_service.dart';

/// Everything that has happened to a sphere's membership, visible to everyone
/// in it.
///
/// This is the substitute for an appeals process. Nobody here can adjudicate a
/// dispute, so the check on admin power is simply that admins act in the open:
/// every membership change is a signed operation that reaches every member
/// anyway, and this is where it is shown.
class SphereLogScreen extends StatelessWidget {
  final String sphereId;
  const SphereLogScreen({super.key, required this.sphereId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sphereService = context.watch<SphereService>();
    final sphere = sphereService.sphere(sphereId);
    final events = sphereService.eventsFor(sphereId);
    final me = context.watch<IdentityService>().publicKey;
    final contacts = context.watch<ContactService>();

    String nameFor(String key) {
      if (key.isEmpty) return 'someone';
      if (key == me) return 'You';
      for (final contact in contacts.contacts) {
        if (contact.publicKey == key) return contact.displayName;
      }
      return '${key.substring(0, 8)}…';
    }

    return Scaffold(
      appBar: AppBar(title: Text(sphere == null ? 'Activity' : sphere.name)),
      body: events.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Nothing has happened here yet.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            )
          : ListView.separated(
              itemCount: events.length + 1,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'What this device saw and applied. A member who was '
                      'offline for part of the sphere\'s life may hold a '
                      'different slice of it — there is no server keeping one '
                      'shared copy.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  );
                }

                final event = events[index - 1];
                return ListTile(
                  leading: Icon(_iconFor(event.op), color: cs.primary),
                  title: Text(_describe(event, nameFor)),
                  subtitle: Text(
                    '${_formatDate(event.at)} · membership version '
                    '${event.epoch}',
                    style: theme.textTheme.bodySmall,
                  ),
                );
              },
            ),
    );
  }

  static IconData _iconFor(String op) {
    switch (op) {
      case 'create':
        return Icons.auto_awesome_outlined;
      case 'add':
        return Icons.person_add_outlined;
      case 'remove':
        return Icons.person_remove_outlined;
      case 'leave':
        return Icons.logout;
      case 'promote':
        return Icons.shield_outlined;
      case 'demote':
        return Icons.remove_moderator_outlined;
      case 'transfer':
        return Icons.key_outlined;
      case 'transfer-offer':
        return Icons.mail_outline;
      case 'rename':
        return Icons.edit_outlined;
      default:
        return Icons.circle_outlined;
    }
  }

  static String _describe(SphereEvent e, String Function(String) nameFor) {
    final by = nameFor(e.by);
    final target = nameFor(e.target);

    switch (e.op) {
      case 'create':
        return '$by created the sphere';
      case 'add':
        return '$by invited $target';
      case 'remove':
        return '$by removed $target';
      case 'leave':
        return '$target left';
      case 'promote':
        return '$by made $target an admin';
      case 'demote':
        return e.by == e.target
            ? '$by stepped down as admin'
            : '$by took admin from $target';
      case 'transfer':
        return '$target became the owner';
      case 'transfer-offer':
        return '$by offered ownership to $target';
      case 'rename':
        return e.detail.isEmpty
            ? '$by changed the sphere details'
            : '$by renamed the sphere to "${e.detail}"';
      default:
        return '$by performed ${e.op}';
    }
  }

  static String _formatDate(DateTime at) {
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final time =
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    if (sameDay) return 'Today $time';
    return '${at.day}/${at.month}/${at.year} $time';
  }
}
