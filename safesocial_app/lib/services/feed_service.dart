import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/contact.dart';
import '../models/post.dart';

/// Manages the social feed — creating, reading, reacting to, liking, and
/// commenting on posts.
///
/// Persists posts to SharedPreferences for offline access. On refresh,
/// merges any new posts from contacts into the timeline.
class FeedService extends ChangeNotifier {
  static const _postsKey = 'spheres_feed_posts';
  static const _hiddenKey = 'spheres_hidden_posts';

  final List<Post> _posts = [];
  final Set<String> _hiddenPostIds = {};
  bool _isRefreshing = false;

  /// All visible posts in the feed, newest first.
  /// Filters out hidden posts. Muted/unfollowed contacts are filtered
  /// by the UI layer which has access to ContactService.
  List<Post> get posts =>
      _posts.where((p) => !_hiddenPostIds.contains(p.id)).toList();

  /// All posts including hidden (for profile grid, etc.)
  List<Post> get allPosts => List.unmodifiable(_posts);

  bool get isRefreshing => _isRefreshing;
  Set<String> get hiddenPostIds => Set.unmodifiable(_hiddenPostIds);

  /// Load persisted posts and hidden IDs from SharedPreferences.
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

  /// Create a new post with the given content and optional media references.
  Future<void> createPost(
    String content, {
    List<String>? mediaRefs,
    String authorName = 'You',
    PostAudience audience = PostAudience.everyone,
  }) async {
    final post = Post(
      id: const Uuid().v4(),
      authorId: 'self',
      authorName: authorName,
      content: content,
      mediaRefs: mediaRefs ?? [],
      createdAt: DateTime.now(),
      audience: audience,
    );

    _posts.insert(0, post);
    await _persistPosts();
    notifyListeners();
  }

  /// Toggle like on a post.
  Future<void> toggleLike(String postId) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final liked = post.likes.contains('self');
    final newLikes = liked
        ? post.likes.where((id) => id != 'self').toList()
        : [...post.likes, 'self'];

    _posts[index] = post.copyWith(likes: newLikes);
    await _persistPosts();
    notifyListeners();
  }

  /// Add a comment to a post.
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
      authorId: 'self',
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
  }

  /// Refresh the feed — reload persisted posts and simulate fetching
  /// contacts' updates. When Veilid is connected, this will poll contacts'
  /// DHT records for new posts.
  Future<void> refreshFeed({List<Contact>? contacts}) async {
    _isRefreshing = true;
    notifyListeners();

    try {
      // Reload persisted posts (picks up any changes)
      await loadPosts();

      // In the real Veilid implementation, this would:
      // for (final contact in contacts) {
      //   final profileKey = contact.profileDhtKey;
      //   final feedKeys = await rc.getDHTValue(profileKey, feedSubkey);
      //   for (final postKey in feedKeys) {
      //     final postData = await rc.getDHTValue(postKey, 0);
      //     // merge into _posts if not already present
      //   }
      // }

      // Sort by newest first
      _posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      debugPrint('[FeedService] Feed refresh failed: $e');
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  /// Add a reaction to a post.
  Future<void> reactToPost(String postId, String emoji) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];

    // Toggle: remove if same emoji from self already exists
    final existing = post.reactions.indexWhere(
      (r) => r.reactorId == 'self' && r.emoji == emoji,
    );
    List<Reaction> newReactions;
    if (existing != -1) {
      newReactions = [...post.reactions]..removeAt(existing);
    } else {
      // Remove any other reaction from self first, then add new
      newReactions = post.reactions.where((r) => r.reactorId != 'self').toList();
      newReactions.add(Reaction(
        reactorId: 'self',
        emoji: emoji,
        timestamp: DateTime.now(),
      ));
    }

    _posts[index] = post.copyWith(reactions: newReactions);
    await _persistPosts();
    notifyListeners();
  }

  /// Hide a post from the feed.
  Future<void> hidePost(String postId) async {
    _hiddenPostIds.add(postId);
    await _persistHidden();
    notifyListeners();
  }

  /// Unhide a previously hidden post.
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
