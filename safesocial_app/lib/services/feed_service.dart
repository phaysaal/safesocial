import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/contact.dart';
import '../models/post.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

/// Manages the social feed with relay-based sync between contacts.
///
/// When you create a post, it's broadcast to all contacts via the relay.
/// When contacts' posts arrive via relay, they're merged into the feed.
class FeedService extends ChangeNotifier {
  static const _postsKey = 'spheres_feed_posts';
  static const _hiddenKey = 'spheres_hidden_posts';

  final List<Post> _posts = [];
  final Set<String> _hiddenPostIds = {};
  bool _isRefreshing = false;

  final RelayService _feedRelay = RelayService();
  String? _myPublicKey;
  List<Contact> _contacts = [];

  List<Post> get posts =>
      _posts.where((p) => !_hiddenPostIds.contains(p.id)).toList();

  List<Post> get allPosts => List.unmodifiable(_posts);
  bool get isRefreshing => _isRefreshing;
  Set<String> get hiddenPostIds => Set.unmodifiable(_hiddenPostIds);

  /// Initialize feed sync — connect relay for each contact's feed channel.
  void initSync(String myPublicKey, List<Contact> contacts) {
    _myPublicKey = myPublicKey;
    _contacts = contacts;

    _feedRelay.onMessageReceived = (contactKey, data) {
      _handleIncomingFeedItem(contactKey, data);
    };

    // Connect a feed-specific relay room for each contact
    for (final contact in contacts.where((c) => !c.blocked)) {
      _feedRelay.connect(
        'feed:$myPublicKey',
        'feed:${contact.publicKey}',
      );
    }
    DebugLogService().info('Feed', 'Sync initialized for ${contacts.length} contacts');
  }

