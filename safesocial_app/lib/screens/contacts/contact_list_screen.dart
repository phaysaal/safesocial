import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/contact.dart';
import '../../models/contact_request.dart';
import '../../services/contact_service.dart';
import '../../widgets/avatar.dart';

/// Screen displaying the user's address book.
class ContactListScreen extends StatefulWidget {
  const ContactListScreen({super.key});

  @override
  State<ContactListScreen> createState() => _ContactListScreenState();
}

class _ContactListScreenState extends State<ContactListScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contactService = context.watch<ContactService>();
    final q = _query.trim().toLowerCase();
    final contacts = contactService.contacts
        .where((c) => q.isEmpty || c.displayName.toLowerCase().contains(q) || (c.nickname?.toLowerCase().contains(q) ?? false))
        .toList();
    // Requests sit above the address book: they are the thing waiting on you.
    final requests = contactService.requests;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Contacts',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Audience Rings',
            icon: const Icon(Icons.blur_circular),
            onPressed: () => context.push('/spheres'),
          ),
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            onPressed: () => context.push('/contacts/add'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search contacts',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: contacts.isEmpty && requests.isEmpty
                ? (q.isEmpty ? _buildEmptyState(theme) : const Center(child: Text('Nobody by that name')))
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: requests.length + contacts.length + (requests.isNotEmpty ? 1 : 0),
                    separatorBuilder: (context, index) => const SizedBox(height: 2),
                    itemBuilder: (context, index) {
                      if (requests.isNotEmpty && index == 0) {
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text('Waiting for you', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
                        );
                      }
                      final i = requests.isNotEmpty ? index - 1 : index;
                      if (i < requests.length) {
                        return _RequestTile(request: requests[i]);
                      }
                      return _ContactListTile(contact: contacts[i - requests.length]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.people_outline, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          const Text('Your address book is empty'),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {}, // Handled by FAB or App Router
            child: const Text('Add your first contact'),
          ),
        ],
      ),
    );
  }
}

class _ContactListTile extends StatelessWidget {
  final Contact contact;

