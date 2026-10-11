import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../models/profile_about.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/profile_sharing.dart';
import '../../services/identity_service.dart';
import '../../services/sphere_service.dart';
import '../../widgets/profile_view.dart';

/// Our own profile, as we see it, with a way to see it as others do.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  /// Null: as we see it. Otherwise the spheres the imagined viewer shares
  /// with us; an empty set is a contact in none of our spheres.
  Set<String>? _viewAs;

  @override
  void initState() {
    super.initState();
    // A temporary picture may have run out since the app was opened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<IdentityService>().expireTemporaryAvatar();
    });
  }

  @override
  Widget build(BuildContext context) {
    final identityService = context.watch<IdentityService>();
    final contacts = context.watch<ContactService>();
    final spheres = context.watch<SphereService>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final profile = identityService.currentIdentity;
    if (profile == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const Center(child: Text('No identity yet')),
      );
    }
    final viewAs = _viewAs;
    final data =
        viewAs == null ? ProfileData.own(profile) : ProfileData.ownAs(profile, viewAs);

    String? resolve(String key) => contacts.contacts
        .where((c) => c.publicKey == key)
        .map((c) => c.displayName)
        .firstOrNull;

    final feed = context.watch<FeedService>();
    final pinnedPosts = [
      for (final id in profile.pinnedPostIds) ...feed.posts.where((p) => p.id == id),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(viewAs == null ? 'Profile' : 'Viewing as…'),
        actions: [
          if (viewAs != null)
            TextButton(
              onPressed: () => setState(() => _viewAs = null),
              child: const Text('Done'),
            )
          else ...[
            IconButton(
              tooltip: 'View as',
              icon: const Icon(Icons.visibility_outlined),
              onPressed: () => _pickViewAs(context, spheres.spheres),
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.push('/settings'),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (viewAs != null)
            Container(
              width: double.infinity,
              color: cs.tertiaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                viewAs.isEmpty
                    ? 'This is what a contact who shares none of your spheres sees.'
                    : 'This is what a contact in ${viewAs.map((id) => spheres.sphere(id)?.name ?? id).join(', ')} sees.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: ProfileView(
              data: data,
              resolveName: resolve,
              pinnedPosts: viewAs != null &&
                      !ProfileSharing.visibleFields(profile, viewAs).contains(ProfileField.pinned)
                  ? const []
                  : pinnedPosts,
              actions: viewAs != null
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () => context.push('/profile/edit'),
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                label: const Text('Edit profile'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: () => context.push('/albums'),
                              icon: const Icon(Icons.photo_library_outlined, size: 18),
                              label: const Text('Albums'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: () => context.push('/contacts/add'),
                              icon: const Icon(Icons.qr_code_2, size: 18),
                              label: const Text('Share'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Identity key',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        SelectableText(
                          profile.publicKey,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace', fontSize: 11),
                        ),
                        if (profile.legacyContact != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Legacy contact: ${resolve(profile.legacyContact!) ?? 'a contact no longer in your list'}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickViewAs(BuildContext context, List<Sphere> spheres) async {
    final choice = await showModalBottomSheet<Set<String>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('See your profile as…'),
              subtitle: Text(
                  'Each field has an audience. Pick who is looking, and the page shows exactly what they get.'),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('A contact in none of your spheres'),
              onTap: () => Navigator.pop(ctx, <String>{}),
            ),
            for (final s in spheres)
              ListTile(
                leading: const Icon(Icons.blur_circular),
                title: Text('Someone in ${s.name}'),
                onTap: () => Navigator.pop(ctx, {s.id}),
              ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) setState(() => _viewAs = choice);
  }
}
