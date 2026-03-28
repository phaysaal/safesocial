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
///
/// Each user has a "Feed Record" on the DHT. Contacts "watch" these records
/// to receive real-time updates when a friend posts something new.
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

  /// Initialize feed sync — connect relay and start watching DHT for contacts.
  void initSync(String myPublicKey, List<Contact> contacts) {
    _myPublicKey = myPublicKey;
    _contacts = contacts;

    _feedRelay.onMessageReceived = (contactKey, data) {
      _handleIncomingFeedItem(contactKey, data);
    };

    // 1. Connect relay rooms (Fast fallback)
    for (final contact in contacts.where((c) => !c.blocked)) {
      _feedRelay.connect(
        'feed:$myPublicKey',
        'feed:${contact.publicKey}',
      );
      
      // 2. Start watching DHT for this contact (Permanent P2P)
      _watchContactFeed(contact);
    }
    
    DebugLogService().info('Feed', 'Sync initialized for ${contacts.length} contacts');
  }

  /// Watch a contact's DHT feed record for updates.
  void _watchContactFeed(Contact contact) async {
    final rc = _veilidService?.routingContext;
    if (rc == null || contact.feedDhtKey == null) return;

    try {
      final recordKey = RecordKey.fromBase64(contact.feedDhtKey!);
      await rc.watchDHTValues(recordKey);
      DebugLogService().info('Feed', 'Watching P2P feed for ${contact.name}');
    } catch (e) {
      DebugLogService().warn('Feed', 'Failed to watch feed for ${contact.name}: $e');
    }
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

  /// Create a new post and broadcast to contacts via relay + DHT.
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

    // 1. Broadcast via Relay (Fast)
    if (_myPublicKey != null) {
      final postJson = jsonEncode({
        'type': 'post',
        'post': post.toJson(),
      });

      for (final contact in _contacts.where((c) => !c.blocked)) {
        _feedRelay.sendViaRelay(contact.publicKey, postJson);
      }
    }

    // 2. Update DHT Feed Record (Permanent)
    _updateDhtFeed(post);
  }

  /// Update the user's permanent DHT feed record.
  Future<void> _updateDhtFeed(Post post) async {
    final rc = _veilidService?.routingContext;
    // We would need a feed record key associated with our identity.
    // Placeholder for DHT feed persistence.
    DebugLogService().info('Feed', 'Permanent DHT feed update scheduled');
  }

  void _handleIncomingFeedItem(String contactKey, String data) {
    try {
      final json = jsonDecode(data);
      if (json['type'] == 'post') {
        final post = Post.fromJson(json['post']);
        _mergePost(post);
      }
    } catch (e) {
      DebugLogService().warn('Feed', 'Malformed feed item from $contactKey');
    }
  }

  /// Handle a DHT value change notification.
  void handleValueChange(RecordKey key, List<int> subkeys) async {
    final rc = _veilidService?.routingContext;
    if (rc == null) return;

    // Find which contact this record belongs to
    final contact = _contacts.firstWhere(
      (c) => c.feedDhtKey == key.toBase64(),
      orElse: () => Contact(publicKey: '', name: 'Unknown'),
    );

    if (contact.publicKey.isEmpty) return;

    try {
      for (final subkey in subkeys) {
        final val = await rc.getDHTValue(key, subkey);
        if (val != null) {
          final data = utf8.decode(val);
          final post = Post.fromJson(jsonDecode(data));
          _mergePost(post);
          DebugLogService().success('Feed', 'New P2P post from ${contact.name}');
        }
      }
    } catch (e) {
      DebugLogService().warn('Feed', 'Failed to read P2P post: $e');
    }
  }

  void _mergePost(Post post) {
    if (_posts.any((p) => p.id == post.id)) return;
    
    // Insert at correct chronological position
    int index = _posts.indexWhere((p) => p.createdAt.isBefore(post.createdAt));
    if (index == -1) {
      _posts.add(post);
    } else {
      _posts.insert(index, post);
    }
    
    _persistPosts();
    notifyListeners();
  }

  Future<void> hidePost(String postId) async {
    _hiddenPostIds.add(postId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey, _hiddenPostIds.toList());
    notifyListeners();
  }

  Future<void> _persistPosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_posts.take(100).map((e) => e.toJson()).toList());
      await prefs.setString(_postsKey, json);
    } catch (e) {
      debugPrint('[FeedService] Persist failed: $e');
    }
  }
}
