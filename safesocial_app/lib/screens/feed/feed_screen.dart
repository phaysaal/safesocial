import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import '../../models/post.dart';
import '../../models/ring.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../services/ring_service.dart';
import '../../services/veilid_service.dart';
import '../../widgets/responsive_layout.dart';
import '../../widgets/avatar.dart';
import '../../widgets/post_card.dart';
import 'story_viewer_screen.dart';

void _showCreatePostSheet(BuildContext context) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final controller = TextEditingController();
  final mediaRefs = <String>[];
  final identity = context.read<IdentityService>();
  final ringService = context.read<RingService>();
  
  List<String> selectedRingIds = []; // Empty means "Everyone"

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    UserAvatar(
                      displayName: identity.currentIdentity?.displayName ?? 'You',
                      size: AvatarSize.medium,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Create Post',
                            style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                          ),
                          // Ring Selector
                          GestureDetector(
                            onTap: () async {
                              final result = await _showRingSelectorDialog(context, ringService, selectedRingIds);
                              if (result != null) {
                                setSheetState(() {
                                  selectedRingIds = result;
                                });
                              }
                            },
                            child: Row(
                              children: [
                                Icon(
                                  selectedRingIds.isEmpty ? Icons.public : Icons.blur_circular,
                                  size: 14,
                                  color: selectedRingIds.isEmpty ? cs.onSurfaceVariant : cs.primary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  selectedRingIds.isEmpty 
                                    ? 'Everyone' 
                                    : selectedRingIds.length == 1 
                                      ? ringService.rings.firstWhere((r) => r.id == selectedRingIds.first).name
                                      : '${selectedRingIds.length} Rings',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selectedRingIds.isEmpty ? cs.onSurfaceVariant : cs.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Icon(Icons.arrow_drop_down, size: 16, color: cs.onSurfaceVariant),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: "What's on your mind?",
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    fillColor: Colors.transparent,
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  maxLines: 6,
                  minLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  autofocus: true,
                  style: theme.textTheme.bodyLarge,
                ),
                const Divider(),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.photo_library_outlined, color: Colors.green[600]),
                      onPressed: () async {
                        final path = await context.read<MediaService>().pickAndStoreImage();
                        if (path != null) mediaRefs.add(path);
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.videocam_outlined, color: Colors.red[400]),
                      onPressed: () async {
                        final path = await context.read<MediaService>().pickAndStoreVideo();
                        if (path != null) mediaRefs.add(path);
                      },
                    ),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: () {
                        final text = controller.text.trim();
                        if (text.isEmpty && mediaRefs.isEmpty) return;
                        
                        context.read<FeedService>().createPost(
                          text,
                          mediaRefs: mediaRefs.isNotEmpty ? mediaRefs : null,
                          authorName: identity.currentIdentity?.displayName ?? 'You',
                          audience: selectedRingIds.isEmpty ? PostAudience.everyone : PostAudience.closeFriends,
                        );
                        Navigator.pop(ctx);
                      },
                      child: const Text('Post'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<List<String>?> _showRingSelectorDialog(BuildContext context, RingService service, List<String> current) async {
  List<String> selected = List.from(current);
  return showDialog<List<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Select Audience'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                value: selected.isEmpty,
                title: const Text('Everyone'),
                subtitle: const Text('All your contacts'),
                onChanged: (val) {
                  if (val == true) setState(() => selected.clear());
                },
              ),
              const Divider(),
              ...service.rings.map((ring) => CheckboxListTile(
                value: selected.contains(ring.id),
                title: Text(ring.name),
                secondary: CircleAvatar(backgroundColor: ring.color, radius: 8),
                onChanged: (val) {
                  setState(() {
                    if (val == true) {
                      selected.add(ring.id);
                    } else {
                      selected.remove(ring.id);
                    }
                  });
                },
              )),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, selected), child: const Text('Done')),
        ],
      ),
    ),
  );
}

