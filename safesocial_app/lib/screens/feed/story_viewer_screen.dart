import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/post.dart';
import '../../services/chat_service.dart';
import '../../crypto/session_manager.dart';
import '../../services/contact_service.dart';
import '../../services/feed_service.dart';
import '../../services/identity_service.dart';
import '../../widgets/avatar.dart';

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
    _animController.reset();
    _animController.forward();
    _recordView(_currentIndex);
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
                return _buildStoryContent(story);
              },
            ),
            _buildOverlays(),
          ],
        ),
      ),
    );
  }

  Widget _buildStoryContent(Post story) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (story.mediaRefs.isNotEmpty)
          Image.file(
            File(story.mediaRefs.first),
            fit: BoxFit.cover,
          )
        else
          Container(
            color: Colors.deepPurple.shade900,
            alignment: Alignment.center,
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
                      displayName: nameFor(key), size: AvatarSize.small),
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
                UserAvatar(displayName: widget.authorName, size: AvatarSize.small),
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
