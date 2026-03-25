import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/contact_service.dart';
import '../../services/identity_service.dart';

/// Screen for adding a new contact via QR code or manual key entry.
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

  void _handleQrScan(String data) {
    // Try to parse as exchange payload (base64-encoded JSON)
    try {
      final decoded = utf8.decode(base64Decode(data));
      final payload = jsonDecode(decoded) as Map<String, dynamic>;
      final publicKey = payload['public_key'] as String?;
      if (publicKey != null && publicKey.isNotEmpty) {
        _showAddFromQrDialog(publicKey);
        return;
      }
    } catch (_) {}

    // Fallback: treat the raw string as a public key
    if (data.length >= 10) {
      _showAddFromQrDialog(data);
    }
  }

  void _showAddFromQrDialog(String publicKey) {
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
              await context.read<ContactService>().addContact(publicKey, name);
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$name added')),
                );
                context.pop();
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final identityService = context.watch<IdentityService>();
    final exchangePayload = identityService.generateExchangePayload();
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
                    data: exchangePayload.isNotEmpty ? exchangePayload : myPublicKey,
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

                const SizedBox(height: 24),

                // Copy key button
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
                Text(
                  'Or add manually',
                  style: theme.textTheme.labelLarge,
                ),
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

        // Scanner
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
                  // Reset after a delay to allow re-scanning
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