/// Instagram / Facebook style social feed.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FeedService>().refreshFeed();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final feedService = context.watch<FeedService>();
    final posts = feedService.posts;
    final memories = feedService.memories;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(
              'Spheres',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: 24,
              ),
            ),
            const SizedBox(width: 8),
            _NetworkDot(),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_box_outlined),
            onPressed: () => _showCreatePostSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.favorite_border),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () => context.go('/chats'),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: cs.primary,
        onRefresh: () => feedService.refreshFeed(),
        child: posts.isEmpty && memories.isEmpty
            ? _buildEmptyFeed(context, theme)
            : CustomScrollView(
                slivers: [
                  // Stories row
                  SliverToBoxAdapter(child: _StoriesRow()),
                  // Memories Banner
                  if (memories.isNotEmpty)
                    SliverToBoxAdapter(child: _MemoriesBanner(count: memories.length)),
                  // Create-post bar
                  SliverToBoxAdapter(child: _CreatePostBar()),
                  // Divider
                  SliverToBoxAdapter(
                    child: Container(height: 8, color: theme.scaffoldBackgroundColor),
                  ),
                  // Posts — constrained width on tablet
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final card = PostCard(post: posts[index]);
                        if (isTablet(context)) {
                          return Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 600),
                              child: card,
                            ),
                          );
                        }
                        return card;
                      },
                      childCount: posts.length,
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 80)),
                ],
              ),
      ),
    );
  }

  Widget _buildEmptyFeed(BuildContext context, ThemeData theme) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _StoriesRow()),
        SliverToBoxAdapter(child: _CreatePostBar()),
        SliverToBoxAdapter(
          child: Container(height: 8, color: theme.scaffoldBackgroundColor),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.dynamic_feed_outlined,
                    size: 64,
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Your feed is empty',
                    style: theme.textTheme.headlineMedium?.copyWith(fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Share something or connect with people to see their posts.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => _showCreatePostSheet(context),
                    icon: const Icon(Icons.edit, size: 18),
                    label: const Text('Create your first post'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Memories Banner ─────────────────────────────────────────────────────────

class _MemoriesBanner extends StatelessWidget {
  final int count;
  const _MemoriesBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return GestureDetector(
      onTap: () => context.push('/memories'),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.primary.withValues(alpha: 0.8), cs.secondary.withValues(alpha: 0.8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: cs.primary.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome, color: Colors.white, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'On This Day',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  Text(
                    'You have $count ${count == 1 ? 'memory' : 'memories'} to relive today.',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white),
          ],
        ),
      ),
    );
  }
}

// ─── Stories row ──────────────────────────────────────────────────────────────

class _StoriesRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final identity = context.watch<IdentityService>();
    final feedService = context.watch<FeedService>();
    final myName = identity.currentIdentity?.displayName ?? 'You';
    final myPubKey = identity.publicKey ?? 'self';

    final storiesMap = feedService.storiesByAuthor;
    final myStories = storiesMap[myPubKey] ?? [];
    final otherAuthors = storiesMap.keys.where((k) => k != myPubKey).toList();

    return Container(
      color: cs.surface,
      height: 110,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        children: [
          _StoryItem(
            label: 'Your story',
            displayName: myName,
            isAddStory: myStories.isEmpty,
            hasActiveStory: myStories.isNotEmpty,
            onTap: () async {
              if (myStories.isNotEmpty) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => StoryViewerScreen(
                      stories: myStories,
                      authorName: 'You',
                    ),
                  ),
                );
              } else {
                final path = await context.read<MediaService>().pickAndStoreImage();
                if (path != null && context.mounted) {
                  await context.read<FeedService>().createStory('', mediaRefs: [path], authorName: myName);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Story added!')));
                }
              }
            },
          ),
          for (final authorId in otherAuthors) ...[
            Builder(
              builder: (ctx) {
                final authorStories = storiesMap[authorId]!;
                final authorName = authorStories.first.authorName.isNotEmpty 
                    ? authorStories.first.authorName 
                    : 'Contact';
                
                return _StoryItem(
                  label: authorName.split(' ').first,
                  displayName: authorName,
                  hasActiveStory: true,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => StoryViewerScreen(
                          stories: authorStories,
                          authorName: authorName,
                        ),
                      ),
                    );
                  },
                );
              }
            )
          ]
        ],
      ),
    );
  }
}

class _StoryItem extends StatelessWidget {
  final String label;
  final String displayName;
  final bool isAddStory;
  final bool hasActiveStory;
  final VoidCallback? onTap;

  const _StoryItem({
    required this.label,
    required this.displayName,
    this.isAddStory = false,
    this.hasActiveStory = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: hasActiveStory
                        ? LinearGradient(
                            colors: [cs.primary, cs.secondary],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : null,
                    border: !hasActiveStory
                        ? Border.all(color: cs.outline, width: 1)
                        : null,
                  ),
                  padding: const EdgeInsets.all(2.5),
                  child: CircleAvatar(
                    backgroundColor: cs.surface,
                    child: UserAvatar(
                      displayName: displayName,
                      size: AvatarSize.medium,
                    ),
                  ),
                ),
                if (isAddStory)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: cs.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: cs.surface, width: 2),
                      ),
                      child: const Icon(Icons.add, size: 14, color: Colors.white),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 64,
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreatePostBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final identity = context.watch<IdentityService>();
    final name = identity.currentIdentity?.displayName ?? 'You';

    return Container(
      color: cs.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      margin: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          UserAvatar(displayName: name, size: AvatarSize.small),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: () => _showCreatePostSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: cs.outline),
                ),
                child: Text(
                  "What's on your mind?",
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.photo_library_outlined, color: Colors.green[600], size: 22),
        ],
      ),
    );
  }
}

class _NetworkDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final vs = context.watch<VeilidService>();
    final isConnected = vs.isAttached;
    final state = vs.attachmentState.toString().split('.').last;

    return GestureDetector(
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isConnected
                  ? 'P2P network: $state'
                  : 'Not connected to P2P network${vs.error != null ? ": ${vs.error}" : ""}',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      },
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isConnected ? Colors.green : Colors.orange,
        ),
      ),
    );
  }
}
