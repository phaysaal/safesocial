import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/sphere.dart';
import '../../models/profile_about.dart';
import '../../services/contact_service.dart';
import '../../models/post.dart';
import '../../services/feed_service.dart';
import '../../services/library_service.dart';
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
    final library = context.watch<LibraryService>();
    final tagged = feed.taggedPosts(profile.publicKey);
    final pendingTags = library.tagReview
        ? tagged.where((p) => !library.isTagApproved(p.id) && !library.isTagHidden(p.id)).toList()
        : const <Post>[];
    final shownTags = tagged.where((p) => library.showsTag(p.id)).toList();

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
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onTertiaryContainer),
              ),
            ),
          Expanded(
            child: ProfileView(
              data: data,
              resolveName: resolve,
              onRemoveHighlight: viewAs != null
                  ? null
                  : (id) => context.read<IdentityService>().removeHighlight(id),
              taggedPosts: shownTags,
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
                            IconButton.filledTonal(
                              tooltip: 'Albums',
                              onPressed: () => context.push('/albums'),
                              icon: const Icon(Icons.photo_library_outlined),
                            ),
                            const SizedBox(width: 4),
                            IconButton.filledTonal(
                              tooltip: 'Share your contact code',
                              onPressed: () => context.push('/contacts/add'),
                              icon: const Icon(Icons.qr_code_2),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _ProfileTile(
                          icon: Icons.article_outlined,
                          label: 'Your posts',
                          hint: '${feed.posts.where((p) => p.authorId == profile.publicKey && !p.isStory).length} on this device',
                          onTap: () => context.push('/profile/posts'),
                        ),
                        _ProfileTile(
                          icon: Icons.history,
                          label: 'Your activity',
                          hint: 'Posts, comments and reactions, newest first',
                          onTap: () => context.push('/profile/activity'),
                        ),
                        _ProfileTile(
                          icon: Icons.inventory_2_outlined,
                          label: 'Manage posts',
                          hint: 'Archive, trash, delete in bulk',
                          onTap: () => context.push('/posts/manage'),
                        ),
                        _ProfileTile(
                          icon: Icons.chat_bubble_outline,
                          label: (profile.activeNote).isEmpty ? 'Share a note for a day' : 'Note: ${profile.activeNote}',
                          hint: 'A line your contacts see for 24 hours',
                          onTap: () async {
                            final identity = context.read<IdentityService>();
                            final c = TextEditingController(text: identity.currentIdentity?.activeNote ?? '');
                            final text = await showDialog<String>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Note for a day'),
                                content: TextField(
                                  controller: c,
                                  maxLength: 80,
                                  autofocus: true,
                                  decoration: const InputDecoration(hintText: 'What are you up to?'),
                                  textCapitalization: TextCapitalization.sentences,
                                ),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                                  TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Clear')),
                                  FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Share')),
                                ],
                              ),
                            );
                            if (text == null) return;
                            await identity.setNote(text);
                          },
                        ),
                        if (pendingTags.isNotEmpty)
                          Card(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              ListTile(
                                leading: Icon(Icons.local_offer_outlined, color: cs.primary),
                                title: Text('${pendingTags.length} post${pendingTags.length == 1 ? '' : 's'} tag you'),
                                subtitle: const Text('Say yes before it shows on your profile.'),
                              ),
                              for (final p in pendingTags)
                                ListTile(
                                  dense: true,
                                  title: Text(p.content.isEmpty ? '(media)' : p.content, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(p.authorName),
                                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                    IconButton(icon: const Icon(Icons.close), tooltip: 'Keep off my profile', onPressed: () => library.reviewTag(p.id, approve: false)),
                                    IconButton(icon: Icon(Icons.check, color: cs.primary), tooltip: 'Show on my profile', onPressed: () => library.reviewTag(p.id, approve: true)),
                                  ]),
                                ),
                            ]),
                          ),
                        _ProfileTile(
                          icon: Icons.history_outlined,
                          label: 'Flash archive and highlights',
                          hint: 'Your flashes, kept here; pick some for the profile',
                          onTap: () => context.push('/stories/archive'),
                        ),
                        const SizedBox(height: 4),
                        Theme(
                          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            leading: Icon(Icons.key_outlined, color: cs.onSurfaceVariant, size: 20),
                            title: Text('Identity key', style: theme.textTheme.bodyMedium),
                            subtitle: Text('${profile.publicKey.substring(0, 12)}…  tap to show',
                                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                            children: [
                              SelectableText(
                                profile.publicKey,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(fontFamily: 'monospace', color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
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

/// One of the profile's own tools: a soft tile, not a red text link.
class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;
  const _ProfileTile({required this.icon, required this.label, required this.hint, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 20, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(hint, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    );
  }
}
