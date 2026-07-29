import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/contact_service.dart';
import '../../services/rust_core_service.dart';
import '../../services/identity_service.dart';
import '../../services/debug_log_service.dart';

/// Social Recovery screen — manage Guardians and Identity Reconstruction.
class SocialRecoveryScreen extends StatefulWidget {
  const SocialRecoveryScreen({super.key});

  @override
  State<SocialRecoveryScreen> createState() => _SocialRecoveryScreenState();
}

class _SocialRecoveryScreenState extends State<SocialRecoveryScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<String> _selectedGuardians = [];
  final List<TextEditingController> _shardControllers = [];
  int _threshold = 3;
  final bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // Add initial shard input fields for reconstruction
    for (var i = 0; i < 3; i++) {
      _shardControllers.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (var c in _shardControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Social Recovery'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Setup Guardians'),
            Tab(text: 'Reconstruct Identity'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSetupTab(context),
          _buildReconstructTab(context),
        ],
      ),
    );
  }

  Widget _buildSetupTab(BuildContext context) {
    final theme = Theme.of(context);
    final contactService = context.watch<ContactService>();
    final identityService = context.read<IdentityService>();
    final rustCore = context.read<RustCoreService>();
    final trustedContacts = contactService.contacts.where((c) => !c.blocked).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildInfoCard(theme, 'Split your recovery key into shards and send them to trusted friends.'),
        const SizedBox(height: 24),
        Text('Select Guardians', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (trustedContacts.isEmpty)
          const Center(child: Text('Add contacts to set up guardians.'))
        else
          ...trustedContacts.map((contact) => CheckboxListTile(
                value: _selectedGuardians.contains(contact.publicKey),
                title: Text(contact.displayName),
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
        if (_selectedGuardians.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Recovery Threshold: $_threshold', style: theme.textTheme.titleSmall),
          Slider(
            value: _threshold.toDouble(),
            min: 1,
            max: _selectedGuardians.length.toDouble(),
            divisions: _selectedGuardians.length > 1 ? _selectedGuardians.length - 1 : 1,
            onChanged: (val) => setState(() => _threshold = val.toInt()),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _isProcessing ? null : () => _setupRecovery(identityService, rustCore),
            child: const Text('Generate & Send Shards'),
          ),
        ],
      ],
    );
  }

  Widget _buildReconstructTab(BuildContext context) {
    final theme = Theme.of(context);
    final identityService = context.read<IdentityService>();
    final rustCore = context.read<RustCoreService>();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildInfoCard(theme, 'Paste the shards collected from your guardians to rebuild your identity.'),
        const SizedBox(height: 24),
        ..._shardControllers.asMap().entries.map((entry) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: entry.value,
                decoration: InputDecoration(
                  labelText: 'Shard ${entry.key + 1}',
                  hintText: 'Paste shard here',
                  border: const OutlineInputBorder(),
                ),
                maxLines: 2,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            )),
        TextButton.icon(
          onPressed: () => setState(() => _shardControllers.add(TextEditingController())),
          icon: const Icon(Icons.add),
          label: const Text('Add Another Shard'),
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _isProcessing ? null : () => _reconstructIdentity(identityService, rustCore),
          child: const Text('Reconstruct Identity'),
        ),
      ],
    );
  }

  Widget _buildInfoCard(ThemeData theme, String text) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(text),
      ),
    );
  }

  // Social recovery is not implemented. Both entry points previously reported
  // success without generating, sending, or reconstructing anything — so a
  // user could believe their guardians held shards when none existed. Until
  // the real Shamir flow lands (threshold enforcement, shard authentication,
  // and verification of the reconstructed secret against the identity public
  // key), these must fail visibly.
  static const _unavailableMessage =
      'Social recovery is not available yet. No shards were created or sent.';

  Future<void> _setupRecovery(IdentityService identity, RustCoreService rustCore) async {
    DebugLogService().warn('Recovery', 'Setup attempted — feature not implemented');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(_unavailableMessage)),
      );
    }
  }

  Future<void> _reconstructIdentity(IdentityService identity, RustCoreService rustCore) async {
    DebugLogService().warn('Recovery', 'Reconstruction attempted — feature not implemented');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Identity reconstruction is not available yet. Your current '
            'identity has not been changed.',
          ),
        ),
      );
    }
  }
}
