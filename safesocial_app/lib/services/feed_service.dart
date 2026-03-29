import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:veilid/veilid.dart';

import '../models/contact.dart';
import '../models/post.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';
import 'veilid_service.dart';

/// Manages the social feed with P2P sync via Veilid DHT and fallback relay.
class FeedService extends ChangeNotifier {
  static const _postsKey = 'spheres_feed_posts';
  static const _hiddenKey = 'spheres_hidden_posts';

  VeilidService? _veilidService;
  final List<Post> _posts = [];
  final Set<String> _hiddenPostIds = {};
  bool _isRefreshing = false;

  final RelayService _feedRelay = RelayService();
  String? _myPublicKey;
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

  void attachVeilidService(VeilidService vs) {
    _veilidService = vs;
  }

  void initSync(String myPublicKey, List<Contact> contacts) {
    _myPublicKey = myPublicKey;
    _contacts = contacts;

    _feedRelay.onMessageReceived = (contactKey, data) {
      _handleIncomingFeedItem(contactKey, data);
    };

    for (final contact in contacts.where((c) => !c.blocked)) {
      _feedRelay.connect('feed:$myPublicKey', 'feed:${contact.publicKey}');
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
      final postJson = jsonEncode({'type': 'post', 'post': post.toJson()});
      for (final contact in _contacts.where((c) => !c.blocked)) {
        _feedRelay.sendViaRelay(contact.publicKey, postJson);
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

  void _handleIncomingFeedItem(String contactKey, String data) {
    try {
      final json = jsonDecode(data);
      if (json['type'] == 'post') {
        _mergePost(Post.fromJson(json['post']));
      }
    } catch (e) {
      DebugLogService().warn('Feed', 'Malformed feed item');
    }
  }

  void handleValueChange(RecordKey key, List<ValueSubkeyRange> subkeys) {
    // DHT update handling
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
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index != -1) {
      final post = _posts[index];
      final newLikes = List<String>.from(post.likes);
      if (post.isLikedBySelf) {
        newLikes.remove('self');
      } else {
        newLikes.add('self');
      }
      _posts[index] = post.copyWith(likes: newLikes);
      notifyListeners();
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
    // Reaction implementation
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
