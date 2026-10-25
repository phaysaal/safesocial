import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';

import '../../models/look.dart';
import '../../models/post.dart';
import '../../widgets/looked.dart';
import '../../services/chat_service.dart';
import '../../crypto/session_manager.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../services/media_service.dart';
import '../../widgets/avatar.dart';
import '../../widgets/media_thumb.dart';
import '../../widgets/post_extras.dart';
import 'story_archive_screen.dart';

/// Full-screen viewer for 24-hour ephemeral stories.
class StoryViewerScreen extends StatefulWidget {
  final List<Post> stories;
  final String authorName;
  final int initialIndex;

  const StoryViewerScreen({
    super.key,
    required this.stories,
    required this.authorName,
    this.initialIndex = 0,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> with SingleTickerProviderStateMixin {
  late PageController _pageController;
  late AnimationController _animController;
  final _replyController = TextEditingController();
  int _currentIndex = 0;
  bool _sendingReply = false;
  static const Duration _storyDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    
    _animController = AnimationController(vsync: this, duration: _storyDuration);
    _animController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _nextStory();
      }
    });
    _animController.forward();
    _recordView(_currentIndex);
  }

  /// Tell the author we watched, once per story.
  void _recordView(int index) {
    if (index < 0 || index >= widget.stories.length) return;
    final story = widget.stories[index];
    // Fire and forget: a receipt must never hold up the viewer.
    context.read<FeedService>().markStoryViewed(story.id);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _animController.dispose();
    _replyController.dispose();
    super.dispose();
  }

  void _nextStory() {
    if (_currentIndex < widget.stories.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      // Reached the end of this user's stories
      context.pop();
    }
  }

  void _previousStory() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      // Already at the first story, restart progress
      _animController.reset();
      _animController.forward();
    }
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _recordView(index);
    });
    _animController
      ..duration = _storyDuration
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: (details) {
          final screenWidth = MediaQuery.of(context).size.width;
          if (details.globalPosition.dx < screenWidth / 3) {
            _previousStory();
          } else {
            _nextStory();
          }
        },
        onLongPressDown: (_) => _animController.stop(),
        onLongPressUp: () => _animController.forward(),
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(), // Handle taps manually
              onPageChanged: _onPageChanged,
              itemCount: widget.stories.length,
              itemBuilder: (context, index) {
                final story = widget.stories[index];
                return _buildStoryContent(story, index);
              },
            ),
            _buildOverlays(),
          ],
        ),
      ),
    );
  }

  /// A video story runs for as long as the clip; everything else for the
  /// default five seconds.
  void _useVideoDuration(int index, Duration duration) {
    if (!mounted || index != _currentIndex) return;
    final clamped = duration < const Duration(seconds: 1)
        ? _storyDuration
        : (duration > const Duration(seconds: 60)
            ? const Duration(seconds: 60)
            : duration);
    _animController
      ..stop()
      ..duration = clamped
      ..reset()
      ..forward();
  }

  Widget _buildStoryContent(Post story, int index) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (story.mediaRefs.isNotEmpty)
          Looked(
            look: Look.forIndex(story.payload, 0),
            child: _StoryMedia(
              ref: story.mediaRefs.first,
              active: index == _currentIndex,
              loop: story.payload?['loop'] == true,
              onVideoDuration: (d) => _useVideoDuration(index, d),
            ),
          )
        else
          Container(
            color: Colors.deepPurple.shade900,
            alignment: Alignment.center,
          ),
        
        if (story.payload?['sticker'] is Map)
          Align(
            alignment: const Alignment(0, 0.45),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: StorySticker(
                sticker: (story.payload!['sticker'] as Map).cast<String, dynamic>(),
                onOpenLink: (url) async {
                  final messenger = ScaffoldMessenger.of(context);
                  final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
                  if (!ok) messenger.showSnackBar(const SnackBar(content: Text('Nothing on this device opens that link')));
                },
                onAnswer: story.authorId == context.read<IdentityService>().publicKey
                    ? null
                    : (answer) async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await context.read<ChatService>().sendMessage(
                                story.authorId, answer, replyToStoryId: story.id);
                          messenger.showSnackBar(
                              const SnackBar(content: Text('Sent privately to the author')));
                        } catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text('Could not send: $e')));
                        }
                      },
              ),
            ),
          ),
        if (story.content.isNotEmpty)
          Align(
            alignment: Alignment.center,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              color: Colors.black45,
              child: Text(
                story.content,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Reply privately to the story's author.
  ///
  /// A story reply is a direct message, not a comment the sphere can see —
  /// which also means it travels on the ratcheted path and gets the forward
  /// secrecy that sphere-sealed content does not.
  Future<void> _sendReply() async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _sendingReply) return;

    final story = widget.stories[_currentIndex];
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _sendingReply = true);
    try {
      await context.read<ChatService>().sendMessage(
            story.authorId,
            text,
            replyToStoryId: story.id,
          );
      _replyController.clear();
      if (mounted) FocusScope.of(context).unfocus();
      messenger.showSnackBar(
        const SnackBar(content: Text('Reply sent'), duration: Duration(seconds: 2)),
      );
    } on NoSessionException {
      messenger.showSnackBar(const SnackBar(
        content: Text(
          'Cannot encrypt to them yet — their encryption key has not arrived.',
        ),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not send: $e')));
    } finally {
      if (mounted) setState(() => _sendingReply = false);
      if (mounted) _animController.forward();
    }
  }

  /// Composer shown under someone else's story.
  Widget _buildReplyBar() {
    final me = context.watch<IdentityService>().publicKey;
    final story = widget.stories[_currentIndex];
    if (me == null || story.authorId == me) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        4,
        12,
        12 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _replyController,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendReply(),
              // Pause the countdown while typing, or the story advances
              // mid-sentence.
              onTap: () => _animController.stop(),
              decoration: InputDecoration(
                hintText: 'Reply privately…',
                hintStyle: const TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Colors.white12,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          IconButton(
            icon: _sendingReply
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.send_rounded, color: Colors.white),
            onPressed: _sendingReply ? null : _sendReply,
          ),
        ],
      ),
    );
  }

  /// Viewer count, shown only on our own stories.
  ///
  /// Sphere members do not learn who else watched — a receipt goes to the
  /// author alone.
  Post get _current => widget.stories[_currentIndex];
  bool get _isMine {
    final me = context.read<IdentityService>().publicKey;
    return me != null && _current.authorId == me;
  }

  Widget _buildViewerBar() {
    final me = context.watch<IdentityService>().publicKey;
    final story = widget.stories[_currentIndex];
    if (me == null || story.authorId != me) return const SizedBox.shrink();

    final viewers = context.watch<FeedService>().viewersOf(story.id);

    return GestureDetector(
      onTap: viewers.isEmpty ? null : () => _showViewers(viewers),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Row(
          children: [
            const Icon(Icons.visibility_outlined,
                color: Colors.white70, size: 18),
            const SizedBox(width: 8),
            Text(
              viewers.isEmpty
                  ? 'No views yet'
                  : '${viewers.length} view${viewers.length == 1 ? '' : 's'}',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  void _showViewers(List<String> viewers) {
    _animController.stop();
    final contacts = context.read<ContactService>().contacts;

    String nameFor(String key) {
      for (final contact in contacts) {
        if (contact.publicKey == key) return contact.displayName;
      }
      return '${key.substring(0, 8)}…';
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Viewed by',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ...viewers.map((key) => ListTile(
                  dense: true,
                  leading: UserAvatar(
                      displayName: nameFor(key), identityKey: key, size: AvatarSize.small),
                  title: Text(nameFor(key)),
                )),
          ],
        ),
      ),
    ).whenComplete(() {
      if (mounted) _animController.forward();
    });
  }

  Widget _buildOverlays() {
    return SafeArea(
      child: Column(
        children: [
          // Progress bars
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: List.generate(
                widget.stories.length,
                (index) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: AnimatedBuilder(
                      animation: _animController,
                      builder: (context, child) {
                        double progress = 0.0;
                        if (index < _currentIndex) {
                          progress = 1.0;
                        } else if (index == _currentIndex) {
                          progress = _animController.value;
                        }
                        return LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.white.withValues(alpha: 0.3),
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                          minHeight: 2,
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Header info
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Hero(tag: 'story:${widget.authorName}', child: UserAvatar(displayName: widget.authorName, identityKey: _current.authorId, size: AvatarSize.small)),
                const SizedBox(width: 8),
                Text(
                  widget.authorName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                  ),
                ),
                const Spacer(),
          _buildViewerBar(),
          _buildReplyBar(),
                if (_isMine && _current.mediaRefs.isNotEmpty && !MediaService.looksLikeVideo(_current.mediaRefs.first))
                  IconButton(
                    tooltip: 'Add to a highlight',
                    icon: const Icon(Icons.auto_awesome_outlined,
                        color: Colors.white, shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                    onPressed: () => showHighlightPicker(context, _current.mediaRefs.first),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                  onPressed: () => context.pop(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The picture or clip behind a story.
///
/// A local image fills the screen; a local video plays while its page is the
/// active one and reports its length so the progress bar matches; a blob that
/// has not been fetched yet shows its inline thumbnail rather than nothing.
class _StoryMedia extends StatefulWidget {
  final String ref;
  final bool active;

  /// A loop clip plays round and round for the story's whole time.
  final bool loop;
  final void Function(Duration) onVideoDuration;

  const _StoryMedia({
    required this.ref,
    required this.active,
    this.loop = false,
    required this.onVideoDuration,
  });

  @override
  State<_StoryMedia> createState() => _StoryMediaState();
}

class _StoryMediaState extends State<_StoryMedia> {
  VideoPlayerController? _video;

  bool get _isLocalVideo =>
      MediaService.looksLikeVideo(widget.ref) && File(widget.ref).existsSync();

  @override
  void initState() {
    super.initState();
    if (_isLocalVideo) _start();
  }

  Future<void> _start() async {
    final controller = VideoPlayerController.file(File(widget.ref));
    try {
      await controller.initialize();
    } catch (_) {
      await controller.dispose();
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _video = controller);
    if (widget.loop) {
      await controller.setLooping(true);
      // A loop is a story of the usual length, not of the clip's.
      widget.onVideoDuration(const Duration(seconds: 6));
    } else {
      widget.onVideoDuration(controller.value.duration);
    }
    if (widget.active) await controller.play();
  }

  @override
  void didUpdateWidget(covariant _StoryMedia old) {
    super.didUpdateWidget(old);
    final v = _video;
    if (v == null) return;
    if (widget.active && !old.active) {
      v.seekTo(Duration.zero);
      v.play();
      widget.onVideoDuration(widget.loop ? const Duration(seconds: 6) : v.value.duration);
    } else if (!widget.active && old.active) {
      v.pause();
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    if (v != null && v.value.isInitialized) {
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: v.value.size.width,
          height: v.value.size.height,
          child: VideoPlayer(v),
        ),
      );
    }
    if (!_isLocalVideo && File(widget.ref).existsSync()) {
      return Image.file(File(widget.ref), fit: BoxFit.cover);
    }
    return MediaThumb(ref: widget.ref, fit: BoxFit.cover, showPlayBadge: false);
  }
}
