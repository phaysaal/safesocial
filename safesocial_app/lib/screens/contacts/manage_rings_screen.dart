import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/ring.dart';
import '../../services/ring_service.dart';
import '../../services/contact_service.dart';
import '../../widgets/avatar.dart';

/// Screen to manage client-side audience rings.
class ManageRingsScreen extends StatelessWidget {
  const ManageRingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ringService = context.watch<RingService>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Rings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _showCreateRingDialog(context, ringService),
          ),
        ],
      ),
      body: ringService.rings.isEmpty
          ? const Center(child: Text('No rings created yet.'))
          : ListView.builder(
              itemCount: ringService.rings.length,
              itemBuilder: (context, index) {
                final ring = ringService.rings[index];
                return _RingTile(ring: ring);
              },
            ),
    );
  }

  void _showCreateRingDialog(BuildContext context, RingService service) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create New Ring'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Ring Name', hintText: 'e.g. Close Friends'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                service.createRing(name, Colors.blue);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

class _RingTile extends StatelessWidget {
  final Ring ring;
  const _RingTile({required this.ring});

  @override
  Widget build(BuildContext context) {
    final contactService = context.watch<ContactService>();
    final ringService = context.read<RingService>();

    return ExpansionTile(
      leading: CircleAvatar(backgroundColor: ring.color, radius: 12),
      title: Text(ring.name, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text('${ring.memberPublicKeys.length} members'),
      trailing: PopupMenuButton<String>(
        onSelected: (val) {
          if (val == 'delete') ringService.deleteRing(ring.id);
        },
        itemBuilder: (ctx) => [
          const PopupMenuItem(value: 'delete', child: Text('Delete Ring', style: TextStyle(color: Colors.red))),
        ],
      ),
      children: [
        ...ring.memberPublicKeys.map((key) {
          final contact = contactService.getContact(key);
          return ListTile(
            dense: true,
            leading: UserAvatar(displayName: contact?.displayName ?? '?', size: AvatarSize.small),
            title: Text(contact?.displayName ?? key),
            trailing: IconButton(
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              onPressed: () => ringService.removeContactFromRing(ring.id, key),
            ),
          );
        }),
        ListTile(
          leading: const Icon(Icons.person_add_outlined, size: 20),
          title: const Text('Add Member', style: TextStyle(fontSize: 13)),
          onTap: () => _showAddMemberDialog(context, ringService, contactService),
        ),
      ],
    );
  }

  void _showAddMemberDialog(BuildContext context, RingService ringService, ContactService contactService) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        final availableContacts = contactService.contacts
            .where((c) => !ring.memberPublicKeys.contains(c.publicKey))
            .toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('Add to ${ring.name}', style: Theme.of(context).textTheme.titleMedium),
            ),
            Expanded(
              child: availableContacts.isEmpty
                  ? const Center(child: Text('No more contacts to add.'))
                  : ListView.builder(
                      itemCount: availableContacts.length,
                      itemBuilder: (ctx, i) {
                        final c = availableContacts[i];
                        return ListTile(
                          leading: UserAvatar(displayName: c.displayName, size: AvatarSize.small),
                          title: Text(c.displayName),
                          onTap: () {
                            ringService.addContactToRing(ring.id, c.publicKey);
                            Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
