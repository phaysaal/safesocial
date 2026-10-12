import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../models/media_provenance.dart';
import '../models/post.dart';
import 'post_kinds.dart';
import 'reaction_picker.dart';
import 'author_name.dart';
import '../models/sphere.dart';
import '../services/contact_service.dart';
import '../services/feed_service.dart';
import '../services/notification_service.dart';
import '../services/media_service.dart';
import '../services/event_reminders.dart';
import '../services/calendar_bridge.dart';
import '../models/event_time.dart';
import '../services/library_service.dart';
import '../services/identity_service.dart';
import '../screens/spheres/sphere_settings_screen.dart';
import '../services/sphere_info_service.dart';
import '../services/sphere_service.dart';
import 'avatar.dart';
import 'media_thumb.dart';
import 'provenance_badge.dart';
import 'post_extras.dart';

/// Instagram / Facebook style post card.
class PostCard extends StatefulWidget {
  final Post post;

  const PostCard({super.key, required this.post});

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  bool _showHeart = false;

  void _onDoubleTap() {
    if (!widget.post.isLikedBy(context.read<IdentityService>().publicKey)) {
      context.read<FeedService>().toggleLike(widget.post.id);
    }
    setState(() => _showHeart = true);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showHeart = false);
    });
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${diff.inDays ~/ 7}w';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final post = widget.post;
    final myKey = context.watch<IdentityService>().publicKey;
    final authorName = post.authorId == myKey
        ? 'You'
        : (post.authorName.isNotEmpty ? post.authorName : post.authorId);

    return Container(
      color: cs.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Author header ──────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                UserAvatar(displayName: authorName, size: AvatarSize.medium),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Builder(builder: (context) {
                        final feeling = Feelings.line(post.payload);
                        final shared = post.isReshare;
                        final badges = context.watch<SphereInfoService>().badgesFor(post.sphereId, post.authorId);
                        final topic = post.payload?['topic'];
                        if (feeling.isEmpty && !shared) {
                          return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
                            Text(authorName,
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            if (badges.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
                                child: Text(badges.first, style: TextStyle(fontSize: 10, color: cs.onTertiaryContainer)),
                              ),
                            if (topic is String && topic.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                                child: Text('#$topic', style: TextStyle(fontSize: 10, color: cs.onSecondaryContainer)),
                              ),
                          ]);
                        }
                        return RichText(
                          text: TextSpan(
                            style: theme.textTheme.bodyLarge,
                            children: [
                              TextSpan(
                                  text: authorName,
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                              if (shared)
                                TextSpan(
                                    text: ' shared a post',
                                    style: TextStyle(color: cs.onSurfaceVariant)),
                              if (feeling.isNotEmpty)
                                TextSpan(
                                    text: ' is $feeling',
                                    style: TextStyle(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        );
                      }),
                      Row(
                        children: [
                          Text(
                            _timeAgo(post.createdAt),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(width: 4),
                          // Members only, always; the glyph says so rather
                          // than hinting at a public audience.
                          Icon(Icons.lock_outline, size: 12, color: cs.onSurfaceVariant),
                          if (context.watch<FeedService>().isPinned(post.id)) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.push_pin, size: 12, color: cs.primary),
                          ],
                          if (post.editedAt != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              'Edited',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontStyle: FontStyle.italic,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Which sphere this went to. The old badge said "Close
                // Friends" while delivery ignored the audience entirely; this
                // names the sphere that actually received it.
                Builder(builder: (context) {
                  final spheres = context.watch<SphereService>();
                  // Every sphere this reached us through. A post can be shared
                  // with several, and someone in two of them should see both
                  // rather than whichever copy happened to arrive first.
                  //
                  // Only spheres we are in appear here, because only their
                  // copies reached us — so this cannot disclose an audience
                  // the reader is not already part of.
                  final names = post.sphereIds
                      .map(spheres.sphere)
                      .whereType<Sphere>()
                      .map((s) => s.name)
                      .toList()
                    ..sort();
                  if (names.isEmpty) return const SizedBox.shrink();
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(names.join(' · '),
                        style: TextStyle(fontSize: 10, color: cs.primary)),
                  );
                }),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, color: cs.onSurfaceVariant),
                  onSelected: (value) => _handlePostMenu(context, value, post),
                  itemBuilder: (ctx) => [
                    PopupMenuItem(
                      value: 'save',
                      child: Text(
                        context.read<LibraryService>().isSaved(post.id)
                            ? 'Remove from saved'
                            : 'Save post',
                      ),
                    ),
                    const PopupMenuItem(value: 'hide', child: Text('Hide post')),
                    if (post.authorId == myKey) ...[
                      const PopupMenuItem(value: 'edit', child: Text('Edit post')),
                      PopupMenuItem(
                        value: 'comments',
                        child: Text(post.commentsOff
                            ? 'Turn comments on'
                            : 'Turn comments off'),
                      ),
                    ],
                    const PopupMenuItem(value: 'open', child: Text('Open post and comments')),
                    if (myKey != null &&
                        (context.read<SphereService>().sphere(post.sphereId)?.isAdmin(myKey) ?? false))
                      const PopupMenuItem(value: 'guide', child: Text('Add to a guide…')),
                    if (!post.isReshare &&
                        (post.authorSig == null || post.allowReshare) &&
                        context.read<SphereService>().spheres.length > 1)
                      const PopupMenuItem(value: 'reshare', child: Text('Share to another sphere')),
                    if (post.authorId == myKey)
                      PopupMenuItem(
                        value: 'profile_pin',
                        child: Text(
                          (context.read<IdentityService>().currentIdentity?.pinnedPostIds.contains(post.id) ?? false)
                              ? 'Unpin from my profile'
                              : 'Pin to my profile',
                        ),
                      ),
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(context.read<FeedService>().isArchived(post.id)
                          ? 'Unarchive'
                          : 'Archive (hide from my feed)'),
                    ),
                    if (post.authorId == myKey ||
                        (myKey != null &&
                            (context.read<SphereService>().sphere(post.sphereId)?.isAdmin(myKey) ??
                                false)))
                      const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    PopupMenuItem(
                      value: 'notify',
                      child: Text(context.read<FeedService>().postNotifies(post)
                          ? 'Stop notifications for this post'
                          : 'Notify me about this post'),
                    ),
                    if (myKey != null &&
                        (context.read<SphereService>().sphere(post.sphereId)?.isAdmin(myKey) ??
                            false))
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(context.read<FeedService>().isPinned(post.id)
                            ? 'Unpin from sphere'
                            : 'Pin in sphere'),
                      ),
                    if (post.authorId != myKey) ...[
                      PopupMenuItem(
                        value: 'mute',
                        child: Text(
                            (context.read<ContactService>().getContact(post.authorId)?.muted ?? false)
                                ? 'Unmute this person'
                                : 'Mute this person (posts and notifications)'),
                      ),
                      PopupMenuItem(
                        value: 'snooze',
                        child: Text(
                            (context.read<ContactService>().getContact(post.authorId)?.isSnoozed ?? false)
                                ? 'End the 30-day snooze'
                                : 'Snooze for 30 days'),
                      ),
                      PopupMenuItem(
                        value: 'unfollow',
                        child: Text(
                            (context.read<ContactService>().getContact(post.authorId)?.following ?? true)
                                ? 'Unfollow'
                                : 'Follow again'),
                      ),
                      const PopupMenuItem(value: 'report', child: Text('Report to the sphere')),
                    ],
                  ],
                ),
              ],
            ),
          ),

          // ── Co-authors ─────────────────────────────────────
          if (post.acceptedCoAuthors.isNotEmpty ||
              (post.coAuthors.contains(myKey) && !post.acceptedCoAuthors.contains(myKey)))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Builder(builder: (context) {
                final contacts = context.read<ContactService>();
                String name(String k) =>
                    k == myKey ? 'you' : (contacts.getContact(k)?.displayName ?? '${k.substring(0, 8)}…');
                final confirmed = post.acceptedCoAuthors.map(name).join(', ');
                final pendingMe = post.coAuthors.contains(myKey) && !post.acceptedCoAuthors.contains(myKey);
                return Row(children: [
                  if (confirmed.isNotEmpty)
                    Expanded(child: Text('with $confirmed', style: theme.textTheme.bodySmall)),
                  if (pendingMe)
                    TextButton(
                      onPressed: () => context.read<FeedService>().acceptCoAuthorship(post.id),
                      child: const Text('Confirm you co-wrote this'),
                    ),
                ]);
              }),
            ),

          // ── Content text ───────────────────────────────────
          if (post.content.isNotEmpty &&
              !post.isPoll &&
              !post.isLifeEvent &&
              !post.isRecommend)
            Builder(builder: (context) {
              final bg = post.payload?['bg'];
              if (post.mediaRefs.isEmpty &&
                  bg is String &&
                  PostBackgrounds.colorsFor(bg) != null &&
                  post.content.length <= PostBackgrounds.maxChars) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: BackgroundTextCard(text: post.content, background: bg),
                );
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(post.content, style: theme.textTheme.bodyMedium),
              );
            }),
          if (post.isLifeEvent) LifeEventCard(post: post),
          if (post.isRecommend)
            RecommendCard(
              post: post,
              myKey: myKey,
              nameFor: (k) => k == myKey
                  ? 'You'
                  : (context.read<ContactService>().getContact(k)?.displayName ?? '${k.substring(0, 8)}…'),
              onSuggest: (text) => context.read<FeedService>().suggest(post.id, text),
            ),
          if (post.isReshare)
            ReshareCard(
              post: post,
              nameFor: (k) => k == myKey
                  ? 'You'
                  : (context.read<ContactService>().getContact(k)?.displayName ?? '${k.substring(0, 8)}…'),
            ),
          if (post.isPoll)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(post.payload?['question'] as String? ?? post.content,
                  style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            ),
          if (post.isEvent)
            EventCard(
              post: post,
              myKey: myKey,
              nameFor: (k) => k == myKey
                  ? 'You'
                  : (context.read<ContactService>().getContact(k)?.displayName ?? '${k.substring(0, 8)}…'),
              onRsvp: (status) => context.read<FeedService>().rsvp(post.id, status),
              isHost: context.read<FeedService>().isEventHost(post),
              onEdit: () => _editEvent(context, post),
              onAddPhoto: () => _addEventPhoto(context, post),
              onReminders: () => _pickReminders(context, post),
              onCalendar: () => _addToCalendar(context, post),
              onExport: () => _exportIcs(context, post),
              onOpenPhoto: (ref) => context.push('/media/view?ref=${Uri.encodeComponent(ref)}'),
              hasReminder: context.watch<LibraryService>().eventReminders(post.id).isNotEmpty,
            ),
          if (post.isPoll)
            FeedPollCard(
              post: post,
              myKey: myKey,
              nameFor: (k) => k == myKey
                  ? 'You'
                  : (context.read<ContactService>().getContact(k)?.displayName ?? '${k.substring(0, 8)}…'),
              onVote: (choices) => context.read<FeedService>().votePost(post.id, choices),
            ),

          // ── Media ──────────────────────────────────────────
          if (post.mediaRefs.isNotEmpty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onDoubleTap: _onDoubleTap,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _buildMediaSection(post.mediaRefs),
                  if (_showHeart)
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.5, end: 1.0),
                      duration: const Duration(milliseconds: 300),
                      builder: (context, scale, child) {
                        return Transform.scale(scale: scale, child: child);
                      },
                      child: Icon(
                        Icons.favorite,
                        color: Colors.white.withValues(alpha: 0.9),
                        size: 80,
                      ),
                    ),
                ],
              ),
            ),
          ],

          // ── Like / reaction counts ─────────────────────────
          if (post.likes.isNotEmpty || post.reactions.isNotEmpty || post.visibleComments(myKey).isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  if (post.reactions.isNotEmpty) ...[
                    Expanded(child: ReactionTally(reactions: post.reactions)),
                  ] else if (post.likes.isNotEmpty) ...[
                    Icon(Icons.thumb_up, size: 16, color: cs.primary),
                    const SizedBox(width: 4),
                    Text('${post.likes.length}', style: theme.textTheme.bodySmall),
                    const Spacer(),
                  ] else ...[
                    const Spacer(),
                  ],
                  if (post.visibleComments(myKey).isNotEmpty)
                    GestureDetector(
                      onTap: () => context.push('/post/${post.id}'),
                      child: Text(
                        '${post.visibleComments(myKey).length} comment${post.visibleComments(myKey).length == 1 ? '' : 's'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),

          // ── Divider ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Divider(color: cs.outline, height: 20),
          ),

          // ── Like / Comment / Share action row ──────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                // Like button — tap to react 👍, long-press for full picker
                Expanded(
                  child: GestureDetector(
                    onLongPress: () => showReactionPicker(context,
                        current: post.reactions
                            .where((r) => r.reactorId == myKey)
                            .firstOrNull
                            ?.emoji,
                        onPick: (e) => context.read<FeedService>().reactToPost(post.id, e)),
                    child: _ActionButton(
                      icon: _selfReactionIcon(post, myKey),
                      label: _selfReactionLabel(post, myKey),
                      color: _hasSelfReaction(post, myKey)
                          ? cs.primary
                          : cs.onSurfaceVariant,
                      onTap: () {
                        final selfReaction = post.reactions
                            .where((r) => r.reactorId == myKey)
                            .toList();
                        if (selfReaction.isNotEmpty && selfReaction.first.emoji == '👍') {
                          // Already liked with 👍 — toggle off
                          context.read<FeedService>().reactToPost(post.id, '👍');
                        } else {
                          // React with 👍
                          context.read<FeedService>().reactToPost(post.id, '👍');
                        }
                      },
                    ),
                  ),
                ),
                _ActionButton(
                  icon: Icons.chat_bubble_outline,
                  label: 'Comment',
                  color: cs.onSurfaceVariant,
                  onTap: () => _showCommentSheet(context, post),
                ),
                _ActionButton(
                  icon: Icons.share_outlined,
                  label: 'Share',
                  color: cs.onSurfaceVariant,
                  onTap: () {},
                ),
              ],
            ),
          ),

          // ── Comments preview ───────────────────────────────
          if (post.visibleComments(myKey).isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in post.visibleComments(myKey).reversed.take(2))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: RichText(
                        text: TextSpan(
                          style: theme.textTheme.bodyMedium,
                          children: [
                            TextSpan(
                              text:
                                  '${authorNameFor(context, authorId: c.authorId, carried: c.authorName)} ',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            TextSpan(text: c.text),
                          ],
                        ),
                      ),
                    ),
                  if (post.visibleComments(myKey).length > 2)
                    GestureDetector(
                      onTap: () => context.push('/post/${post.id}'),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'View all ${post.visibleComments(myKey).length} comments',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ),
                ],
              ),
            ),

          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildMediaSection(List<String> refs) {
    if (refs.length == 1) {
      return _mediaImage(refs[0], width: double.infinity, height: 350);
    }
    // Grid for multiple images
    return SizedBox(
      height: 300,
      child: Row(
        children: [
          Expanded(child: _mediaImage(refs[0], height: 300)),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _mediaImage(refs.length > 1 ? refs[1] : refs[0])),
                if (refs.length > 2) ...[
                  const SizedBox(height: 2),
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _mediaImage(refs[2]),
                        if (refs.length > 3)
                          Container(
                            color: Colors.black45,
                            alignment: Alignment.center,
                            child: Text(
                              '+${refs.length - 3}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaImage(String ref, {double? width, double? height}) {
    final post = widget.post;
    final index = post.mediaRefs.indexOf(ref);
    final alt = index >= 0 && index < post.altTexts.length ? post.altTexts[index] : '';
    final provenance = MediaProvenance.at(post.provenance, index);
    final blurred = context.watch<LibraryService>().blursAnyOf(post.sphereIds);
    final pano = (post.payload?['pano'] as List?)?.contains(index) ?? false;
    final image = Semantics(
      label: alt.isEmpty ? null : alt,
      image: true,
      child: GestureDetector(
        onTap: () => context.push(
            '/media/view?ref=${Uri.encodeComponent(ref)}${pano ? '&pano=1' : ''}'),
        onLongPress: alt.isEmpty
            ? null
            : () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(alt))),
        child: MediaThumb(ref: ref, width: width, height: height),
      ),
    );
    final withBadge = provenance == null && !pano
        ? image
        : Stack(children: [
            image,
            if (provenance != null)
              Positioned(right: 6, bottom: 6, child: ProvenanceBadge(provenance: provenance)),
            if (pano)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                  child: const Text('360°',
                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ),
          ]);
    return BlurGate(blurred: blurred, child: withBadge);
  }

  void _handlePostMenu(BuildContext context, String action, Post post) {
    if (action == 'guide') {
      showAddToGuideDialog(context, post.sphereId, post.id);
      return;
    }
    if (action == 'reshare') {
      _reshare(context, post);
      return;
    }
    if (action == 'profile_pin') {
      final identity = context.read<IdentityService>();
      final pinned = identity.currentIdentity?.pinnedPostIds.contains(post.id) ?? false;
      identity.setPinnedToProfile(post.id, !pinned);
      return;
    }
    if (action == 'archive') {
      final feed = context.read<FeedService>();
      feed.setArchived(post.id, !feed.isArchived(post.id));
      return;
    }
    if (action == 'delete') {
      _confirmDelete(context, post);
      return;
    }
    if (action == 'open') {
      context.push('/post/${post.id}');
      return;
    }
    if (action == 'comments') {
      final feed = context.read<FeedService>();
      final off = !post.commentsOff;
      feed.setCommentsOff(post.id, off);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(off
              ? 'Comments are off; existing ones stay'
              : 'Comments are on again')));
      return;
    }
    if (action == 'notify') {
      final feed = context.read<FeedService>();
      final on = !feed.postNotifies(post);
      feed.setPostNotifications(post.id, on);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(on
              ? 'You will be told about comments and reactions here'
              : 'No more notifications for this post')));
      return;
    }
    if (action == 'save') {
      final library = context.read<LibraryService>();
      final wasSaved = library.isSaved(post.id);
      library.toggleSave(post.id);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(wasSaved ? 'Removed from saved' : 'Saved'),
        duration: const Duration(seconds: 2),
      ));
      return;
    }

    switch (action) {
      case 'hide':
        context.read<FeedService>().hidePost(post.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Post hidden'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => context.read<FeedService>().unhidePost(post.id),
            ),
          ),
        );
      case 'edit':
        _editPost(context, post);
      case 'report':
        showReportDialog(context).then((reason) {
          if (reason == null || !context.mounted) return;
          context.read<FeedService>().reportPost(post.id, reason);
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Reported to the admins of this sphere')));
        });
      case 'pin':
        final feed = context.read<FeedService>();
        final pinned = feed.isPinned(post.id);
        feed.setPinned(post.sphereId, post.id, !pinned).then((_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(pinned ? 'Unpinned' : 'Pinned in the sphere')));
          }
        }).catchError((e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
          }
        });
      case 'mute':
        final contacts = context.read<ContactService>();
        final wasMuted = contacts.getContact(post.authorId)?.muted ?? false;
        contacts.toggleMute(post.authorId);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(wasMuted
              ? 'Their posts and notifications are back'
              : 'Their posts leave your feed and they will not notify you'),
        ));
      case 'snooze':
        final contacts = context.read<ContactService>();
        final c = contacts.getContact(post.authorId);
        if (c?.isSnoozed ?? false) {
          contacts.unsnooze(post.authorId);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Snooze ended')));
        } else {
          contacts.snooze(post.authorId);
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Quiet for 30 days, then back by themselves')));
        }
      case 'unfollow':
        final contacts = context.read<ContactService>();
        final wasFollowing = contacts.getContact(post.authorId)?.following ?? true;
        contacts.toggleFollow(post.authorId);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(wasFollowing
              ? 'Unfollowed; their posts leave your feed'
              : 'Following again'),
        ));
    }
  }

  Future<void> _editPost(BuildContext context, Post post) async {
    final controller = TextEditingController(text: post.content);
    final feed = context.read<FeedService>();
    final messenger = ScaffoldMessenger.of(context);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit post'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          minLines: 2,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (text == null) return;
    try {
      await feed.editPost(post.id, text);
      messenger.showSnackBar(
          const SnackBar(content: Text('Edited; everyone in the sphere sees the change')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not edit: $e')));
    }
  }

  // ── Emoji / reaction helpers ──────────────────────────────

  bool _hasSelfReaction(Post post, String? myKey) =>
      myKey != null && post.reactions.any((r) => r.reactorId == myKey);

  IconData _selfReactionIcon(Post post, String? myKey) {
    if (_hasSelfReaction(post, myKey)) return Icons.emoji_emotions;
    return Icons.thumb_up_outlined;
  }

  String _selfReactionLabel(Post post, String? myKey) {
    final selfReaction =
        post.reactions.where((r) => r.reactorId == myKey).toList();
    if (selfReaction.isNotEmpty) {
      return ReactionKinds.labelFor(selfReaction.first.emoji);
    }
    return 'Like';
  }

  Future<void> _confirmDelete(BuildContext context, Post post) async {
    final feed = context.read<FeedService>();
    final mine = post.authorId == context.read<IdentityService>().publicKey;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this post?'),
        content: Text(mine
            ? 'Everyone in its spheres is told to drop it. You can restore it from the trash for thirty days.'
            : 'As an admin you remove it for everyone in the sphere. Nothing is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await feed.deletePost(post.id);
  }

  Future<void> _reshare(BuildContext context, Post post) async {
    final spheres = context.read<SphereService>().spheres
        .where((s) => !post.sphereIds.contains(s.id))
        .toList();
    final feed = context.read<FeedService>();
    final messenger = ScaffoldMessenger.of(context);
    if (spheres.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('It is already in every sphere you are in')));
      return;
    }
    final chosen = <String>{};
    final note = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Share to another sphere'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  post.authorSig != null
                      ? 'The author\'s signed words travel with it; pictures are re-uploaded by you.'
                      : 'This post is not signed, so readers are told the attribution is your word.',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                for (final s in spheres)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: chosen.contains(s.id),
                    title: Text(s.name),
                    onChanged: (v) => setDialogState(() {
                      if (v == true) {
                        chosen.add(s.id);
                      } else {
                        chosen.remove(s.id);
                      }
                    }),
                  ),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Say something (optional)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: chosen.isEmpty ? null : () => Navigator.pop(ctx, true),
                child: const Text('Share')),
          ],
        ),
      ),
    );
    if (go != true) return;
    try {
      await feed.resharePost(post.id, targets: chosen, note: note.text.trim());
      messenger.showSnackBar(const SnackBar(content: Text('Shared')));
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // ── Events ──────────────────────────────────────────────

  Future<void> _editEvent(BuildContext context, Post post) async {
    final feed = context.read<FeedService>();
    final p = post.payload ?? const {};
    final me = context.read<IdentityService>().publicKey;
    final spheres = context.read<SphereService>();
    final contacts = context.read<ContactService>();
    final members = <String>{};
    for (final id in post.sphereIds) {
      members.addAll(spheres.sphere(id)?.members.map((m) => m.identityKey) ?? const []);
    }
    final draft = await showEventDialog(
      context,
      initial: EventDraft(
        title: p['title'] as String? ?? '',
        startsAt: DateTime.tryParse(p['starts_at'] as String? ?? '') ?? DateTime.now(),
        endsAt: DateTime.tryParse(p['ends_at'] as String? ?? ''),
        place: p['place'] as String? ?? '',
        ticketUrl: p['ticket_url'] as String? ?? '',
        recurrence: p['recurrence'] as String? ?? 'none',
        coHosts: FeedService.coHostsOf(post),
      ),
      candidates: [
        for (final k in members)
          if (k != post.authorId) (k, contacts.getContact(k)?.displayName ?? '${k.substring(0, 8)}…'),
      ],
      canPickHosts: post.authorId == me,
    );
    if (draft == null) return;
    await feed.updateEvent(post.id, {
      'title': draft.title,
      'starts_at': draft.startsAt.toIso8601String(),
      'ends_at': draft.endsAt?.toIso8601String(),
      'place': draft.place,
      'ticket_url': draft.ticketUrl,
      'recurrence': draft.recurrence,
      if (post.authorId == me) 'co_hosts': draft.coHosts,
    });
  }

  Future<void> _addEventPhoto(BuildContext context, Post post) async {
    final feed = context.read<FeedService>();
    final path = await context.read<MediaService>().pickAndStoreImage();
    if (path != null) await feed.addEventPhoto(post.id, path);
  }

  Future<void> _pickReminders(BuildContext context, Post post) async {
    final library = context.read<LibraryService>();
    final notifications = context.read<NotificationService>();
    final chosen = Set<int>.from(library.eventReminders(post.id));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Remind me'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Shown by this phone, at the time; nothing is sent.',
                  style: TextStyle(fontSize: 12)),
              for (final m in EventReminders.choices)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: chosen.contains(m),
                  title: Text(EventReminders.labelFor(m)),
                  onChanged: (v) => setDialogState(() {
                    if (v == true) {
                      chosen.add(m);
                    } else {
                      chosen.remove(m);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Done')),
          ],
        ),
      ),
    );
    if (ok == true) {
      await EventReminders.set(
          post: post, minutesBefore: chosen.toList(), library: library, notifications: notifications);
    }
  }

  Future<void> _addToCalendar(BuildContext context, Post post) async {
    final messenger = ScaffoldMessenger.of(context);
    final p = post.payload ?? const {};
    final next = EventReminders.nextStart(post);
    final starts = next ?? DateTime.tryParse(p['starts_at'] as String? ?? '') ?? DateTime.now();
    final ends = DateTime.tryParse(p['ends_at'] as String? ?? '');
    try {
      await CalendarBridge.insert(
        title: p['title'] as String? ?? 'Event',
        starts: starts,
        ends: ends == null ? null : starts.add(ends.difference(DateTime.parse(p['starts_at'] as String))),
        place: p['place'] as String? ?? '',
        description: post.content,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _exportIcs(BuildContext context, Post post) async {
    final messenger = ScaffoldMessenger.of(context);
    final p = post.payload ?? const {};
    final starts = DateTime.tryParse(p['starts_at'] as String? ?? '');
    if (starts == null) return;
    final ics = EventTime.ics(
      uid: '${post.id}@spheres',
      title: p['title'] as String? ?? 'Event',
      starts: starts,
      ends: DateTime.tryParse(p['ends_at'] as String? ?? ''),
      place: p['place'] as String? ?? '',
      description: post.content,
      recurrence: p['recurrence'] as String? ?? 'none',
      url: p['ticket_url'] as String? ?? '',
    );
    try {
      await CalendarBridge.shareIcs(fileName: 'spheres-event-${post.id.substring(0, 8)}.ics', contents: ics);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  // ── Comment sheet with reply threading ──────────────────

  void _showCommentSheet(BuildContext context, Post post) {
    final controller = TextEditingController();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    String? replyToId;
    String? replyToName;
    // What this viewer may see; hidden comments stay with their writer.
    final visible =
        post.visibleComments(context.read<IdentityService>().publicKey);

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
            // Build threaded comment list: top-level first, then replies indented
            final topLevel =
                visible.where((c) => c.replyToId == null).toList();

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              builder: (ctx, scrollController) {
                return Column(
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Comments',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontSize: 16)),
                        const SizedBox(width: 8),
                        // React, edit, hide, pin and the rest live on the
                        // full thread; this sheet is for a quick word.
                        TextButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            context.push('/post/${post.id}');
                          },
                          icon: const Icon(Icons.open_in_full, size: 16),
                          label: const Text('Full thread',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    const Divider(),
                    Expanded(
                      child: visible.isEmpty
                          ? Center(
                              child: Text('No comments yet. Be the first!',
                                  style: theme.textTheme.bodySmall),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              itemCount: topLevel.length,
                              itemBuilder: (ctx, i) {
                                final c = topLevel[i];
                                final replies = visible
                                    .where((r) => r.replyToId == c.id)
                                    .toList();
                                return _CommentThread(
                                  comment: c,
                                  replies: replies,
                                  onReply: (comment) {
                                    setSheetState(() {
                                      replyToId = comment.id;
                                      replyToName = authorNameFor(context,
                                          authorId: comment.authorId,
                                          carried: comment.authorName);
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                    // Reply indicator
                    if (replyToId != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        color: cs.surfaceContainerHighest,
                        child: Row(
                          children: [
                            Text('Replying to $replyToName',
                                style: theme.textTheme.bodySmall),
                            const Spacer(),
                            GestureDetector(
                              onTap: () => setSheetState(() {
                                replyToId = null;
                                replyToName = null;
                              }),
                              child: Icon(Icons.close,
                                  size: 16, color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    // Input
                    Container(
                      padding: EdgeInsets.fromLTRB(
                          16, 8, 8, MediaQuery.of(ctx).viewInsets.bottom + 8),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        border: Border(top: BorderSide(color: cs.outline)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              decoration: InputDecoration(
                                hintText: replyToId != null
                                    ? 'Reply to $replyToName...'
                                    : 'Write a comment...',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: cs.surfaceContainerHighest,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                              ),
                              textCapitalization:
                                  TextCapitalization.sentences,
                              autofocus: true,
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon:
                                Icon(Icons.send_rounded, color: cs.primary),
                            onPressed: () {
                              final text = controller.text.trim();
                              if (text.isEmpty) return;
                              context.read<FeedService>().commentOnPost(
                                    post.id,
                                    text,
                                    replyToId: replyToId,
                                  );
                              controller.clear();
                              setSheetState(() {
                                replyToId = null;
                                replyToName = null;
                              });
                              Navigator.pop(ctx);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

// ─── Comment thread widget ───────────────────────────────────────────────────

class _CommentThread extends StatelessWidget {
  final Comment comment;
  final List<Comment> replies;
  final void Function(Comment) onReply;

  const _CommentThread({
    required this.comment,
    required this.replies,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final name = authorNameFor(context,
        authorId: comment.authorId, carried: comment.authorName);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top-level comment
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserAvatar(displayName: name, size: AvatarSize.small),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(comment.text,
                              style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                    // Reply button
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 4),
                      child: GestureDetector(
                        onTap: () => onReply(comment),
                        child: Text('Reply',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 11,
                            )),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Threaded replies (indented)
          for (final reply in replies)
            Padding(
              padding: const EdgeInsets.only(left: 40, top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UserAvatar(
                    displayName: reply.authorName.isNotEmpty
                        ? reply.authorName
                        : reply.authorId,
                    size: AvatarSize.small,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            reply.authorName.isNotEmpty
                                ? reply.authorName
                                : reply.authorId,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(reply.text,
                              style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Action button ───────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
