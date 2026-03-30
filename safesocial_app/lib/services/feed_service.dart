import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/contact.dart';
import '../models/post.dart';
import 'debug_log_service.dart';
import 'media_service.dart';
import 'relay_service.dart';

/// Manages the social feed with P2P sync via Veilid DHT and fallback relay.
class FeedService extends ChangeNotifier {
  static const _postsKey = 'spheres_feed_posts';
  static const _hiddenKey = 'spheres_hidden_posts';

  final List<Post> _posts = [];
  final Set<String> _hiddenPostIds = {};
  bool _isRefreshing = false;

  final RelayService _feedRelay = RelayService();
  String? _myPublicKey;
  String? _mySecretKey;
  List<Contact> _contacts = [];

  List<Post> get posts =>
      _posts.where((p) => !_hiddenPostIds.contains(p.id) && !p.isStory).toList();

  /// Returns posts from previous years on the same month and day.
  List<Post> get memories {
    final now = DateTime.now();
    return _posts.where((p) =>
      !p.isStory &&
      p.createdAt.month == now.month &&
      p.createdAt.day == now.day &&
      p.createdAt.year < now.year
    ).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Returns unexpired stories grouped by authorId
  Map<String, List<Post>> get storiesByAuthor {
    final now = DateTime.now();
    final activeStories = _posts.where((p) => 
      p.isStory && 
      !_hiddenPostIds.contains(p.id) && 
      (p.expiresAt == null || p.expiresAt!.isAfter(now))
    ).toList();

    final map = <String, List<Post>>{};
    for (var story in activeStories) {
      map.putIfAbsent(story.authorId, () => []).add(story);
    }
    return map;
  }

  List<Post> get allPosts => List.unmodifiable(_posts);
  bool get isRefreshing => _isRefreshing;
  Set<String> get hiddenPostIds => Set.unmodifiable(_hiddenPostIds);


  void initSync(String myPublicKey, String mySecretKey, List<Contact> contacts) {
    _myPublicKey = myPublicKey;
    _mySecretKey = mySecretKey;
    _contacts = contacts;

    _feedRelay.onMessageReceived = (contactKey, data) {
      _handleIncomingFeedItem(contactKey, data);
    };

    for (final contact in contacts.where((c) => !c.blocked)) {
      _feedRelay.connect('feed:$myPublicKey', 'feed:${contact.publicKey}', mySecretKey: _mySecretKey!, authPublicKey: myPublicKey);
    }
  }

  Future<void> loadPosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_postsKey);
      if (json != null) {
        final list = jsonDecode(json) as List<dynamic>;
        _posts.clear();
        final now = DateTime.now();
        
        for (var e in list) {
          final p = Post.fromJson(e as Map<String, dynamic>);
          // Clean up expired stories
          if (p.isStory && p.expiresAt != null && p.expiresAt!.isBefore(now)) {
            continue;
          }
          _posts.add(p);
        }
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

  Future<void> createPost(
    String content, {
    List<String>? mediaRefs, 
    String authorName = 'You', 
    PostAudience audience = PostAudience.everyone,
    bool isStory = false,
    DateTime? expiresAt,
  }) async {
    final post = Post(
      id: const Uuid().v4(),
      authorId: _myPublicKey ?? 'self',
      authorName: authorName,
      content: content,
      mediaRefs: mediaRefs ?? [],
      createdAt: DateTime.now(),
      audience: audience,
      isStory: isStory,
      expiresAt: expiresAt,
    );

    _posts.insert(0, post);
    await _persistPosts();
    notifyListeners();

    if (_myPublicKey != null) {
      final relayPost = await _encodePostMedia(post);
      final postJson = jsonEncode({'type': 'post', 'post': relayPost.toJson()});
      for (final contact in _contacts.where((c) => !c.blocked)) {
        _feedRelay.sendViaRelay('feed:${contact.publicKey}', postJson);
      }
    }
  }

  /// Convenience method to create a 24-hour ephemeral story
  Future<void> createStory(String content, {List<String>? mediaRefs, String authorName = 'You'}) async {
    final expiresAt = DateTime.now().add(const Duration(hours: 24));
    await createPost(
      content,
      mediaRefs: mediaRefs,
      authorName: authorName,
      audience: PostAudience.closeFriends, // Stories default to close friends
      isStory: true,
      expiresAt: expiresAt,
    );
  }

  void _handleIncomingFeedItem(String contactKey, String data) async {
    try {
      final json = jsonDecode(data);
      if (json['type'] == 'post') {
        final post = await _decodePostMedia(Post.fromJson(json['post']));
        _mergePost(post);
      } else if (json['type'] == 'like') {
        final postId = json['post_id'] as String;
        final authorId = json['author_id'] as String;
        final liked = json['liked'] as bool;
        final index = _posts.indexWhere((p) => p.id == postId);
        if (index == -1) return;
        final post = _posts[index];
        final newLikes = List<String>.from(post.likes);
        if (liked) {
          if (!newLikes.contains(authorId)) newLikes.add(authorId);
        } else {
          newLikes.remove(authorId);
        }
        _posts[index] = post.copyWith(likes: newLikes);
        _persistPosts();
        notifyListeners();
      } else if (json['type'] == 'reaction') {
        final postId = json['post_id'] as String;
        final authorId = json['author_id'] as String;
        final emoji = json['emoji'] as String;
        final index = _posts.indexWhere((p) => p.id == postId);
        if (index == -1) return;
        final post = _posts[index];
        final newReactions = List<Reaction>.from(post.reactions);
        final existing = newReactions.indexWhere(
            (r) => r.reactorId == authorId && r.emoji == emoji);
        if (existing != -1) {
          newReactions.removeAt(existing);
        } else {
          newReactions.add(Reaction(reactorId: authorId, emoji: emoji, timestamp: DateTime.now()));
        }
        _posts[index] = post.copyWith(reactions: newReactions);
        _persistPosts();
        notifyListeners();
      }
    } catch (e) {
      DebugLogService().warn('Feed', 'Malformed feed item');
    }
  }


  /// Encode local image paths as base64 data URIs for relay transfer.
  Future<Post> _encodePostMedia(Post post) async {
    if (post.mediaRefs.isEmpty) return post;
    final encoded = <String>[];
    for (final ref in post.mediaRefs) {
      if (ref.startsWith('data:')) {
        encoded.add(ref);
      } else {
        final b64 = await MediaService.encodeImageForRelay(ref);
        if (b64 != null) encoded.add(b64);
      }
    }
    return post.copyWith(mediaRefs: encoded);
  }

  /// Decode base64 data URIs received from relay into local file paths.
  Future<Post> _decodePostMedia(Post post) async {
    if (post.mediaRefs.isEmpty) return post;
    final decoded = <String>[];
    for (final ref in post.mediaRefs) {
      if (ref.startsWith('data:image/')) {
        final localPath = await MediaService.decodeAndSaveImage(ref);
        if (localPath != null) decoded.add(localPath);
      } else {
        decoded.add(ref);
      }
    }
    return post.copyWith(mediaRefs: decoded);
  }

  void _mergePost(Post post) {
    if (_posts.any((p) => p.id == post.id)) return;
    
    // Don't merge if it's already an expired story
    if (post.isStory && post.expiresAt != null && post.expiresAt!.isBefore(DateTime.now())) {
      return;
    }

    int index = _posts.indexWhere((p) => p.createdAt.isBefore(post.createdAt));
    if (index == -1) {
      _posts.add(post);
    } else {
      _posts.insert(index, post);
    }
    _persistPosts();
    notifyListeners();
  }

  void toggleLike(String postId) {
    if (_myPublicKey == null) return;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;
    final post = _posts[index];
    final newLikes = List<String>.from(post.likes);
    final nowLiked = !post.isLikedBySelf;
    if (post.isLikedBySelf) {
      newLikes.remove('self');
    } else {
      newLikes.add('self');
    }
    _posts[index] = post.copyWith(likes: newLikes);
    _persistPosts();
    notifyListeners();

    final likeJson = jsonEncode({
      'type': 'like',
      'post_id': postId,
      'author_id': _myPublicKey,
      'liked': nowLiked,
    });
    for (final contact in _contacts.where((c) => !c.blocked)) {
      _feedRelay.sendViaRelay('feed:${contact.publicKey}', likeJson);
    }
  }

  void commentOnPost(String postId, String text, {String? replyToId}) {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index != -1) {
      final post = _posts[index];
      final newComments = List<Comment>.from(post.comments);
      newComments.add(Comment(
        id: const Uuid().v4(),
        authorId: _myPublicKey ?? 'self',
        authorName: 'You',
        text: text,
        createdAt: DateTime.now(),
        replyToId: replyToId,
      ));
      _posts[index] = post.copyWith(comments: newComments);
      notifyListeners();
    }
  }

