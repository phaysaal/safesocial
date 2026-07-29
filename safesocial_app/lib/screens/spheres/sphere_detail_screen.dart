import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/sphere_service.dart';

/// Members and settings for one sphere.
class SphereDetailScreen extends StatelessWidget {
  final String sphereId;
  const SphereDetailScreen({super.key, required this.sphereId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sphereService = context.watch<SphereService>();
    final sphere = sphereService.sphere(sphereId);
    final me = context.watch<IdentityService>().publicKey;

    if (sphere == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This sphere is no longer available.')),
      );
    }

    final iAmAdmin = me != null && sphere.isAdmin(me);
    final contacts = context.watch<ContactService>();

    String nameFor(String key) {
      if (key == me) return 'You';
      for (final contact in contacts.contacts) {
        if (contact.publicKey == key) return contact.displayName;
      }
      return '${key.substring(0, 8)}…';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(sphere.name),
        actions: [
          if (iAmAdmin)
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              tooltip: 'Add member',
              onPressed: () => _showAddMember(context, sphere),
            ),
        ],
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              // Surfacing the epoch is deliberate: it is the thing that makes
              // removal real, and it explains why an old member stops seeing
              // new posts.
              'Membership version ${sphere.epoch} · '
              '${sphere.members.length} member${sphere.members.length == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const Divider(),
          ...sphere.members.map((member) {
            final isMe = member.identityKey == me;
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: cs.surfaceContainerHighest,
                child: Text(nameFor(member.identityKey).characters.first.toUpperCase()),
              ),
              title: Text(nameFor(member.identityKey)),
              subtitle: Text(member.isAdmin ? 'Admin' : 'Member'),
              trailing: (iAmAdmin && !isMe)
                  ? PopupMenuButton<String>(
                      onSelected: (action) =>
                          _onMemberAction(context, sphere, member, action),
                      itemBuilder: (_) => [
                        if (!member.isAdmin)
                          const PopupMenuItem(
                            value: 'promote',
                            child: Text('Make admin'),
                          ),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove from sphere'),
                        ),
                      ],
                    )
                  : null,
            );
          }),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: cs.error),
            title: Text('Leave sphere', style: TextStyle(color: cs.error)),
            subtitle: const Text('You will lose access to its content'),
            onTap: () => _confirmLeave(context, sphere),
          ),
        ],
      ),
    );
  }

  Future<void> _onMemberAction(
    BuildContext context,
    Sphere sphere,
    SphereMember member,
    String action,
  ) async {
    final service = context.read<SphereService>();
    final messenger = ScaffoldMessenger.of(context);

    try {
      if (action == 'promote') {
        await service.promote(sphere.id, member.identityKey);
      } else if (action == 'remove') {
        await service.removeMember(sphere.id, member.identityKey);
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Removed. They keep what they already had, but cannot read '
              'anything posted from now on.',
            ),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _showAddMember(BuildContext context, Sphere sphere) async {
    final contacts = context
        .read<ContactService>()
        .contacts
        .where((c) => !c.blocked && !sphere.contains(c.publicKey))
        .toList();

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Everyone you know is already in here')),
      );
      return;
    }

    final service = context.read<SphereService>();
    final messenger = ScaffoldMessenger.of(context);

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Add to sphere',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ...contacts.map((contact) => ListTile(
                  title: Text(contact.displayName),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    try {
                      await service.addMember(sphere.id, contact.publicKey);
                      messenger.showSnackBar(SnackBar(
                        content: Text(
                            '${contact.displayName} was invited and will be asked to join'),
                      ));
                    } catch (e) {
                      messenger
                          .showSnackBar(SnackBar(content: Text('Failed: $e')));
                    }
                  },
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLeave(BuildContext context, Sphere sphere) async {
    final service = context.read<SphereService>();
    final router = GoRouter.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Leave "${sphere.name}"?'),
        content: const Text(
          'Its keys are deleted from this device, so its content becomes '
          'unreadable here. This cannot be undone without being invited again.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await service.leave(sphere.id);
    router.pop();
  }
}
