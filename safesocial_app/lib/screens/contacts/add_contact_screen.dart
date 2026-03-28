import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/call_service.dart';
import '../../services/chat_service.dart';
import '../../services/contact_service.dart';
import '../../services/identity_service.dart';

/// Two-step contact exchange:
/// 1. Person A shows their QR code
/// 2. Person B scans it → B adds A + creates a conversation DHT record
///    → B's QR code now includes the conversation key
/// 3. A scans B's QR → A adds B + joins the conversation
/// Both can now message each other through the shared DHT record.
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _formKey = GlobalKey<FormState>();
  final _publicKeyController = TextEditingController();
  final _displayNameController = TextEditingController();

  // After scanning someone, we store the conversation key to include
  // in our own QR code so they can join the conversation.
  String? _lastCreatedConversationKey;
  String? _lastAddedContactName;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _publicKeyController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _addContact() async {
    if (!_formKey.currentState!.validate()) return;

    final publicKey = _publicKeyController.text.trim();
    final displayName = _displayNameController.text.trim();

    await _addContactAndCreateConversation(publicKey, displayName, null);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$displayName added! Now ask them to scan your QR code.')),
      );
    }
  }

  /// Core logic: add contact + create/join conversation DHT record.
  Future<void> _addContactAndCreateConversation(
    String publicKey,
    String displayName,
    String? conversationDhtKey,
  ) async {
    final contactService = context.read<ContactService>();
    final chatService = context.read<ChatService>();
    final identityService = context.read<IdentityService>();

    // Add as contact
    await contactService.addContact(publicKey, displayName);

    // Ensure relay has our public key (critical for fresh installs)
    final myKey = identityService.publicKey;
    if (myKey != null && myKey.isNotEmpty) {
      chatService.setMyPublicKey(myKey);
    }

    // Connect relay for instant messaging fallback
    chatService.connectRelay(publicKey);

    // Connect call signaling
    try {
      final callService = context.read<CallService>();
      if (myKey != null) {
        callService.setMyPublicKey(myKey);
      }
      callService.connectSignaling(publicKey);
    } catch (_) {}

    if (conversationDhtKey != null && conversationDhtKey.isNotEmpty) {
      // They already created a conversation — join it with our writer keypair
      try {
        await chatService.joinConversationByString(
          publicKey,
          conversationDhtKey,
          writerKeypair: identityService.keypair,
        );
        debugPrint('[AddContact] Joined existing conversation: $conversationDhtKey');
      } catch (e) {
        debugPrint('[AddContact] Failed to join conversation: $e');
      }
    } else {
      // We're the first to scan — create a new conversation
      final keypair = identityService.keypair;
      final key = await chatService.createConversation(publicKey, keypair);
      if (key != null) {
        _lastCreatedConversationKey = key.toString();
        debugPrint('[AddContact] Created conversation: $_lastCreatedConversationKey');
      }
    }

    setState(() {
      _lastAddedContactName = displayName;
    });
  }

  void _handleQrScan(String data) {
    try {
      final decoded = utf8.decode(base64Decode(data));
      final payload = jsonDecode(decoded) as Map<String, dynamic>;
      final publicKey = payload['public_key'] as String?;
      final conversationKey = payload['conversation_key'] as String?;

      if (publicKey != null && publicKey.isNotEmpty) {
        _showAddFromQrDialog(publicKey, conversationKey);
        return;
      }
    } catch (_) {}

    // Fallback: treat raw string as public key
    if (data.length >= 10) {
      _showAddFromQrDialog(data, null);
    }
  }

  void _showAddFromQrDialog(String publicKey, String? conversationKey) {
    final nameController = TextEditingController();
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Key found:', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              publicKey.length > 24
                  ? '${publicKey.substring(0, 12)}...${publicKey.substring(publicKey.length - 8)}'
                  : publicKey,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
            if (conversationKey != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.link, size: 14, color: Colors.green[600]),
                  const SizedBox(width: 4),
                  Text('Conversation link included',
                      style: TextStyle(fontSize: 12, color: Colors.green[600])),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                hintText: 'What should you call them?',
              ),
              textCapitalization: TextCapitalization.words,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;

              Navigator.pop(ctx);

              await _addContactAndCreateConversation(
                publicKey, name, conversationKey,
              );

              if (mounted) {
                if (conversationKey != null) {
                  // Both sides connected — ready to chat
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Connected with $name! You can now chat.')),
                  );
                  context.pop(); // Go back to contacts
                } else {
                  // We scanned first — tell them to scan us back
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('$name added! Now show them YOUR QR code to complete the connection.'),
                      duration: const Duration(seconds: 4),
                    ),
                  );
                  // Switch to "My QR Code" tab
                  _tabController.animateTo(0);
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  /// Build the exchange payload QR data.
  /// Includes conversation key if we've already created one.
  String _buildQrData() {
    final identityService = context.read<IdentityService>();
    final payload = <String, dynamic>{
      'public_key': identityService.publicKey ?? '',
      'profile_dht_key': identityService.profileDhtKey?.toString() ?? '',
    };

    // Include conversation key if we just created one
    if (_lastCreatedConversationKey != null) {
      payload['conversation_key'] = _lastCreatedConversationKey;
    }

    return base64Encode(utf8.encode(jsonEncode(payload)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final identityService = context.watch<IdentityService>();
    final myPublicKey = identityService.publicKey ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Contact'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: cs.primary,
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurfaceVariant,
          tabs: const [
            Tab(icon: Icon(Icons.qr_code), text: 'My QR Code'),
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'Scan'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          // ── Tab 1: Show my QR code ──────────────────────
          SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 16),

                // Step indicator
                if (_lastAddedContactName != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'You added $_lastAddedContactName! Now ask them to scan this QR code to complete the connection.',
                            style: TextStyle(fontSize: 13, color: Colors.green[800]),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  Text(
                    'Your QR Code',
                    style: theme.textTheme.headlineMedium?.copyWith(fontSize: 20),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Let others scan this to add you as a contact.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                ],

                // QR code
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: _buildQrData(),
                    version: QrVersions.auto,
                    size: 220,
                    eyeStyle: QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: cs.primary,
                    ),
                    dataModuleStyle: QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: cs.onSurface,
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // How it works
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('How to connect:', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 8),
                      _StepRow(step: '1', text: 'One person scans the other\'s QR code'),
                      _StepRow(step: '2', text: 'Then the other person scans back'),
                      _StepRow(step: '3', text: 'Both are connected and can chat!'),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: myPublicKey));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Public key copied'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy Public Key'),
                ),

                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 24),

                // Manual add form
                Text('Or add manually', style: theme.textTheme.labelLarge),
                const SizedBox(height: 16),
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _publicKeyController,
                        decoration: const InputDecoration(
                          labelText: 'Their Public Key',
                          hintText: 'Paste their key here',
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
                      const SizedBox(height: 12),
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
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: _addContact,
                          icon: const Icon(Icons.person_add),
                          label: const Text('Add Contact'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Tab 2: QR Scanner ──────────────────────────
          _QrScannerTab(onScanned: _handleQrScan),
        ],
      ),
    );
  }
}