  /// Load persisted posts and hidden IDs.
  Future<void> loadPosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_postsKey);
      if (json != null) {
        final list = jsonDecode(json) as List<dynamic>;
        _posts.clear();
        _posts.addAll(
          list.map((e) => Post.fromJson(e as Map<String, dynamic>)),
        );
      }
      final hiddenJson = prefs.getStringList(_hiddenKey);
      if (hiddenJson != null) {
        _hiddenPostIds.addAll(hiddenJson);
      }
    } catch (e) {
      debugPrint('[FeedService] Failed to load posts: $e');
    }
    notifyListeners();
  }

  /// Create a new post and broadcast to contacts via relay.
  Future<void> createPost(
    String content, {
    List<String>? mediaRefs,
    String authorName = 'You',
    PostAudience audience = PostAudience.everyone,
  }) async {
    final post = Post(
      id: const Uuid().v4(),
      authorId: _myPublicKey ?? 'self',
      authorName: authorName,
      content: content,
      mediaRefs: mediaRefs ?? [],
      createdAt: DateTime.now(),
      audience: audience,
    );

    _posts.insert(0, post);
    await _persistPosts();
    notifyListeners();

    // Broadcast to contacts via relay
    if (_myPublicKey != null) {
      final postJson = jsonEncode({
        'type': 'post',
        'data': post.toJson(),
      });
      for (final contact in _contacts.where((c) => !c.blocked)) {
        _feedRelay.sendViaRelay('feed:${contact.publicKey}', postJson);
      }
      DebugLogService().success('Feed', 'Post broadcast to ${_contacts.length} contacts');
    }
  }

  /// Handle incoming post/like/comment from a contact via relay.
  void _handleIncomingFeedItem(String contactKey, String data) {
    try {
      final payload = jsonDecode(data) as Map<String, dynamic>;
      final type = payload['type'] as String?;

      switch (type) {
        case 'post':
          final postData = payload['data'] as Map<String, dynamic>;
          final post = Post.fromJson(postData);
          // Skip duplicates
          if (_posts.any((p) => p.id == post.id)) return;
          _posts.insert(0, post);
          _posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
          _persistPosts();
          DebugLogService().success('Feed', 'Received post from ${post.authorName}');
          notifyListeners();

        case 'like':
          final postId = payload['post_id'] as String;
          final userId = payload['user_id'] as String;
          final index = _posts.indexWhere((p) => p.id == postId);
          if (index != -1 && !_posts[index].likes.contains(userId)) {
            _posts[index] = _posts[index].copyWith(
              likes: [..._posts[index].likes, userId],
            );
            _persistPosts();
            notifyListeners();
          }

        case 'comment':
          final postId = payload['post_id'] as String;
          final comment = Comment.fromJson(payload['comment'] as Map<String, dynamic>);
          final index = _posts.indexWhere((p) => p.id == postId);
          if (index != -1 && !_posts[index].comments.any((c) => c.id == comment.id)) {
            _posts[index] = _posts[index].copyWith(
              comments: [..._posts[index].comments, comment],
            );
            _persistPosts();
            notifyListeners();
          }

        case 'reaction':
          final postId = payload['post_id'] as String;
          final reaction = Reaction.fromJson(payload['reaction'] as Map<String, dynamic>);
          final index = _posts.indexWhere((p) => p.id == postId);
          if (index != -1) {
            _posts[index] = _posts[index].copyWith(
              reactions: [..._posts[index].reactions, reaction],
            );
            _persistPosts();
            notifyListeners();
          }
      }
    } catch (e) {
      DebugLogService().error('Feed', 'Failed to process incoming feed item: $e');
    }
  }

  /// Toggle like — also broadcasts to contacts.
  Future<void> toggleLike(String postId) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final liked = post.likes.contains('self');
    final userId = _myPublicKey ?? 'self';
    final newLikes = liked
        ? post.likes.where((id) => id != 'self' && id != userId).toList()
        : [...post.likes, userId];

    _posts[index] = post.copyWith(likes: newLikes);
    await _persistPosts();
    notifyListeners();

    // Broadcast like to post author
    if (!liked && post.authorId != 'self' && post.authorId != _myPublicKey) {
      final payload = jsonEncode({
        'type': 'like',
        'post_id': postId,
        'user_id': userId,
      });
      _feedRelay.sendViaRelay('feed:${post.authorId}', payload);
    }
  }

  /// Add comment — also broadcasts to post author.
  Future<void> commentOnPost(
    String postId,
    String text, {
    String authorName = 'You',
    String? replyToId,
  }) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final comment = Comment(
      id: const Uuid().v4(),
      authorId: _myPublicKey ?? 'self',
      authorName: authorName,
      text: text,
      createdAt: DateTime.now(),
      replyToId: replyToId,
    );

    _posts[index] = post.copyWith(
      comments: [...post.comments, comment],
    );
    await _persistPosts();
    notifyListeners();

    // Broadcast comment to post author
    if (post.authorId != 'self' && post.authorId != _myPublicKey) {
      final payload = jsonEncode({
        'type': 'comment',
        'post_id': postId,
        'comment': comment.toJson(),
      });
      _feedRelay.sendViaRelay('feed:${post.authorId}', payload);
    }
  }

  /// Refresh feed.
  Future<void> refreshFeed({List<Contact>? contacts}) async {
    _isRefreshing = true;
    notifyListeners();

    try {
      await loadPosts();
      _posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      debugPrint('[FeedService] Feed refresh failed: $e');
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Add reaction — also broadcasts.
  Future<void> reactToPost(String postId, String emoji) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final userId = _myPublicKey ?? 'self';

    final existing = post.reactions.indexWhere(
      (r) => (r.reactorId == 'self' || r.reactorId == userId) && r.emoji == emoji,
    );
    List<Reaction> newReactions;
    if (existing != -1) {
      newReactions = [...post.reactions]..removeAt(existing);
    } else {
      newReactions = post.reactions
          .where((r) => r.reactorId != 'self' && r.reactorId != userId)
          .toList();
      final reaction = Reaction(
        reactorId: userId,
        emoji: emoji,
        timestamp: DateTime.now(),
      );
      newReactions.add(reaction);

      // Broadcast to post author
      if (post.authorId != 'self' && post.authorId != _myPublicKey) {
        _feedRelay.sendViaRelay(
          'feed:${post.authorId}',
          jsonEncode({'type': 'reaction', 'post_id': postId, 'reaction': reaction.toJson()}),
        );
      }
    }

    _posts[index] = post.copyWith(reactions: newReactions);
    await _persistPosts();
    notifyListeners();
  }

  Future<void> hidePost(String postId) async {
    _hiddenPostIds.add(postId);
    await _persistHidden();
    notifyListeners();
  }

  Future<void> unhidePost(String postId) async {
    _hiddenPostIds.remove(postId);
    await _persistHidden();
    notifyListeners();
  }

  Future<void> _persistHidden() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_hiddenKey, _hiddenPostIds.toList());
    } catch (e) {
      debugPrint('[FeedService] Failed to persist hidden posts: $e');
    }
  }

  Future<void> _persistPosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _postsKey,
        jsonEncode(_posts.map((p) => p.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[FeedService] Failed to persist posts: $e');
    }
  }
}
