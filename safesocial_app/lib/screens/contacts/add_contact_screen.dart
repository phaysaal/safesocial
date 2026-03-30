import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';
import '../../services/call_service.dart';
import '../../services/debug_log_service.dart';

/// Screen to add a new contact via QR code scan or public key input.
/// Also displays the user's own QR code for others to scan.
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _keyController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isScanning = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
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

      // 1. Add to contact list
      await contactService.addContact(publicKey, name);

      // 2. Initialize signaling and relay
      if (identityService.isOnboarded) {
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
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Scan or Add'),
            Tab(text: 'My QR Code'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _isScanning ? _buildScanner() : _buildForm(theme, cs),
          _buildMyQRCode(context),
        ],
      ),
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

  Widget _buildMyQRCode(BuildContext context) {
    final identity = context.watch<IdentityService>();
    final pubKey = identity.publicKey ?? '';
    final name = identity.currentIdentity?.displayName ?? 'User';
    final cs = Theme.of(context).colorScheme;

    final inviteLink = 'spheres://add?key=$pubKey&name=${Uri.encodeComponent(name)}';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const Text(
            'Show this code to a friend or share your invite link to connect.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 20,
                  spreadRadius: 5,
                ),
              ],
            ),
            child: QrImageView(
              data: inviteLink,
              version: QrVersions.auto,
              size: 240.0,
              eyeStyle: QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: cs.primary,
              ),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (pubKey.isNotEmpty)
            Text(
              pubKey.length > 20 ? pubKey.substring(0, 20) + '...' : pubKey,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, fontFamily: 'monospace'),
            ),
          const SizedBox(height: 40),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: inviteLink));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Invite link copied to clipboard')),
              );
            },
            icon: const Icon(Icons.share_outlined),
            label: const Text('Share Invite Link'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
            ),
          ),
        ],
      ),
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
                // Check if it's a spheres link
                if (rawValue.startsWith('spheres://add')) {
                  final uri = Uri.parse(rawValue);
                  final key = uri.queryParameters['key'];
                  final name = uri.queryParameters['name'];
                  if (key != null) {
                    setState(() {
                      _keyController.text = key;
                      if (name != null) _nameController.text = name;
                      _isScanning = false;
                    });
                    break;
                  }
                }
                
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
