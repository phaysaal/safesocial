import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
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
  PostAudience audience = PostAudience.everyone;

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
                          // Audience selector
                          GestureDetector(
                            onTap: () {
                              setSheetState(() {
                                audience = audience == PostAudience.everyone
                                    ? PostAudience.closeFriends
                                    : PostAudience.everyone;
                              });
                            },
                            child: Row(
                              children: [
                                Icon(
                                  audience == PostAudience.closeFriends
                                      ? Icons.star
                                      : Icons.public,
                                  size: 14,
                                  color: audience == PostAudience.closeFriends
                                      ? Colors.green
                                      : cs.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  audience == PostAudience.closeFriends
                                      ? 'Close Friends'
                                      : 'Everyone',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: audience == PostAudience.closeFriends
                                        ? Colors.green
                                        : cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Icon(Icons.arrow_drop_down,
                                    size: 16, color: cs.onSurfaceVariant),
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
                        final path =
                            await context.read<MediaService>().pickAndStoreImage();
                        if (path != null) mediaRefs.add(path);
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.videocam_outlined, color: Colors.red[400]),
                      onPressed: () async {
                        final path =
                            await context.read<MediaService>().pickAndStoreVideo();
                        if (path != null) mediaRefs.add(path);
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.location_on_outlined, color: Colors.orange[600]),
                      onPressed: () {},
                    ),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: () {
                        final text = controller.text.trim();
                        if (text.isEmpty && mediaRefs.isEmpty) return;
                        context.read<FeedService>().createPost(
                              text,
                              mediaRefs: mediaRefs.isNotEmpty ? mediaRefs : null,
                              authorName:
                                  identity.currentIdentity?.displayName ?? 'You',
                              audience: audience,
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
    // Auto-refresh feed when screen opens
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
            onPressed: () {},
          ),
        ],
      ),
      body: RefreshIndicator(
        color: cs.primary,
        onRefresh: () => feedService.refreshFeed(),
        child: posts.isEmpty
            ? _buildEmptyFeed(context, theme)
            : CustomScrollView(
                slivers: [
                  // Stories row
                  SliverToBoxAdapter(child: _StoriesRow()),
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
    
    // Check if we have our own active story
    final myStories = storiesMap[myPubKey] ?? [];
    
    // Get other people's stories
    final otherAuthors = storiesMap.keys.where((k) => k != myPubKey).toList();

    return Container(
      color: cs.surface,
      height: 110,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        children: [
          // "Your story" item
          _StoryItem(
            label: 'Your story',
            displayName: myName,
            isAddStory: myStories.isEmpty,
            hasActiveStory: myStories.isNotEmpty,
            onTap: () async {
              if (myStories.isNotEmpty) {
                // View my own story
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => StoryViewerScreen(
                      stories: myStories,
                      authorName: 'You',
                    ),
                  ),
                );
              } else {
                // Create a new story
                final path = await context.read<MediaService>().pickAndStoreImage();
                if (path != null && context.mounted) {
                  await context.read<FeedService>().createStory('', mediaRefs: [path], authorName: myName);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Story added!')));
                }
              }
            },
          ),
          // Contact stories
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

// ─── "What's on your mind?" bar ──────────────────────────────────────────────

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

// ─── Network status dot ──────────────────────────────────────────────────────

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