// ─── Step row ────────────────────────────────────────────────────────────────

class _StepRow extends StatelessWidget {
  final String step;
  final String text;

  const _StepRow({required this.step, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(step,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

// ─── QR Scanner Tab ──────────────────────────────────────────────────────────

class _QrScannerTab extends StatefulWidget {
  final void Function(String data) onScanned;

  const _QrScannerTab({required this.onScanned});

  @override
  State<_QrScannerTab> createState() => _QrScannerTabState();
}

class _QrScannerTabState extends State<_QrScannerTab> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _hasScanned = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      children: [
        const SizedBox(height: 16),
        Text(
          'Scan a QR Code',
          style: theme.textTheme.headlineMedium?.copyWith(fontSize: 20),
        ),
        const SizedBox(height: 8),
        Text(
          'Point your camera at a contact\'s QR code.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cs.primary, width: 2),
            ),
            child: MobileScanner(
              controller: _scannerController,
              onDetect: (capture) {
                if (_hasScanned) return;
                final barcode = capture.barcodes.firstOrNull;
                if (barcode?.rawValue != null) {
                  _hasScanned = true;
                  widget.onScanned(barcode!.rawValue!);
                  Future.delayed(const Duration(seconds: 3), () {
                    if (mounted) setState(() => _hasScanned = false);
                  });
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
