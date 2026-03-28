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
      _posts.where((p) => !_hiddenPostIds.contains(p.id)).toList();

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
        _posts.addAll(list.map((e) => Post.fromJson(e as Map<String, dynamic>)));
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

  Future<void> createPost(String content, {List<String>? mediaRefs, String authorName = 'You', PostAudience audience = PostAudience.everyone}) async {
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

    if (_myPublicKey != null) {
      final postJson = jsonEncode({'type': 'post', 'post': post.toJson()});
      for (final contact in _contacts.where((c) => !c.blocked)) {
        _feedRelay.sendViaRelay(contact.publicKey, postJson);
      }
    }
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
    await prefs.setString(_postsKey, jsonEncode(_posts.take(100).map((e) => e.toJson()).toList()));
  }
}
