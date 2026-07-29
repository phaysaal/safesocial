import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../crypto/session_manager.dart';
import '../models/contact.dart';
import '../models/post.dart';
import 'debug_log_service.dart';
import 'media_service.dart';
import 'relay_service.dart';
import 'sphere_service.dart';

/// Manages the social feed with P2P sync via Veilid DHT and fallback relay.
class FeedService extends ChangeNotifier {
  static const _postsKey = 'spheres_feed_posts';
  static const _hiddenKey = 'spheres_hidden_posts';

  final List<Post> _posts = [];
  final Set<String> _hiddenPostIds = {};
  bool _isRefreshing = false;

  final RelayService _feedRelay = RelayService();
  String? _myPublicKey;
  List<Contact> _contacts = [];

  /// The home feed: the union of posts across the spheres you belong to.
  ///
  /// A post whose sphere we are not in is not shown even if it reached this
  /// device — after leaving a sphere its content disappears from the feed
  /// rather than lingering because it happens to be in local storage. The
  /// feed used to display whatever arrived, with no scoping at all.
  List<Post> get posts => _visible(_posts.where((p) => !p.isStory));

  /// Posts limited to one sphere.
  List<Post> postsIn(String sphereId) =>
      _visible(_posts.where((p) => !p.isStory && p.sphereId == sphereId));

  List<Post> _visible(Iterable<Post> source) {
    final spheres = _spheres;
    return source.where((p) {
      if (_hiddenPostIds.contains(p.id)) return false;
      if (spheres == null) return false;
      final sphere = spheres.sphere(p.sphereId);
      if (sphere == null) return false;
      // Only show authors who are still members. A former member's old posts
      // stay readable to those who were there, but do not keep appearing as if
      // they were still in the sphere.
      return sphere.contains(p.authorId);
    }).toList();
  }

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
    // Sphere-scoped like the rest of the feed.
    final activeStories = _visible(_posts.where((p) =>
        p.isStory && (p.expiresAt == null || p.expiresAt!.isAfter(now))));

