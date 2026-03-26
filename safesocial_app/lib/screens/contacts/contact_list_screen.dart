import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/friend_request.dart';
import '../../services/contact_service.dart';
import '../../widgets/avatar.dart';

/// Displays contacts and pending friend requests.
class ContactListScreen extends StatelessWidget {
  const ContactListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final contactService = context.watch<ContactService>();
    final contacts = contactService.contacts;
    final pendingIn = contactService.pendingIncoming;
    final pendingOut = contactService.pendingOutgoing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_outlined),
            tooltip: 'Groups',
            onPressed: () => context.push('/groups'),
          ),
        ],
      ),
      body: (contacts.isEmpty && pendingIn.isEmpty && pendingOut.isEmpty)
          ? _buildEmptyState(theme)
          : ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                // ── Incoming friend requests ──────────────
                if (pendingIn.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'FRIEND REQUESTS',
                      style: TextStyle(
                        color: cs.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  for (final req in pendingIn)
                    _FriendRequestTile(request: req),
                  const Divider(height: 24),
                ],

                // ── Pending outgoing requests ────────────
                if (pendingOut.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      'SENT REQUESTS',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  for (final req in pendingOut)
                    ListTile(
                      leading: UserAvatar(
                        displayName: req.toPublicKey.substring(0, 6),
                        size: AvatarSize.medium,
                      ),
                      title: Text(
                        req.toPublicKey.length > 16
                            ? '${req.toPublicKey.substring(0, 8)}...${req.toPublicKey.substring(req.toPublicKey.length - 6)}'
                            : req.toPublicKey,
                        style: theme.textTheme.bodyMedium,
                      ),
                      subtitle: Text(
                        'Waiting for acceptance',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      trailing: Icon(Icons.hourglass_top, size: 18, color: cs.onSurfaceVariant),
                    ),
                  const Divider(height: 24),
                ],

                // ── Confirmed contacts ───────────────────
                if (contacts.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      'CONTACTS (${contacts.length})',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                for (final contact in contacts)
                  Dismissible(
                    key: ValueKey(contact.publicKey),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      color: cs.error,
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    confirmDismiss: (_) async {
                      return await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Remove Contact'),
                          content: Text(
                            'Remove ${contact.displayName} from your contacts?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text('Remove',
                                  style: TextStyle(color: cs.error)),
                            ),
                          ],
                        ),
                      );
                    },
                    onDismissed: (_) {
                      contactService.removeContact(contact.publicKey);
                    },
                    child: ListTile(
                      leading: UserAvatar(
                        displayName: contact.displayName,
                        size: AvatarSize.medium,
                      ),
                      title: Text(
                        contact.displayName,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        contact.nickname ??
                            (contact.publicKey.length > 16
                                ? '${contact.publicKey.substring(0, 8)}...${contact.publicKey.substring(contact.publicKey.length - 6)}'
                                : contact.publicKey),
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (contact.closeFriend)
                            Icon(Icons.star, size: 16, color: Colors.green[600]),
                          if (contact.blocked)
                            Icon(Icons.block, size: 16, color: cs.error),
                          if (contact.muted)
                            Icon(Icons.volume_off, size: 16, color: cs.onSurfaceVariant),
                        ],
                      ),
                      onTap: () => context.push('/chat/${contact.publicKey}'),
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/contacts/add'),
        tooltip: 'Add contact',
        child: const Icon(Icons.person_add),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.people_outline,
              size: 64,
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No contacts yet',
              style: theme.textTheme.headlineMedium?.copyWith(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Add someone by scanning their QR code or sharing yours.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A tile for an incoming friend request with Accept/Reject buttons.
class _FriendRequestTile extends StatelessWidget {
  final FriendRequest request;

  const _FriendRequestTile({required this.request});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          UserAvatar(
            displayName: request.fromDisplayName.isNotEmpty
                ? request.fromDisplayName
                : request.fromPublicKey.substring(0, 6),
            size: AvatarSize.medium,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.fromDisplayName.isNotEmpty
                      ? request.fromDisplayName
                      : 'Unknown',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text('wants to connect', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              context.read<ContactService>().acceptFriendRequest(request.id);
            },
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              minimumSize: Size.zero,
            ),
            child: const Text('Accept'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () {
              context.read<ContactService>().rejectFriendRequest(request.id);
            },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: Size.zero,
            ),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }
}
