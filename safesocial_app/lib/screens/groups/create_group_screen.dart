import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/contact.dart';
import '../../services/contact_service.dart';
import '../../services/group_service.dart';
import '../../services/identity_service.dart';
import '../../widgets/avatar.dart';

/// Full-screen form for creating a new group.
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final Set<String> _selectedContactKeys = {};
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _creating = true);

    final identityService = context.read<IdentityService>();
    final groupService = context.read<GroupService>();
    final contactService = context.read<ContactService>();

    final publicKey = identityService.publicKey ?? '';
    final displayName =
        identityService.currentIdentity?.displayName ?? 'Unknown';

    await groupService.createGroup(
      _nameController.text.trim(),
      _descriptionController.text.trim(),
      publicKey: publicKey,
      displayName: displayName,
    );

    // The newly created group is the last in the list.
    final newGroup = groupService.groups.last;

    // Add selected contacts as members.
    for (final key in _selectedContactKeys) {
      final contact = contactService.getContact(key);
      if (contact != null) {
        await groupService.addMember(
          newGroup.dhtKey,
          contact.publicKey,
          contact.displayName,
        );
      }
    }

    if (mounted) {
      context.go('/group/${newGroup.dhtKey}');
    }
  }

  void _toggleContact(String publicKey) {
    setState(() {
      if (_selectedContactKeys.contains(publicKey)) {
        _selectedContactKeys.remove(publicKey);
      } else {
        _selectedContactKeys.add(publicKey);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final contacts = context.watch<ContactService>().contacts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Group'),
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Group name field
                  TextFormField(
                    controller: _nameController,
                    maxLength: 50,
                    decoration: InputDecoration(
                      labelText: 'Group name',
                      hintText: 'Enter a group name',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    textCapitalization: TextCapitalization.words,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Group name is required';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Description field
                  TextFormField(
                    controller: _descriptionController,
                    maxLength: 200,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: 'Description (optional)',
                      hintText: 'What is this group about?',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                  const SizedBox(height: 24),

                  // Selected members chips
                  if (_selectedContactKeys.isNotEmpty) ...[
                    Text(
                      'Selected members',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurface.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: _selectedContactKeys.map((key) {
                        final contact =
                            context.read<ContactService>().getContact(key);
                        return Chip(
                          avatar: UserAvatar(
                            displayName: contact?.displayName ?? '',
                            size: AvatarSize.small,
                          ),
                          label: Text(contact?.displayName ?? key),
                          onDeleted: () => _toggleContact(key),
                          deleteIconColor:
                              colorScheme.onSurface.withOpacity(0.5),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Add Members section
                  Text(
                    'Add Members',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                  const SizedBox(height: 8),

                  if (contacts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No contacts yet. You can add members later.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  else
                    ...contacts.map((contact) => _buildContactTile(
                          contact,
                          theme,
                          colorScheme,
                        )),
                ],
              ),
            ),

            // Create button
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _creating ? null : _createGroup,
                  child: _creating
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactTile(
    Contact contact,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final selected = _selectedContactKeys.contains(contact.publicKey);

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
      contentPadding: EdgeInsets.zero,
    );
  }
}
