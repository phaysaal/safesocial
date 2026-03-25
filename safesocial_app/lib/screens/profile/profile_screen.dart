import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/identity_service.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/group_service.dart';
import '../../services/theme_service.dart';
import '../../models/post.dart';
import '../../widgets/avatar.dart';

/// Instagram-style profile screen.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final identityService = context.watch<IdentityService>();
    final contactService = context.watch<ContactService>();
    final feedService = context.watch<FeedService>();
    final groupService = context.watch<GroupService>();

    final profile = identityService.currentIdentity;
    if (profile == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final myPosts =
        feedService.posts.where((p) => p.authorId == 'self').toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          profile.displayName,
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_box_outlined),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => _showSettingsSheet(context),
          ),
        ],
      ),
      body: DefaultTabController(
        length: 2,
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) {
            return [
              SliverToBoxAdapter(
                child: Container(
                  color: cs.surface,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Avatar + stats row ───────────────────
                      Row(
                        children: [
                          UserAvatar(
                            displayName: profile.displayName,
                            imageRef: profile.avatarRef,
                            size: AvatarSize.large,
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _StatColumn(
                                  count: '${myPosts.length}',
                                  label: 'Posts',
                                ),
                                _StatColumn(
                                  count: '${contactService.contacts.length}',
                                  label: 'Contacts',
                                ),
                                _StatColumn(
                                  count: '${groupService.groups.length}',
                                  label: 'Groups',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // ── Name ─────────────────────────────────
                      Text(
                        profile.displayName,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),

                      // ── Bio ──────────────────────────────────
                      if (profile.bio.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(profile.bio, style: theme.textTheme.bodyMedium),
                      ],

                      // ── Public key chip ──────────────────────
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(
                              ClipboardData(text: profile.publicKey));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Public key copied'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.key, size: 12, color: cs.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              _truncateKey(profile.publicKey),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.copy, size: 12, color: cs.onSurfaceVariant),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // ── Action buttons ───────────────────────
                      Row(
                        children: [
                          Expanded(
                            child: _ProfileButton(
                              label: 'Edit Profile',
                              onTap: () => context.push('/profile/edit'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _ProfileButton(
                              label: 'Share Profile',
                              onTap: () async {
                                final key =
                                    await identityService.exportIdentity();
                                if (context.mounted) {
                                  Clipboard.setData(ClipboardData(text: key));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content:
                                          Text('Identity key copied to clipboard'),
                                      duration: Duration(seconds: 2),
                                    ),
                                  );
                                }
                              },
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),

              // ── Tab bar ──────────────────────────────────────
              SliverPersistentHeader(
                pinned: true,
                delegate: _TabBarDelegate(
                  TabBar(
                    indicatorColor: cs.onSurface,
                    labelColor: cs.onSurface,
                    unselectedLabelColor: cs.onSurfaceVariant,
                    indicatorWeight: 1.5,
                    tabs: const [
                      Tab(icon: Icon(Icons.grid_on, size: 22)),
                      Tab(icon: Icon(Icons.bookmark_border, size: 22)),
                    ],
                  ),
                  cs.surface,
                ),
              ),
            ];
          },
          body: TabBarView(
            children: [
              // ── Grid tab ──────────────────────────────────
              myPosts.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.camera_alt_outlined,
                            size: 48,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No posts yet',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Share your first post to see it here.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(1),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 2,
                        crossAxisSpacing: 2,
                      ),
                      itemCount: myPosts.length,
                      itemBuilder: (context, index) {
                        final post = myPosts[index];
                        return _PostGridTile(post: post);
                      },
                    ),

              // ── Saved tab (placeholder) ───────────────────
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bookmark_border,
                      size: 48,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(height: 12),
                    Text('Saved', style: theme.textTheme.titleLarge?.copyWith(fontSize: 18)),
                    const SizedBox(height: 4),
                    Text(
                      'Save posts to revisit them later.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSettingsSheet(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final themeService = context.read<ThemeService>();

    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  themeService.isDark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                ),
                title: Text(
                  themeService.isDark
                      ? 'Switch to Light Mode'
                      : 'Switch to Dark Mode',
                ),
                onTap: () {
                  themeService.toggle();
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Export Identity'),
                onTap: () async {
                  final key =
                      await context.read<IdentityService>().exportIdentity();
                  if (ctx.mounted) {
                    Clipboard.setData(ClipboardData(text: key));
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Identity key copied'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('About SafeSocial'),
                onTap: () => Navigator.pop(ctx),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  String _truncateKey(String key) {
    if (key.length <= 16) return key;
    return '${key.substring(0, 8)}...${key.substring(key.length - 6)}';
  }
}

// ─── Stat column (Instagram style) ───────────────────────────────────────────

class _StatColumn extends StatelessWidget {
  final String count;
  final String label;

  const _StatColumn({required this.count, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          count,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

// ─── Profile action button ───────────────────────────────────────────────────

class _ProfileButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ProfileButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Tab bar delegate ────────────────────────────────────────────────────────

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  final Color backgroundColor;

  _TabBarDelegate(this.tabBar, this.backgroundColor);

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(color: backgroundColor, child: tabBar);
  }

  @override
  bool shouldRebuild(_TabBarDelegate oldDelegate) => false;
}

// ─── Post grid tile ──────────────────────────────────────────────────────────

class _PostGridTile extends StatelessWidget {
  final Post post;

  const _PostGridTile({required this.post});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // If the post has media, show first image; otherwise show text preview
    if (post.mediaRefs.isNotEmpty) {
      final file = File(post.mediaRefs.first);
      if (file.existsSync()) {
        return Image.file(file, fit: BoxFit.cover);
      }
    }

    // Text-only post tile
    return Container(
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.all(8),
      child: Center(
        child: Text(
          post.content,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: cs.onSurface),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