  const _ContactListTile({required this.contact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final contactService = context.read<ContactService>();

    return ListTile(
      leading: InkWell(
        onTap: () => context.push('/contact/${contact.publicKey}'),
        borderRadius: BorderRadius.circular(24),
        child: UserAvatar(
          displayName: contact.displayName,
          imageRef: contact.avatarRef,
          size: AvatarSize.medium,
        ),
      ),
      title: Text(
        contact.displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: contact.isPending
          // Waiting on them, not on us — and it clears the moment they
          // approve, which the old label never did.
          ? Text('Waiting for them to approve',
              style: TextStyle(color: cs.secondary, fontSize: 12))
          : (contact.onBreak || contact.isSnoozed || contact.muted || contact.restricted)
              ? Text(
                  [
                    if (contact.onBreak) 'on a break',
                    if (contact.isSnoozed && !contact.onBreak) 'snoozed',
                    if (contact.muted) 'muted',
                    if (contact.restricted && !contact.onBreak) 'restricted',
                  ].join(' · '),
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12))
              : null,
      trailing: PopupMenuButton<String>(
        onSelected: (value) => _handleMenuAction(context, value, contactService),
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'profile',
            child: ListTile(
              leading: Icon(Icons.person_outline),
              title: Text('View profile'),
              dense: true,
            ),
          ),
          const PopupMenuItem(
            value: 'rename',
            child: ListTile(
              leading: Icon(Icons.edit_outlined),
              title: Text('Rename'),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'favourite',
            child: ListTile(
              leading: Icon(contact.favourite ? Icons.star : Icons.star_outline),
              title: Text(contact.favourite ? 'Remove from favourites' : 'Add to favourites'),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'snooze',
            child: ListTile(
              leading: const Icon(Icons.snooze_outlined),
              title: Text(contact.isSnoozed ? 'End snooze' : 'Snooze for 30 days'),
              subtitle: contact.isSnoozed
                  ? Text('Back on ${contact.snoozedUntil!.toLocal().toString().substring(0, 10)}')
                  : null,
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'restrict',
            child: ListTile(
              leading: Icon(contact.restricted ? Icons.lock_open_outlined : Icons.lock_outline),
              title: Text(contact.restricted ? 'Stop restricting' : 'Restrict'),
              subtitle: const Text('They get only your name and picture', style: TextStyle(fontSize: 11)),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'break',
            child: ListTile(
              leading: Icon(contact.onBreak ? Icons.play_arrow_outlined : Icons.pause_circle_outline),
              title: Text(contact.onBreak ? 'End the break' : 'Take a break'),
              subtitle: contact.onBreak
                  ? null
                  : const Text('Quiet and restricted until you end it', style: TextStyle(fontSize: 11)),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'block',
            child: ListTile(
              leading: Icon(contact.blocked ? Icons.check_circle_outline : Icons.block),
              title: Text(contact.blocked ? 'Unblock' : 'Block'),
              dense: true,
            ),
          ),
          const PopupMenuItem(
            value: 'share',
            child: ListTile(
              leading: Icon(Icons.share_outlined),
              title: Text('Share Contact'),
              dense: true,
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red),
              title: Text('Delete', style: TextStyle(color: Colors.red)),
              dense: true,
            ),
          ),
        ],
      ),
      onTap: () => context.push('/chat/${contact.publicKey}'),
    );
  }

  void _handleMenuAction(BuildContext context, String action, ContactService service) {
    switch (action) {
      case 'profile':
        context.push('/contact/${contact.publicKey}');
        break;
      case 'rename':
        _showRenameDialog(context, service);
        break;
      case 'favourite':
        service.setFavourite(contact.publicKey, !contact.favourite);
        break;
      case 'snooze':
        if (contact.isSnoozed) {
          service.unsnooze(contact.publicKey);
        } else {
          service.snooze(contact.publicKey);
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Quiet for 30 days, then back by themselves')));
        }
        break;
      case 'restrict':
        service.setRestricted(contact.publicKey, !contact.restricted);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(contact.restricted
                ? 'They get your full profile again'
                : 'They now get only your name and picture')));
        break;
      case 'break':
        service.setOnBreak(contact.publicKey, !contact.onBreak);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(contact.onBreak
                ? 'Break ended'
                : 'On a break: their posts leave your feed, they will not notify you, and they get only your name and picture')));
        break;
      case 'block':
        service.toggleBlock(contact.publicKey);
        break;
      case 'share':
        final link = 'spheres://add?key=${contact.publicKey}&name=${Uri.encodeComponent(contact.displayName)}';
        Clipboard.setData(ClipboardData(text: link));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invite link copied to clipboard')),
        );
        break;
      case 'delete':
        _showDeleteConfirm(context, service);
        break;
    }
  }

  void _showRenameDialog(BuildContext context, ContactService service) {
    final controller = TextEditingController(text: contact.displayName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Contact'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New Name'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                service.renameContact(contact.publicKey, newName);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirm(BuildContext context, ContactService service) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Contact'),
        content: Text('Are you sure you want to delete ${contact.displayName}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              service.removeContact(contact.publicKey);
              Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

/// Someone asking to connect, with the decision still yours.
class _RequestTile extends StatelessWidget {
  final ContactRequest request;
  const _RequestTile({required this.request});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final contacts = context.read<ContactService>();
    final messenger = ScaffoldMessenger.of(context);

    return Container(
      color: cs.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${request.displayName} would like to connect',
            style: TextStyle(
                color: cs.onSecondaryContainer, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            // The name is their claim, not a fact. The key is the identity.
            'They chose that name themselves. Their key starts '
            '${request.publicKey.substring(0, 8)}.',
            style: TextStyle(color: cs.onSecondaryContainer, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () async {
                  await contacts.declineRequest(request.publicKey);
                  messenger.showSnackBar(const SnackBar(
                    content: Text('Declined. They are not told, and they '
                        'cannot ask again.'),
                  ));
                },
                child: const Text('Decline'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => contacts.approveRequest(request.publicKey),
                child: const Text('Approve'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
