import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/call_service.dart';
import '../../services/debug_log_service.dart';

/// Screen to add a new contact via QR code scan or public key input.
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _keyController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isScanning = false;
  bool _isProcessing = false;

  @override
  void dispose() {
    _keyController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _addContact() async {
    final publicKey = _keyController.text.trim();
    final name = _nameController.text.trim();

    if (publicKey.isEmpty || name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both name and public key')),
      );
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final contactService = context.read<ContactService>();
      final chatService = context.read<ChatService>();
      final identityService = context.read<IdentityService>();
      final myKey = identityService.publicKey;

      // 1. Add to contact list
      await contactService.addContact(publicKey, name);

      // 2. Initialize signaling and relay
      if (myKey != null) {
        final callService = context.read<CallService>();
        callService.connectSignaling(publicKey);
        chatService.connectRelay(publicKey);
      }

      // 3. Create conversation entry
      await chatService.createConversation(publicKey);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added $name to contacts')),
        );
        context.pop();
      }
    } catch (e) {
      DebugLogService().error('Contacts', 'Failed to add contact: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Contact'),
      ),
      body: _isScanning ? _buildScanner() : _buildForm(theme, cs),
    );
  }

  Widget _buildForm(ThemeData theme, ColorScheme cs) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.person_add_outlined, size: 48, color: cs.primary),
          ),
        ),
        const SizedBox(height: 32),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Display Name',
            prefixIcon: Icon(Icons.badge_outlined),
            hintText: 'e.g. Alice',
          ),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _keyController,
          decoration: InputDecoration(
            labelText: 'Public Key',
            prefixIcon: const Icon(Icons.vpn_key_outlined),
            suffixIcon: IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: () => setState(() => _isScanning = true),
            ),
            hintText: 'Paste Ed25519 public key',
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        const SizedBox(height: 40),
        SizedBox(
          height: 54,
          child: ElevatedButton(
            onPressed: _isProcessing ? null : _addContact,
            child: _isProcessing
                ? const CircularProgressIndicator()
                : const Text('Add Contact', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            final List<Barcode> barcodes = capture.barcodes;
            for (final barcode in barcodes) {
              final rawValue = barcode.rawValue;
              if (rawValue != null) {
                setState(() {
                  _keyController.text = rawValue;
                  _isScanning = false;
                });
                break;
              }
            }
          },
        ),
        Positioned(
          top: 20,
          left: 20,
          child: CircleAvatar(
            backgroundColor: Colors.black54,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => setState(() => _isScanning = false),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ],
    );
  }
}
