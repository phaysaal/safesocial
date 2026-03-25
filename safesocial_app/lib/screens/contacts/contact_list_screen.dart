import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/contact_service.dart';
import '../../widgets/avatar.dart';

/// Displays the user's contact list with swipe-to-delete/block.
class ContactListScreen extends StatelessWidget {
  const ContactListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final contactService = context.watch<ContactService>();
    final contacts = contactService.contacts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
      ),
      body: contacts.isEmpty
          ? _buildEmptyState(theme)
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: contacts.length,
              separatorBuilder: (_, __) => Divider(
                indent: 72,
                height: 1,
                color: theme.dividerTheme.color,
              ),
              itemBuilder: (context, index) {
                final contact = contacts[index];

                return Dismissible(
                  key: ValueKey(contact.publicKey),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    color: colorScheme.error,
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) async {
                    return await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Remove Contact'),
                        content: Text(
                          'Remove ${contact.displayName} from your contacts?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(
                              'Remove',
                              style: TextStyle(color: colorScheme.error),
                            ),
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
                    subtitle: contact.nickname != null
                        ? Text(contact.nickname!)
                        : Text(
                            _truncateKey(contact.publicKey),
                            style: theme.textTheme.bodySmall,
                          ),
                    trailing: contact.blocked
                        ? Icon(
                            Icons.block,
                            color: colorScheme.error,
                            size: 20,
                          )
                        : null,
                    onTap: () => context.push('/chat/${contact.publicKey}'),
                    onLongPress: () {
                      _showContactOptions(context, contactService, contact);
                    },
                  ),
                );
              },
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
              color: theme.colorScheme.primary.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No contacts yet',
              style: theme.textTheme.headlineMedium?.copyWith(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(
              'Share your public key to connect.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  void _showContactOptions(
    BuildContext context,
    ContactService contactService,
    dynamic contact,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                contact.blocked ? Icons.check_circle : Icons.block,
                color: contact.blocked ? colorScheme.primary : colorScheme.error,
              ),
              title: Text(
                contact.blocked ? 'Unblock' : 'Block',
              ),
              onTap: () {
                contactService.toggleBlock(contact.publicKey);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: colorScheme.error),
              title: const Text('Remove'),
              onTap: () {
                contactService.removeContact(contact.publicKey);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _truncateKey(String key) {
    if (key.length <= 12) return key;
    return '${key.substring(0, 6)}...${key.substring(key.length - 4)}';
  }
}
