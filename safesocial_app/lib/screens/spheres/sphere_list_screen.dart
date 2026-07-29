import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../services/contact_service.dart';
import '../../services/sphere_service.dart';

/// The spheres you belong to, and invitations waiting on you.
class SphereListScreen extends StatelessWidget {
  const SphereListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sphereService = context.watch<SphereService>();
    final spheres = sphereService.spheres;
    final invites = sphereService.invites;

    return Scaffold(
      appBar: AppBar(title: const Text('Spheres')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/spheres/create'),
        icon: const Icon(Icons.add),
        label: const Text('New Sphere'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          if (invites.isNotEmpty) ...[
            _Header(title: 'Invitations'),
            ...invites.map((invite) => _InviteTile(invite: invite)),
            const Divider(),
          ],
          if (spheres.isEmpty && invites.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 64, 24, 24),
              child: Column(
                children: [
                  Icon(Icons.blur_on, size: 56, color: cs.onSurfaceVariant),
                  const SizedBox(height: 16),
                  Text(
                    'Everything lives in a sphere',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A sphere is a named group of people. Posts, chats and '
                    'photos belong to one — there is no public audience.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          else ...[
            if (spheres.isNotEmpty) _Header(title: 'Your spheres'),
            ...spheres.map((sphere) => _SphereTile(sphere: sphere)),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  const _Header({required this.title});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
      );
}

class _SphereTile extends StatelessWidget {
  final Sphere sphere;
  const _SphereTile({required this.sphere});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sphereService = context.watch<SphereService>();

    // Without the current epoch key we can read history but not publish —
    // usually because a rotation has not reached us yet.
    final canPost = sphereService.keyring.hasKey(sphere.id, sphere.epoch);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: cs.primaryContainer,
        child: Icon(_iconFor(sphere.kind), color: cs.onPrimaryContainer),
      ),
      title: Text(sphere.name),
      subtitle: Text(
        '${sphere.members.length} member${sphere.members.length == 1 ? '' : 's'}'
        '${canPost ? '' : ' · waiting for key'}',
      ),
      trailing: canPost ? null : Icon(Icons.hourglass_empty, size: 18, color: cs.outline),
      onTap: () => context.push('/sphere/${sphere.id}'),
    );
  }

  static IconData _iconFor(SphereKind kind) => switch (kind) {
        SphereKind.direct => Icons.person_outline,
        SphereKind.group => Icons.group_outlined,
        SphereKind.broadcast => Icons.campaign_outlined,
      };
}

class _InviteTile extends StatelessWidget {
  final PendingInvite invite;
  const _InviteTile({required this.invite});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final contacts = context.watch<ContactService>();
    final inviterName = contacts
            .contacts
            .where((c) => c.publicKey == invite.invitedBy)
            .map((c) => c.displayName)
            .followedBy(['someone you know']).first;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: cs.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(invite.sphere.name,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              '$inviterName invited you · ${invite.sphere.members.length} members',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => context
                      .read<SphereService>()
                      .declineInvite(invite.sphere.id),
                  child: const Text('Decline'),
                ),
                FilledButton(
                  onPressed: () => context
                      .read<SphereService>()
                      .acceptInvite(invite.sphere.id),
                  child: const Text('Join'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