    final map = <String, List<Post>>{};
    for (var story in activeStories) {
      map.putIfAbsent(story.authorId, () => []).add(story);
    }
    return map;
  }

  List<Post> get allPosts => List.unmodifiable(_posts);
  bool get isRefreshing => _isRefreshing;
  Set<String> get hiddenPostIds => Set.unmodifiable(_hiddenPostIds);


  SessionManager? _sessions;
  SphereService? _spheres;
  String? Function(String identityKey)? _resolveExchangeKey;

  /// Receives sealed `album_add` envelopes that arrive on the feed channels.
  Future<void> Function(String sealed)? onAlbumItem;

  /// Supply the crypto context so feed channels get pairwise addresses and
  /// content can be sealed to a sphere.
  void attachCrypto(
    SessionManager sessions,
    String? Function(String identityKey) resolveExchangeKey, {
    SphereService? spheres,
  }) {
    _sessions = sessions;
    _resolveExchangeKey = resolveExchangeKey;
    if (spheres != null) _spheres = spheres;
  }

  /// Seal a payload to a sphere and deliver it to that sphere's members.
  ///
  /// Feed traffic used to go out as plain `jsonEncode`, so the relay operator
  /// could read every post, like and reaction — including the base64 photos
  /// inlined in posts.
  Future<void> _publishToSphere({
    required String sphereId,
    required String type,
    required String payloadJson,
  }) async {
    final spheres = _spheres;
    if (spheres == null) return;

    final sphere = spheres.sphere(sphereId);
    if (sphere == null) {
      DebugLogService()
          .warn('Feed', 'Cannot publish to unknown sphere $sphereId');
      return;
    }

    final String sealed;
    try {
      sealed = await spheres.sealContent(
        sphereId: sphereId,
        type: type,
        plaintext: payloadJson,
      );
    } catch (e) {
      DebugLogService().error('Feed', 'Could not seal $type: $e');
      return;
    }

    final blocked =
        _contacts.where((c) => c.blocked).map((c) => c.publicKey).toSet();
    for (final member in sphere.members.map((m) => m.identityKey)) {
      if (member == _myPublicKey || blocked.contains(member)) continue;
      _feedRelay.sendViaRelay(member, sealed);
    }
  }

  Future<void> _connectFeedMailbox(String contactKey) async {
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final mailbox = await sessions.mailboxFor(
        peerIdentityKey: contactKey,
        peerKeyExchangePublicKey: _resolveExchangeKey?.call(contactKey),
        purpose: 'feed',
      );
      await _feedRelay.connectMailbox(contactKey, mailbox);
    } on NoSessionException {
      // Nothing to connect to until the contact publishes an encryption key.
    }
  }

  void initSync(String myPublicKey, String mySecretKey, List<Contact> contacts) {
    _myPublicKey = myPublicKey;
    _contacts = contacts;

    _feedRelay.onMessageReceived = (contactKey, data) {
      _handleIncomingFeedItem(contactKey, data);
    };

    for (final contact in contacts.where((c) => !c.blocked)) {
      _connectFeedMailbox(contact.publicKey);
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

  /// Publish a post to one sphere.
  ///
  /// [sphereId] is required and [audienceMembers] is the sphere's member list.
  /// Delivery goes to exactly those people. Previously this fanned out to every
  /// non-blocked contact regardless of the chosen audience, so a "close
  /// friends" story reached everyone — the audience only ever drew a badge.
  Future<void> createPost(
    String content, {
    required String sphereId,
    required List<String> audienceMembers,
    List<String>? mediaRefs,
    String authorName = 'You',
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
      sphereId: sphereId,
      isStory: isStory,
      expiresAt: expiresAt,
    );

    _posts.insert(0, post);
    await _persistPosts();
    notifyListeners();

    if (_myPublicKey == null) return;

    final relayPost = await _encodePostMedia(post);
    await _publishToSphere(
      sphereId: sphereId,
      type: 'post',
      payloadJson: jsonEncode({'type': 'post', 'post': relayPost.toJson()}),
    );
  }

  /// A 24-hour ephemeral post, scoped to a sphere like everything else.
  Future<void> createStory(
    String content, {
    required String sphereId,
    required List<String> audienceMembers,
    List<String>? mediaRefs,
    String authorName = 'You',
  }) async {
    await createPost(
      content,
      sphereId: sphereId,
      audienceMembers: audienceMembers,
      mediaRefs: mediaRefs,
      authorName: authorName,
      isStory: true,
      expiresAt: DateTime.now().add(const Duration(hours: 24)),
    );
  }

  void _handleIncomingFeedItem(String contactKey, String data) async {
    final spheres = _spheres;
    if (spheres == null) return;

    try {
      // Verifies the signature, checks the author is a member of the sphere,
      // and decrypts. Anything that fails throws rather than being displayed.
      final opened = await spheres.openContent(data);
      final authorId = opened.from;
      final json = jsonDecode(opened.plaintext);

      if (json['type'] == 'album_add') {
        // Album items ride the same per-member channels as feed content.
        await onAlbumItem?.call(data);
        return;
      }

      if (json['type'] == 'post') {
        final post = await _decodePostMedia(Post.fromJson(json['post']));

        // Authorship and audience both come from the verified envelope, not
        // from fields in the payload that the sender could set freely.
        if (post.authorId != authorId || post.sphereId != opened.sphereId) {
          DebugLogService().warn(
              'Feed', 'Dropping post: payload disagrees with signed envelope');
          return;
        }
        _mergePost(post);
      } else if (json['type'] == 'like') {
        final postId = json['post_id'] as String;
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
      } else if (json['type'] == 'comment') {
        final comment = Comment.fromJson(json['comment']);
        if (comment.authorId != authorId) {
          DebugLogService()
              .warn('Feed', 'Dropping comment: author disagrees with signature');
          return;
        }
        _applyComment(json['post_id'] as String, comment);
      } else if (json['type'] == 'reaction') {
        final postId = json['post_id'] as String;
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
      DebugLogService().warn('Feed', 'Rejected feed item from $contactKey: $e');
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
    final me = _myPublicKey;
    if (me == null) return;
    final nowLiked = !post.isLikedBy(me);
    if (!nowLiked) {
      newLikes.remove(me);
    } else {
      newLikes.add(me);
    }
    _posts[index] = post.copyWith(likes: newLikes);
    _persistPosts();
    notifyListeners();

    // A reaction goes only to the sphere the post belongs to.
    _publishToSphere(
      sphereId: post.sphereId,
      type: 'like',
      payloadJson: jsonEncode({
        'type': 'like',
        'post_id': postId,
        'liked': nowLiked,
      }),
    );
  }

  /// Add a comment, save it, and send it to the sphere.
  ///
  /// This previously did none of those last two things: it updated the list in
  /// memory and called notifyListeners, so comments vanished on restart and
  /// were never seen by anyone else, including the post's author.
  Future<void> commentOnPost(String postId, String text,
      {String? replyToId, String authorName = 'You'}) async {
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

    _posts[index] = post.copyWith(comments: [...post.comments, comment]);
    await _persistPosts();
    notifyListeners();

    await _publishToSphere(
      sphereId: post.sphereId,
      type: 'comment',
      payloadJson: jsonEncode({
        'type': 'comment',
        'post_id': postId,
        'comment': comment.toJson(),
      }),
    );
  }

  void _applyComment(String postId, Comment comment) {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;
    if (_posts[index].comments.any((c) => c.id == comment.id)) return;

    _posts[index] = _posts[index].copyWith(
      comments: [..._posts[index].comments, comment]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
    _persistPosts();
    notifyListeners();
  }

  void reactToPost(String postId, String emoji) {
    final me = _myPublicKey;
    if (me == null) return;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final newReactions = List<Reaction>.from(post.reactions);
    // Reactions are stored under our real key so they survive a restart and
    // match what peers see.
    final existing = newReactions.indexWhere(
        (r) => r.reactorId == me && r.emoji == emoji);

    if (existing != -1) {
      // Toggle off — remove reaction
      newReactions.removeAt(existing);
    } else {
      // Remove any previous reaction from self before adding new one
      newReactions.removeWhere((r) => r.reactorId == me);
      newReactions.add(Reaction(reactorId: me, emoji: emoji, timestamp: DateTime.now()));
    }

    _posts[index] = post.copyWith(reactions: newReactions);
    notifyListeners();
    _persistPosts();

    _publishToSphere(
      sphereId: post.sphereId,
      type: 'reaction',
      payloadJson: jsonEncode({
        'type': 'reaction',
        'post_id': postId,
        'emoji': emoji,
      }),
    );
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
