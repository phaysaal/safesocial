import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/identity_service.dart';
import '../../services/album_service.dart';
import '../../widgets/avatar.dart';

/// User profile screen — view and manage personal identity.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final identityService = context.watch<IdentityService>();
    final albumService = context.watch<AlbumService>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final profile = identityService.currentIdentity;
    final name = profile?.displayName ?? 'Spheres User';
    final pubKey = identityService.publicKey ?? 'Not available';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Header
            Center(
              child: Column(
                children: [
                  UserAvatar(displayName: name, size: AvatarSize.large),
                  const SizedBox(height: 16),
                  Text(
                    name,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Public Identity',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Action Grid
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ProfileAction(
                  icon: Icons.edit_outlined,
                  label: 'Edit Profile',
                  onTap: () => context.push('/profile/edit'),
                ),
                _ProfileAction(
                  icon: Icons.photo_library_outlined,
                  label: 'My Albums',
                  onTap: () => context.push('/albums'),
                ),
                _ProfileAction(
                  icon: Icons.share_outlined,
                  label: 'Share ID',
                  onTap: () => context.push('/contacts/add'),
                ),
              ],
            ),
            const SizedBox(height: 40),

            // Details
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'NETWORK IDENTITY',
                style: theme.textTheme.labelMedium?.copyWith(color: cs.primary, letterSpacing: 1.2),
              ),
            ),
            const SizedBox(height: 16),
            _DetailTile(
              label: 'Public Key (Ed25519)',
              value: pubKey,
              isMonospace: true,
            ),
            const Divider(height: 32),
            
            // Stats or recent activity
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.collections_bookmark_outlined, color: cs.secondary),
              title: const Text('Recent Albums'),
              trailing: Text('${albumService.albums.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
              onTap: () => context.push('/albums'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ProfileAction({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Icon(icon, color: cs.primary, size: 28),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

class _DetailTile extends StatelessWidget {
  final String label;
  final String value;
  final bool isMonospace;

  const _DetailTile({required this.label, required this.value, this.isMonospace = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontFamily: isMonospace ? 'monospace' : null,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
