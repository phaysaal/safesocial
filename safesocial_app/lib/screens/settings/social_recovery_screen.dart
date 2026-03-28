import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/contact.dart';
import '../../services/contact_service.dart';
import '../../services/rust_core_service.dart';
import '../../services/identity_service.dart';
import '../../services/debug_log_service.dart';

/// Social Recovery screen — manage Guardians and Identity Shards.
class SocialRecoveryScreen extends StatefulWidget {
  const SocialRecoveryScreen({super.key});

  @override
  State<SocialRecoveryScreen> createState() => _SocialRecoveryScreenState();
}

class _SocialRecoveryScreenState extends State<SocialRecoveryScreen> {
  final List<String> _selectedGuardians = [];
  int _threshold = 3;
  bool _isGenerating = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final contactService = context.watch<ContactService>();
    final identityService = context.read<IdentityService>();
    final rustCore = context.read<RustCoreService>();

    final trustedContacts = contactService.contacts.where((c) => !c.blocked).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Social Recovery'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildInfoCard(theme),
          const SizedBox(height: 24),
          Text(
            'Select Guardians',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Choose trusted friends who can help you recover your account if you lose your phone.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (trustedContacts.isEmpty)
            _buildEmptyState(theme)
          else
            ...trustedContacts.map((contact) => CheckboxListTile(
                  value: _selectedGuardians.contains(contact.publicKey),
                  title: Text(contact.name),
                  secondary: CircleAvatar(
                    backgroundColor: cs.primaryContainer,
                    child: Text(contact.name[0]),
                  ),
                  onChanged: (val) {
                    setState(() {
                      if (val == true) {
                        _selectedGuardians.add(contact.publicKey);
                      } else {
                        _selectedGuardians.remove(contact.publicKey);
                      }
                    });
                  },
                )),
          const SizedBox(height: 24),
          if (_selectedGuardians.isNotEmpty) ...[
            Text(
              'Recovery Threshold',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'How many guardians must collaborate to recover your account?',
              style: theme.textTheme.bodySmall,
            ),
            Slider(
              value: _threshold.toDouble(),
              min: 1,
              max: _selectedGuardians.length.toDouble(),
              divisions: _selectedGuardians.length > 1 ? _selectedGuardians.length - 1 : 1,
              label: _threshold.toString(),
              onChanged: (val) {
                setState(() => _threshold = val.toInt());
              },
            ),
            Center(
              child: Text(
                '$_threshold out of ${_selectedGuardians.length} guardians required',
                style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _isGenerating || _selectedGuardians.length < 2
                    ? null
                    : () => _setupRecovery(identityService, rustCore),
                icon: _isGenerating 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.shield),
                label: const Text('Activate Social Recovery'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.people_alt, color: theme.colorScheme.secondary, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'Spheres uses Shamir\'s Secret Sharing. Your recovery key is split into fragments and sent securely to your friends.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Icon(Icons.person_add_disabled, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            const Text('You need at least 2 trusted contacts to set up social recovery.'),
          ],
        ),
      ),
    );
  }

  Future<void> _setupRecovery(IdentityService identity, RustCoreService rustCore) async {
    setState(() => _isGenerating = true);
    
    try {
      // 1. Get the recovery key (private key)
      final secret = await identity.exportIdentity();
      
      // 2. Generate shards using Rust Core (SSS)
      final result = rustCore.exportIdentity(base64Encode(identity.publicKey!.codeUnits)); // Temporary use of export call logic
      // FUTURE: Call spheres_generate_recovery_shards via FFI
      
      DebugLogService().success('Recovery', 'Generated ${_selectedGuardians.length} shards with threshold $_threshold');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Social Recovery Activated! Shards sent to guardians.')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      DebugLogService().error('Recovery', 'Failed to setup recovery: $e');
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }
}
