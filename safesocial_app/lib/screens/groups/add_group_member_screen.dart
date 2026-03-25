import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/contact.dart';
import '../../services/contact_service.dart';
import '../../services/group_service.dart';
import '../../widgets/avatar.dart';

/// Screen to add contacts as members to an existing group.
class AddGroupMemberScreen extends StatefulWidget {
  final String dhtKey;

  const AddGroupMemberScreen({super.key, required this.dhtKey});

  @override
  State<AddGroupMemberScreen> createState() => _AddGroupMemberScreenState();
}

class _AddGroupMemberScreenState extends State<AddGroupMemberScreen> {
  final Set<String> _selectedKeys = {};
  bool _adding = false;

  Future<void> _addSelected() async {
    if (_selectedKeys.isEmpty) return;

    setState(() => _adding = true);

    final groupService = context.read<GroupService>();
    final contactService = context.read<ContactService>();

    for (final key in _selectedKeys) {
      final contact = contactService.getContact(key);
      if (contact != null) {
        await groupService.addMember(
          widget.dhtKey,
          contact.publicKey,
          contact.displayName,
        );
      }
    }

    if (mounted) {
      context.pop();
    }
  }

  void _toggleContact(String publicKey) {
    setState(() {
      if (_selectedKeys.contains(publicKey)) {
        _selectedKeys.remove(publicKey);
      } else {
        _selectedKeys.add(publicKey);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final contactService = context.watch<ContactService>();
    final groupService = context.watch<GroupService>();

    final group = groupService.getGroup(widget.dhtKey);
    final existingKeys =
        group?.members.map((m) => m.publicKey).toSet() ?? <String>{};

    // Only show contacts not already in the group.
    final availableContacts = contactService.contacts
        .where((c) => !existingKeys.contains(c.publicKey))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Members'),
      ),
      body: Column(
        children: [
          Expanded(
            child: availableContacts.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.person_search_outlined,
                            size: 64,
                            color: colorScheme.primary.withOpacity(0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No contacts available to add',
                            style: theme.textTheme.headlineMedium
                                ?.copyWith(fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'All your contacts are already in this group, or you have no contacts yet.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: availableContacts.length,
                    itemBuilder: (context, index) {
                      final contact = availableContacts[index];
                      return _buildContactTile(
                        contact,
                        theme,
                        colorScheme,
                      );
                    },
                  ),
          ),

          // Add Selected button
          if (availableContacts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      _selectedKeys.isEmpty || _adding ? null : _addSelected,
                  child: _adding
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _selectedKeys.isEmpty
                              ? 'Select members to add'
                              : 'Add Selected (${_selectedKeys.length})',
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContactTile(
    Contact contact,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final selected = _selectedKeys.contains(contact.publicKey);

    return CheckboxListTile(
      value: selected,
      onChanged: (_) => _toggleContact(contact.publicKey),
      secondary: UserAvatar(
        displayName: contact.displayName,
        size: AvatarSize.medium,
      ),
      title: Text(
        contact.displayName,
        style: theme.textTheme.bodyLarge,
      ),
      activeColor: colorScheme.primary,
      controlAffinity: ListTileControlAffinity.trailing,
    );
  }
}