  void reactToPost(String postId, String emoji) {
    if (_myPublicKey == null) return;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final newReactions = List<Reaction>.from(post.reactions);
    final existing = newReactions.indexWhere(
        (r) => r.reactorId == _myPublicKey && r.emoji == emoji);

    if (existing != -1) {
      // Toggle off — remove reaction
      newReactions.removeAt(existing);
    } else {
      newReactions.add(Reaction(reactorId: _myPublicKey!, emoji: emoji, timestamp: DateTime.now()));
    }

    _posts[index] = post.copyWith(reactions: newReactions);
    notifyListeners();
    _persistPosts();

    // Broadcast reaction update to contacts
    final reactionJson = jsonEncode({
      'type': 'reaction',
      'post_id': postId,
      'author_id': _myPublicKey,
      'emoji': emoji,
    });
    for (final contact in _contacts.where((c) => !c.blocked)) {
      _feedRelay.sendViaRelay('feed:${contact.publicKey}', reactionJson);
    }
  }

  Future<void> refreshFeed() async {
    _isRefreshing = true;
    notifyListeners();
    
    // Clean up expired stories dynamically during refresh
    final now = DateTime.now();
    bool changed = false;
    _posts.removeWhere((p) {
      if (p.isStory && p.expiresAt != null && p.expiresAt!.isBefore(now)) {
        changed = true;
        return true;
      }
      return false;
    });

    if (changed) {
      await _persistPosts();
    }

    await Future.delayed(const Duration(seconds: 1)); // Simulation
    _isRefreshing = false;
    notifyListeners();
  }

  void hidePost(String postId) {
    _hiddenPostIds.add(postId);
    _persistHidden();
    notifyListeners();
  }

  void unhidePost(String postId) {
    _hiddenPostIds.remove(postId);
    _persistHidden();
    notifyListeners();
  }

  Future<void> _persistHidden() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey, _hiddenPostIds.toList());
  }

  Future<void> _persistPosts() async {
    final prefs = await SharedPreferences.getInstance();
    // Only persist non-expired stories
    final now = DateTime.now();
    final validPosts = _posts.where((p) => !(p.isStory && p.expiresAt != null && p.expiresAt!.isBefore(now)));
    await prefs.setString(_postsKey, jsonEncode(validPosts.take(100).map((e) => e.toJson()).toList()));
  }
}
