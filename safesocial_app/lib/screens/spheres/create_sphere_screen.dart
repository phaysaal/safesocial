import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../services/contact_service.dart';
import '../../services/sphere_service.dart';

/// Create a sphere and choose who is in it.
class CreateSphereScreen extends StatefulWidget {
  const CreateSphereScreen({super.key});

  @override
  State<CreateSphereScreen> createState() => _CreateSphereScreenState();
}

class _CreateSphereScreenState extends State<CreateSphereScreen> {
  final _nameController = TextEditingController();
  final _selected = <String>{};
  SphereKind _kind = SphereKind.group;
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give the sphere a name')),
      );
      return;
    }

    setState(() => _creating = true);
    try {
      await context.read<SphereService>().create(
            name: name,
            kind: _kind,
            initialMembers: _selected.toList(),
          );
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not create: $e')));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final contacts = context.watch<ContactService>().contacts
        .where((c) => !c.blocked)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('New Sphere'),
        actions: [
          TextButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Family, Climbing, Book club',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          SegmentedButton<SphereKind>(
            segments: const [
              ButtonSegment(
                value: SphereKind.group,
                icon: Icon(Icons.group_outlined),
                label: Text('Everyone posts'),
              ),
              ButtonSegment(
                value: SphereKind.broadcast,
                icon: Icon(Icons.campaign_outlined),
                label: Text('Admins post'),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            'Both are private to their members. There is no public option — '
            'content that is not addressed to a sphere cannot be created.',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Text('Members', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'You can add people later. They will be asked before joining.',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          if (contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No contacts yet. Create the sphere now and invite people once '
                'you have added them.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            )
          else
            ...contacts.map((contact) {
              final canEncrypt = contact.keyExchangePublicKey != null;
              return CheckboxListTile(
                value: _selected.contains(contact.publicKey),
                title: Text(contact.displayName),
                subtitle: canEncrypt
                    ? null
                    : const Text(
                        'No encryption key yet — they will be added but cannot '
                        'receive anything until they come online',
                        style: TextStyle(fontSize: 11),
                      ),
                isThreeLine: !canEncrypt,
                onChanged: (checked) => setState(() {
                  if (checked == true) {
                    _selected.add(contact.publicKey);
                  } else {
                    _selected.remove(contact.publicKey);
                  }
                }),
              );
            }),
        ],
      ),
    );
  }
}
