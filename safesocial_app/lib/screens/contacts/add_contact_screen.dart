import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/contact_service.dart';
import '../../services/identity_service.dart';

/// Screen for adding a new contact by exchanging public keys.
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _formKey = GlobalKey<FormState>();
  final _publicKeyController = TextEditingController();
  final _displayNameController = TextEditingController();

  @override
  void dispose() {
    _publicKeyController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _addContact() async {
    if (!_formKey.currentState!.validate()) return;

    await context.read<ContactService>().addContact(
          _publicKeyController.text.trim(),
          _displayNameController.text.trim(),
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact added')),
      );
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final identityService = context.watch<IdentityService>();
    final myPublicKey = identityService.publicKey ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Contact'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Your public key section
              Text(
                'Your Public Key',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colorScheme.primary.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        myPublicKey,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.copy,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: myPublicKey));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Public key copied'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      tooltip: 'Copy key',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Share this key with others so they can add you.',
                style: theme.textTheme.bodySmall,
              ),

              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 32),

              // Add someone else's key
              Text(
                'Add Someone',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _publicKeyController,
                decoration: const InputDecoration(
                  labelText: 'Their Public Key',
                  hintText: 'Paste their public key here',
                  prefixIcon: Icon(Icons.key),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a public key';
                  }
                  if (value.trim().length < 10) {
                    return 'That key looks too short';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 16),

              TextFormField(
                controller: _displayNameController,
                decoration: const InputDecoration(
                  labelText: 'Display Name',
                  hintText: 'What should you call them?',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                textCapitalization: TextCapitalization.words,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a name';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 24),

              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _addContact,
                  icon: const Icon(Icons.person_add),
                  label: const Text('Add Contact'),
                ),
              ),

              const SizedBox(height: 24),

              // Future: QR code
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.qr_code,
                      color: colorScheme.onSurface.withOpacity(0.4),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'QR code scanning coming soon.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface.withOpacity(0.4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
