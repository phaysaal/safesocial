import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../crypto/social_recovery.dart';
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

  /// Split the identity and show the shards for distribution.
  ///
  /// The shards are shown rather than sent: delivering them over the same
  /// channels this identity secures would defeat the point, since anyone who
  /// compromised the account could collect them. Hand them over out of band.
  Future<void> _setupRecovery(
      IdentityService identity, RustCoreService rustCore) async {
    final secret = identity.secretKey;
    final publicKey = identity.publicKey;
    if (secret == null || publicKey == null) return;

    final messenger = ScaffoldMessenger.of(context);

    try {
      final shards = SocialRecovery.createShards(
        identitySecretHex: secret,
        identityPublicKeyHex: publicKey,
        guardianCount: _selectedGuardians.length,
        threshold: _threshold,
      );

      DebugLogService().success('Recovery',
          '${shards.length} shard(s) created, threshold $_threshold');

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('$_threshold of ${shards.length} required'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text(
                  'Give one shard to each guardian, in person or over a channel '
                  'this identity does not protect. Any '
                  'threshold of them together can restore you; fewer cannot.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                ...shards.asMap().entries.map((entry) {
                  final guardian = _selectedGuardians[entry.key];
                  return ListTile(
                    dense: true,
                    title: Text('Shard ${entry.value.index} → '
                        '${guardian.substring(0, 8)}…'),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(
                            ClipboardData(text: entry.value.encode()));
                        messenger.showSnackBar(SnackBar(
                          content: Text('Shard ${entry.value.index} copied'),
                        ));
                      },
                    ),
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done')),
          ],
        ),
      );
    } on RecoveryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not split: $e')));
    }
  }

  /// Rebuild the identity from pasted shards.
  ///
  /// Nothing is adopted unless the result verifies against the public key the
  /// shards name. Shamir has no integrity of its own, so too few shards or one
  /// bad one produces plausible nonsense — the previous implementation
  /// reported exactly that as success.
  Future<void> _reconstructIdentity(
      IdentityService identity, RustCoreService rustCore) async {
    final messenger = ScaffoldMessenger.of(context);

    final shards = _shardControllers
        .map((c) => RecoveryShard.tryDecode(c.text))
        .whereType<RecoveryShard>()
        .toList();

    final pasted = _shardControllers.where((c) => c.text.trim().isNotEmpty).length;
    if (shards.length < pasted) {
      messenger.showSnackBar(SnackBar(
        content: Text('${pasted - shards.length} shard(s) could not be read'),
      ));
      return;
    }
    if (shards.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Paste your shards first')));
      return;
    }

    final String secret;
    try {
      secret = SocialRecovery.reconstruct(shards);
    } on RecoveryException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace this identity?'),
        content: Text(
          'The shards rebuilt the identity '
          '${shards.first.identityPublicKey.substring(0, 8)}… and it verifies.\n\n'
          'Restoring replaces whatever identity is on this device, which cannot '
          'be brought back.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;

    final restored = await identity.importIdentity(jsonEncode({
      'key': shards.first.identityPublicKey,
      'secret': secret,
    }));

    if (!mounted) return;
    if (restored) {
      DebugLogService().success('Recovery', 'Identity restored from shards');
      messenger.showSnackBar(const SnackBar(
        content: Text('Identity restored. Restart the app to finish.'),
      ));
      Navigator.pop(context);
    } else {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not apply the restored identity')));
    }
  }
}
