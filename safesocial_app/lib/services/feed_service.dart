import 'dart:async';
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'secure_store.dart';
import 'package:uuid/uuid.dart';

import '../crypto/blob.dart';
import '../crypto/envelope.dart';
import '../crypto/session_manager.dart';
import '../models/contact.dart';
import '../models/event_time.dart';
import '../models/media_provenance.dart';
import '../models/post.dart';
import '../models/sphere.dart';
import 'chat_service.dart';
import 'debug_log_service.dart';
import 'inbound_events.dart';
import 'outbox_service.dart';
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
  String? _mySecretKey;
  List<Contact> _contacts = [];

  /// Who not to send to, asked fresh every time.
  ///
  /// The local list is a snapshot taken at startup — it has to be a copy,
  /// because connectContact appends to it — so reading `blocked` from it meant
  /// blocking someone had no effect on posts until the app restarted. Blocking
  /// is a decision that should take hold immediately, so its source is the
  /// address book itself rather than a stale copy of it.
  Set<String> Function()? blockedKeys;

  /// Our own display name, read fresh each time.
  ///
  /// Comments used to default to the literal string 'You', and neither caller
  /// passed anything else — so that string was stored and sent, and every
  /// reader saw their own word for themselves against somebody else's comment.
  /// A name that travels has to be the author's actual name; deciding whether
  /// to render it as "You" belongs to whoever is reading.
  String Function()? myDisplayName;

  String get _authorName {
    final name = myDisplayName?.call().trim();
    return (name == null || name.isEmpty) ? 'Someone' : name;
  }

  /// Who is skipped when fanning content out.
  Set<String> get blockedForSending =>
      blockedKeys?.call() ??
      _contacts.where((c) => c.blocked).map((c) => c.publicKey).toSet();

  /// The home feed: the union of posts across the spheres you belong to.
  ///
  /// A post whose sphere we are not in is not shown even if it reached this
  /// device — after leaving a sphere its content disappears from the feed
  /// rather than lingering because it happens to be in local storage. The
  /// feed used to display whatever arrived, with no scoping at all.
  List<Post> get posts =>
      _visible(_posts.where((p) => !p.isStory && !_archivedIds.contains(p.id)));

  /// Posts limited to one sphere.
  List<Post> postsIn(String sphereId) {
    final visible = _visible(
        _posts.where((p) => !p.isStory && p.sphereIds.contains(sphereId)));
    final pins = _pinned[sphereId];
    if (pins == null || pins.isEmpty) return visible;
    final pinned = pins.map((id) => visible.where((p) => p.id == id)).expand((p) => p);
    return [...pinned, ...visible.where((p) => !pins.contains(p.id))];
  }

  /// Sphere ids the user has muted. Supplied by the app so FeedService need
  /// not depend on LibraryService.
  Set<String> Function()? mutedSpheres;

  /// Members the user has muted within a sphere, by sphere id. Their posts stay
  /// stored and stay readable to everyone else; they just do not show here.
  Set<String> Function(String sphereId)? mutedMembers;

  /// Contacts who are muted, snoozed or on a break, and contacts unfollowed:
  /// their posts stay stored and leave the feed. Supplied by the app. "Mute
  /// this person" and "Unfollow" on a post set flags nothing read before.
  Set<String> Function()? quietAuthors;
  Set<String> Function()? unfollowedAuthors;

  /// With data saver on, a post's pictures are not fetched when it arrives;
  /// the inline thumbnail shows and the full picture loads when tapped.
  bool Function()? dataSaver;

  /// The user's hidden-words filter. Local; a hidden post is still stored.
  bool Function(String text)? hidesText;

  List<Post> _visible(Iterable<Post> source) {
    final spheres = _spheres;
    final muted = mutedSpheres?.call() ?? const <String>{};
    return source.where((p) {
      if (_hiddenPostIds.contains(p.id)) return false;
      if (spheres == null) return false;
      if (p.authorId != _myPublicKey) {
        if (hidesText?.call(p.content) ?? false) return false;
        if (quietAuthors?.call().contains(p.authorId) ?? false) return false;
        if (unfollowedAuthors?.call().contains(p.authorId) ?? false) return false;
      }
      // Visible through any sphere we are still in and have not muted.
      final through = p.sphereIds
          .where((id) => !muted.contains(id))
          .map(spheres.sphere)
          .whereType<Sphere>();
      if (through.isEmpty) return false;
      final sphere = through.first;
      // Only show authors who are still members. A former member's old posts
      // stay readable to those who were there, but do not keep appearing as if
      // they were still in the sphere.
      if (!sphere.contains(p.authorId)) return false;
      // Muted in every sphere it reaches us through: hidden. Muted in one of
      // several: still shown, through the others.
      return through.any(
          (sp) => !(mutedMembers?.call(sp.id) ?? const <String>{}).contains(p.authorId));
    }).toList();
  }

  // ── Events, polls, co-authors ─────────────────────────────────────────────

  /// An event is a post with a time and a place; RSVPs are signed items that
  /// every device tallies for itself.
  Future<void> createEvent({
    required Set<String> sphereIds,
    required List<String> audienceMembers,
    required String title,
    required DateTime startsAt,
    DateTime? endsAt,
    String place = '',
    List<String> coHosts = const [],
    String recurrence = 'none',
    String ticketUrl = '',
    String details = '',
    String? authorName,
  }) =>
      createPost(
        details,
        sphereIds: sphereIds,
        audienceMembers: audienceMembers,
        authorName: authorName,
        kind: 'event',
        payload: {
          'title': title,
          'starts_at': startsAt.toIso8601String(),
          if (endsAt != null) 'ends_at': endsAt.toIso8601String(),
          'place': place,
          'rsvps': <String, dynamic>{},
          if (coHosts.isNotEmpty) 'co_hosts': coHosts,
          if (recurrence != 'none') 'recurrence': recurrence,
          if (ticketUrl.isNotEmpty) 'ticket_url': ticketUrl,
          'photos': <dynamic>[],
        },
      );

  /// going · maybe · no · (empty to withdraw)
  Future<void> rsvp(String postId, String status) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1 || !_posts[index].isEvent) return;
    _applyRsvp(index, me, status);
    for (final sphereId in _posts[index].sphereIds) {
      await _publishToSphere(
        sphereId: sphereId,
        type: 'event_rsvp',
        payloadJson: jsonEncode({'type': 'event_rsvp', 'post_id': postId, 'status': status}),
      );
    }
  }

  void _applyRsvp(int index, String who, String status) {
    final payload = Map<String, dynamic>.from(_posts[index].payload ?? {});
    final rsvps = Map<String, dynamic>.from(payload['rsvps'] as Map? ?? {});
    if (status.isEmpty) {
      rsvps.remove(who);
    } else if (const {'going', 'interested', 'maybe', 'no'}.contains(status)) {
      rsvps[who] = status;
    } else {
      return;
    }
    payload['rsvps'] = rsvps;
    _posts[index] = _posts[index].copyWith(payload: payload);
    _persistPosts();
    notifyListeners();
  }

  Future<void> createPollPost({
    required Set<String> sphereIds,
    required List<String> audienceMembers,
    required String question,
    required List<String> options,
    bool multiple = false,
    bool anonymous = false,
    String? authorName,
  }) =>
      createPost(
        question,
        sphereIds: sphereIds,
        audienceMembers: audienceMembers,
        authorName: authorName,
        kind: 'poll',
        payload: {
          'question': question,
          'options': options,
          'multiple': multiple,
          'anonymous': anonymous,
          'votes': <String, dynamic>{},
        },
      );

  Future<void> votePost(String postId, List<int> choices) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1 || !_posts[index].isPoll) return;
    _applyPostVote(index, me, choices);
    for (final sphereId in _posts[index].sphereIds) {
      await _publishToSphere(
        sphereId: sphereId,
        type: 'post_vote',
        payloadJson: jsonEncode({'type': 'post_vote', 'post_id': postId, 'choices': choices}),
      );
    }
  }

  void _applyPostVote(int index, String voter, List<int> choices) {
    final post = _posts[index];
    final payload = Map<String, dynamic>.from(post.payload ?? {});
    final count = (payload['options'] as List?)?.length ?? 0;
    var valid = choices.where((c) => c >= 0 && c < count).toSet().toList()..sort();
    if (payload['multiple'] != true && valid.length > 1) valid = [valid.first];
    final votes = Map<String, dynamic>.from(payload['votes'] as Map? ?? {});
    final key = payload['anonymous'] == true ? ChatService.voterHash(voter, post.id) : voter;
    if (valid.isEmpty) {
      votes.remove(key);
    } else {
      votes[key] = valid;
    }
    payload['votes'] = votes;
    _posts[index] = post.copyWith(payload: payload);
    _persistPosts();
    notifyListeners();
  }

  /// Confirm being a co-author of a post that names us.
  Future<void> acceptCoAuthorship(String postId) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1 || !_posts[index].coAuthors.contains(me)) return;
    _applyCoAuthor(index, me);
    for (final sphereId in _posts[index].sphereIds) {
      await _publishToSphere(
        sphereId: sphereId,
        type: 'coauthor_accept',
        payloadJson: jsonEncode({'type': 'coauthor_accept', 'post_id': postId}),
      );
    }
  }

  void _applyCoAuthor(int index, String who) {
    final post = _posts[index];
    if (!post.coAuthors.contains(who) || post.acceptedCoAuthors.contains(who)) return;
    _posts[index] = post.copyWith(acceptedCoAuthors: [...post.acceptedCoAuthors, who]);
    _persistPosts();
    notifyListeners();
  }

  // ── Drafts and scheduled posts ────────────────────────────────────────────

  static const _draftsKey = 'spheres_drafts_v1';
  final List<Map<String, dynamic>> _drafts = [];
  List<Map<String, dynamic>> get drafts => List.unmodifiable(_drafts);

  /// Members of each sphere, for publishing a draft later. Set by the app.
  List<String> Function(String sphereId)? membersOf;

  Future<String> saveDraft({
    String? id,
    required String content,
    List<String> mediaRefs = const [],
    required Set<String> sphereIds,
    DateTime? scheduledFor,
    String kind = 'post',
    Map<String, dynamic>? payload,
    List<String> altTexts = const [],
  }) async {
    final draftId = id ?? const Uuid().v4();
    _drafts.removeWhere((d) => d['id'] == draftId);
    _drafts.insert(0, {
      'id': draftId,
      'content': content,
      'mediaRefs': mediaRefs,
      'sphereIds': sphereIds.toList(),
      if (scheduledFor != null) 'scheduledFor': scheduledFor.toIso8601String(),
      'kind': kind,
      if (payload != null) 'payload': payload,
      if (altTexts.isNotEmpty) 'altTexts': altTexts,
      'savedAt': DateTime.now().toIso8601String(),
    });
    await _persistDrafts();
    notifyListeners();
    return draftId;
  }

  Future<void> deleteDraft(String id) async {
    _drafts.removeWhere((d) => d['id'] == id);
    await _persistDrafts();
    notifyListeners();
  }

  /// Post a draft now, whatever its schedule.
  Future<void> publishDraft(String id) async {
    final draft = _drafts.firstWhere((d) => d['id'] == id, orElse: () => const {});
    if (draft.isEmpty) return;
    final sphereIds = (draft['sphereIds'] as List).cast<String>().toSet();
    final audience = <String>{};
    for (final sid in sphereIds) {
      audience.addAll(membersOf?.call(sid) ?? const []);
    }
    if (audience.isEmpty) throw StateError('None of the chosen spheres exist any more');
    await createPost(
      draft['content'] as String? ?? '',
      sphereIds: sphereIds,
      audienceMembers: audience.toList(),
      mediaRefs: (draft['mediaRefs'] as List?)?.cast<String>(),
      kind: draft['kind'] as String? ?? 'post',
      payload: (draft['payload'] as Map?)?.cast<String, dynamic>(),
      altTexts: (draft['altTexts'] as List?)?.cast<String>() ?? const [],
    );
    await deleteDraft(id);
  }

  /// Publish anything whose scheduled time has come. Runs on a timer.
  Future<void> publishDueDrafts() async {
    final now = DateTime.now();
    for (final draft in List<Map<String, dynamic>>.from(_drafts)) {
      final at = DateTime.tryParse(draft['scheduledFor'] as String? ?? '');
      if (at == null || at.isAfter(now)) continue;
      try {
        await publishDraft(draft['id'] as String);
      } catch (e) {
        DebugLogService().error('Feed', 'Scheduled post failed: $e');
      }
    }
  }

  Timer? _draftTimer;

  Future<void> _persistDrafts() =>
      SecureStore.instance.setString(_draftsKey, jsonEncode(_drafts));

  // ── Reports to the sphere ─────────────────────────────────────────────────

  static const _reportsKey = 'spheres_reports_v1';

  /// Sphere id -> reports its admins have received. Only admins keep them.
  final Map<String, List<Map<String, dynamic>>> _reports = {};
  List<Map<String, dynamic>> reportsFor(String sphereId) =>
      List.unmodifiable(_reports[sphereId] ?? const []);

  /// Flag a post to the admins of the sphere it appeared in. There is no outside
  /// authority to send it to; the sphere is the authority.
  Future<void> reportPost(String postId, String reason) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;
    for (final sphereId in _posts[index].sphereIds) {
      await _publishToSphere(
        sphereId: sphereId,
        type: 'report',
        payloadJson: jsonEncode({'type': 'report', 'post_id': postId, 'reason': reason}),
      );
    }
  }

  Future<void> dismissReport(String sphereId, String postId, String by) async {
    _reports[sphereId]?.removeWhere((r) => r['post_id'] == postId && r['by'] == by);
    await SecureStore.instance.setString(_reportsKey, jsonEncode(_reports));
    notifyListeners();
  }

  // ── Editing ───────────────────────────────────────────────────────────────

  /// Change the text of one of our own posts, everywhere it was shared.
  Future<void> editPost(String postId, String content) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1) return;
    final post = _posts[index];
    if (post.authorId != me) {
      throw StateError('Only the author can edit a post');
    }
    final trimmed = content.trim();
    if (trimmed == post.content) return;
    final editedAt = DateTime.now();
    final edited = post.copyWith(content: trimmed, editedAt: editedAt);
    _posts[index] = edited.copyWith(authorSig: _signCore(edited));
    await _persistPosts();
    notifyListeners();

    final payload = jsonEncode({
      'type': 'post_edit',
      'post_id': postId,
      'content': trimmed,
      'edited_at': editedAt.toIso8601String(),
      'sig': _posts[index].authorSig,
    });
    for (final sphereId in post.sphereIds) {
      await _publishToSphere(sphereId: sphereId, type: 'post_edit', payloadJson: payload);
    }
  }

  // ── Pinning posts in a sphere ─────────────────────────────────────────────

  static const _pinnedPostsKey = 'spheres_pinned_posts_v1';

  /// Sphere id -> pinned post ids, newest pin first. Set by that sphere's
  /// admins; everyone sees the same pins.
  final Map<String, List<String>> _pinned = {};

  List<String> pinnedIn(String sphereId) =>
      List.unmodifiable(_pinned[sphereId] ?? const []);

  bool isPinned(String postId) => _pinned.values.any((ids) => ids.contains(postId));

  /// Pin or unpin a post in one sphere. Admins only; the receiving side checks
  /// the same thing against the signature, so a non-admin's pin goes nowhere.
  Future<void> setPinned(String sphereId, String postId, bool pinned) async {
    final me = _myPublicKey;
    final sphere = _spheres?.sphere(sphereId);
    if (me == null || sphere == null) return;
    if (!sphere.isAdmin(me)) throw StateError('Only an admin can pin a post');
    _applyPin(sphereId, postId, pinned);
    await _publishToSphere(
      sphereId: sphereId,
      type: 'post_pin',
      payloadJson: jsonEncode({'type': 'post_pin', 'post_id': postId, 'pinned': pinned}),
    );
  }

  void _applyPin(String sphereId, String postId, bool pinned) {
    final list = _pinned.putIfAbsent(sphereId, () => []);
    list.remove(postId);
    if (pinned) list.insert(0, postId);
    if (list.isEmpty) _pinned.remove(sphereId);
    SecureStore.instance.setString(_pinnedPostsKey, jsonEncode(_pinned));
    notifyListeners();
  }

  Future<void> _loadPins() async {
    final raw = await SecureStore.instance.getString(_pinnedPostsKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded.forEach((k, v) => _pinned[k] = (v as List<dynamic>).cast<String>());
    } catch (_) {}
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

  /// Durable queue for sphere content. Supplied by the app.
  ///
  /// Sending used to be fire-and-forget: the result of [sendSealedToMember]
  /// was discarded, and it returns false whenever there is no live socket. A
  /// post written while a member was unreachable — or in the seconds after
  /// they went offline, when our own socket is reconnecting — was dropped and
  /// never mentioned again. Queueing makes it survive.
  OutboxService? outbox;

  /// Called with (author, sphereId, payload) for a verified sphere message.
  ///
  /// Group chat rides the same per-member channels as everything else
  /// addressed to a sphere, so it arrives here. Passing the opened payload
  /// rather than the sealed bytes avoids decrypting the same envelope twice.
  Future<void> Function(String from, String sphereId, Map<String, dynamic>)?
      onSphereMessage;

  /// Keeps a sealed envelope so it can be offered to a member who missed it.
  Future<void> Function({
    required String sphereId,
    required String envelopeId,
    required String sealed,
    DateTime? at,
  })? archiveEnvelope;

  /// Handles the two messages that make up a sync round.
  Future<void> Function(String from, String sphereId, Map<String, dynamic>)?
      onSyncDigest;
  Future<void> Function(String from, String sphereId, Map<String, dynamic>)?
      onSyncItems;

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

    final blocked = blockedForSending;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (final member in sphere.members.map((m) => m.identityKey)) {
      if (blocked.contains(member)) continue;
      // Our own entry in the member list stands for our other devices; with
      // one device there is nothing to send and queueForMember says so.
      await queueForMember(
        id: '$type:$stamp:$member',
        member: member,
        sealed: sealed,
      );
    }
  }

  /// Hand one member's copy to the durable queue, or send it directly if no
  /// queue is attached.
  Future<void> queueForMember({
    required String id,
    required String member,
    required String sealed,
  }) async {
    // Archived here rather than at each caller, because this is the single
    // point everything addressed to a sphere leaves by — posts, group
    // messages and album items alike. Without it our *own* content was
    // missing from the archive, so a peer asking us for what they had missed
    // could never be given anything we wrote ourselves.
    try {
      final envelope = Envelope.decode(sealed);
      final sphereId = envelope.sphereId;
      if (sphereId != null) {
        await archiveEnvelope?.call(
          sphereId: sphereId,
          envelopeId: envelope.id,
          sealed: sealed,
        );
      }
    } catch (_) {
      // Keeping a copy is best effort and must never stop a send.
    }

    // Sphere-sealed content is one envelope for everyone who holds the key,
    // so every device of the member gets the same bytes.
    final devices = _devicesFor(member);
    if (devices.isEmpty) {
      if (member != _myPublicKey) {
        DebugLogService().warn('Feed', 'No device known for $member; not sent');
      }
      return;
    }

    final queue = outbox;
    if (queue == null) {
      for (final device in devices) {
        final ok = await _feedRelay.sendViaRelay(member, sealed, deviceKey: device);
        if (!ok) {
          DebugLogService().warn(
              'Feed', 'Could not reach $member and have nowhere to queue it');
        }
      }
      return;
    }
    await queue.enqueueAll(
      id: id,
      peer: member,
      payloads: {for (final d in devices) d: sealed},
    );
  }

  /// Device keys to address for a member — every device of a contact, or, for
  /// our own key, every device of ours but this one.
  List<String> _devicesFor(String member) {
    final sessions = _sessions;
    if (sessions == null) return const [];
    return sessions.devicesOf(member,
        fallback: member == _myPublicKey ? null : _resolveExchangeKey?.call(member));
  }

  /// Apply an envelope a peer sent back because we were missing it.
  ///
  /// Deliberately the same path as anything arriving directly: the signature
  /// is checked, the author confirmed to be a member, and the content
  /// decrypted. Being handed something by a peer earns it no shortcut.
  Future<void> handleRecovered(String from, String sealed) async {
    await _handleIncomingFeedItem(from, sealed);
  }

  /// Send already-sealed sphere content to one member.
  ///
  /// Anything addressed to a sphere travels this channel — posts, album items
  /// and group messages alike — because that is where the receiving side opens
  /// sphere-sealed envelopes. Sending one down the direct chat channel instead
  /// puts it in front of a decoder that cannot open it.
  Future<bool> sendSealedToMember(String peerIdentityKey, String sealed,
          {String? deviceKey}) =>
      _feedRelay.sendViaRelay(peerIdentityKey, sealed, deviceKey: deviceKey);

  /// The same sealed content to every device of a member. True if any took it.
  Future<bool> sendSealedToAllDevices(String peerIdentityKey, String sealed) async {
    var any = false;
    for (final device in _devicesFor(peerIdentityKey)) {
      if (await _feedRelay.sendViaRelay(peerIdentityKey, sealed, deviceKey: device)) {
        any = true;
      }
    }
    return any;
  }

  /// Open the feed channel to each of our other devices, so posts we write
  /// anywhere show up everywhere.
  Future<void> connectOwnDevices() async {
    final sessions = _sessions;
    final me = _myPublicKey;
    if (sessions == null || me == null) {
      // A stub that returns quietly here is how posts stopped reaching a
      // linked phone after every restart; say so instead.
      DebugLogService().warn('Feed', 'Cannot open own-device channels before initSync');
      return;
    }
    final others = sessions.devicesOf(me);
    DebugLogService().info('Feed',
        others.isEmpty
            ? 'No other devices of ours to listen for'
            : 'Listening for ${others.length} other device(s) of ours');
    for (final device in others) {
      try {
        final mailbox = await sessions.mailboxFor(
          peerIdentityKey: me,
          peerKeyExchangePublicKey: device,
          purpose: 'feed',
        );
        await _feedRelay.connectMailbox(me, mailbox, deviceKey: device);
      } catch (e) {
        DebugLogService().warn('Feed', 'Could not open a feed channel to our own device: $e');
      }
    }
  }

  /// Open a feed channel for a contact added after startup.
  ///
  /// initSync only ever saw the contacts that existed at launch, so anyone
  /// added later never received posts and their posts never arrived.
  Future<void> connectContact(Contact contact) async {
    if (!_contacts.any((c) => c.publicKey == contact.publicKey)) {
      _contacts.add(contact);
    }
    await _connectFeedMailbox(contact.publicKey);
  }

  Future<void> _connectFeedMailbox(String contactKey) async {
    final sessions = _sessions;
    if (sessions == null) return;
    try {
      final devices = sessions.devicesOf(contactKey,
          fallback: _resolveExchangeKey?.call(contactKey));
      if (devices.isEmpty) throw NoSessionException(contactKey);
      for (final device in devices) {
        final mailbox = await sessions.mailboxFor(
          peerIdentityKey: contactKey,
          peerKeyExchangePublicKey: device,
          purpose: 'feed',
        );
        await _feedRelay.connectMailbox(contactKey, mailbox, deviceKey: device);
      }
    } on NoSessionException {
      // Nothing to connect to until the contact publishes an encryption key.
    }
  }

  void initSync(String myPublicKey, String mySecretKey, List<Contact> contacts) {
    _myPublicKey = myPublicKey;
    _mySecretKey = mySecretKey;
    // A copy, not the caller's list. ContactService hands out an unmodifiable
    // view, and connectContact appends to this — so keeping the reference made
    // every contact added after launch throw, silently leaving their feed
    // channel unopened. That is the whole "posts never arrive" bug.
    _contacts = List.of(contacts);

    _feedRelay.onMessageReceived = (contactKey, data) {
      _handleIncomingFeedItem(contactKey, data);
    };

    for (final contact in contacts.where((c) => !c.blocked)) {
      _connectFeedMailbox(contact.publicKey);
    }
  }

  Future<void> loadPosts() async {
    await _loadPins();
    await _loadPostNotificationPrefs();
    await _loadTrashAndArchive();
    try {
      final draftsRaw = await SecureStore.instance.getString(_draftsKey);
      if (draftsRaw != null) {
        _drafts
          ..clear()
          ..addAll((jsonDecode(draftsRaw) as List).cast<Map<String, dynamic>>());
      }
      final reportsRaw = await SecureStore.instance.getString(_reportsKey);
      if (reportsRaw != null) {
        (jsonDecode(reportsRaw) as Map<String, dynamic>).forEach((k, v) {
          _reports[k] = (v as List).cast<Map<String, dynamic>>();
        });
      }
    } catch (_) {}
    _draftTimer?.cancel();
    _draftTimer = Timer.periodic(const Duration(minutes: 1), (_) => publishDueDrafts());
    final prefs0 = SecureStore.instance;
    _sendViewReceipts =
        await prefs0.getBool('spheres_story_view_receipts') ?? true;

    try {
      final prefs = SecureStore.instance;
      final json = await prefs.getString(_postsKey);
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
      final hiddenJson = await prefs.getStringList(_hiddenKey);
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
  /// Write a post into one sphere, or several at once.
  ///
  /// Several is not one send to many audiences: each sphere has its own key,
  /// so one envelope is sealed per sphere. They share a post id, which is what
  /// lets a reader who is in two of them see one post rather than two.
  ///
  /// Each envelope names only the sphere it is addressed to, so nobody learns
  /// where else it went. Someone in Family cannot tell it also went to Work.
  Future<void> createPost(
    String content, {
    String? sphereId,
    Set<String>? sphereIds,
    required List<String> audienceMembers,
    List<String>? mediaRefs,
    String? authorName,
    bool isStory = false,
    DateTime? expiresAt,
    String kind = 'post',
    Map<String, dynamic>? payload,
    List<String> altTexts = const [],
    List<String> coAuthors = const [],
    List<MediaProvenance?>? provenance,
    bool allowReshare = true,
  }) async {
    final targets = {...?sphereIds, if (sphereId != null) sphereId};
    if (targets.isEmpty) {
      throw StateError('A post has to be addressed to at least one sphere');
    }

    final post = Post(
      id: const Uuid().v4(),
      authorId: _myPublicKey ?? 'self',
      authorName: authorName ?? _authorName,
      content: content,
      mediaRefs: mediaRefs ?? [],
      createdAt: DateTime.now(),
      sphereId: targets.first,
      sphereIds: targets,
      isStory: isStory,
      expiresAt: expiresAt,
      kind: kind,
      payload: payload,
      altTexts: altTexts,
      // What this device could tell about each picture's origin, recorded
      // when it was picked. Travels sealed with the post.
      provenance: provenance ?? MediaService.provenanceListFor(mediaRefs ?? []),
      coAuthors: coAuthors,
      allowReshare: allowReshare,
    );
    final signed = post.copyWith(authorSig: _signCore(post));

    _posts.insert(0, signed);
    await _persistPosts();
    notifyListeners();

    if (_myPublicKey == null) return;

    final relayPost = await _encodePostMedia(signed);
    for (final target in targets) {
      // Rebuilt per sphere so the copy names only where it is going.
      final copy = relayPost.copyWith(sphereId: target, sphereIds: {target});
      await _publishToSphere(
        sphereId: target,
        type: 'post',
        payloadJson: jsonEncode({'type': 'post', 'post': copy.toJson()}),
      );
    }
  }

  /// A 24-hour ephemeral post, scoped to a sphere like everything else.
  Future<void> createStory(
    String content, {
    required String sphereId,
    required List<String> audienceMembers,
    List<String>? mediaRefs,
    String authorName = 'You',
    Map<String, dynamic>? payload,
  }) async {
    await createPost(
      content,
      sphereId: sphereId,
      audienceMembers: audienceMembers,
      mediaRefs: mediaRefs,
      authorName: authorName,
      isStory: true,
      expiresAt: DateTime.now().add(const Duration(hours: 24)),
      payload: payload,
    );
  }

  // Returns a future so a recovered item can be awaited; the live path still
  // fires and forgets.
  Future<void> _handleIncomingFeedItem(String contactKey, String data) async {
    final spheres = _spheres;
    if (spheres == null) return;

    try {
      // Verifies the signature, checks the author is a member of the sphere,
      // and decrypts. Anything that fails throws rather than being displayed.
      final opened = await spheres.openContent(data);
      final authorId = opened.from;
      final json = jsonDecode(opened.plaintext);

      // A sync round is about content, and is not itself content.
      if (json['type'] == 'sync_digest') {
        await onSyncDigest?.call(
            authorId, opened.sphereId, json as Map<String, dynamic>);
        return;
      }
      if (json['type'] == 'sync_items') {
        await onSyncItems?.call(
            authorId, opened.sphereId, json as Map<String, dynamic>);
        return;
      }

      // Kept exactly as it arrived: we could not re-sign it as its author, and
      // relaying it later only works if the original signature travels with it.
      await archiveEnvelope?.call(
        sphereId: opened.sphereId,
        envelopeId: opened.envelopeId,
        sealed: data,
      );

      await applyFeedJson(
        authorId: authorId,
        sphereId: opened.sphereId,
        json: (json as Map).cast<String, dynamic>(),
        sealed: data,
      );
    } catch (e) {
      DebugLogService().warn('Feed', 'Rejected feed item from $contactKey: $e');
    }
  }

  /// Apply one verified feed item. [authorId] and [sphereId] come from the
  /// opened envelope, never from the payload, so every rule below ("only the
  /// author", "only an admin") is a rule about who signed. Public so tests can
  /// state who signed without sealing as a third party.
  @visibleForTesting
  Future<void> applyFeedJson({
    required String authorId,
    required String sphereId,
    required Map<String, dynamic> json,
    String sealed = '',
  }) async {
    final spheres = _spheres;
    if (spheres == null) return;

      if (json['type'] is String && (json['type'] as String).startsWith('sphere_msg')) {
      // The group conversation and everything about it: messages, edits,
      // unsends, pins, votes, read receipts, timer changes.
      await onSphereMessage?.call(
          authorId, sphereId, json);
      return;
    }

    if (json['type'] == 'album_add') {
      // Album items ride the same per-member channels as feed content.
      await onAlbumItem?.call(sealed);
      return;
    }

    if (json['type'] == 'post') {
      final post = await _decodePostMedia(Post.fromJson(json['post']));

      // Authorship and audience both come from the verified envelope, not
      // from fields in the payload that the sender could set freely.
      if (post.authorId != authorId || post.sphereId != sphereId) {
        DebugLogService().warn(
            'Feed', 'Dropping post: payload disagrees with signed envelope');
        return;
      }
      if (post.isReshare && !reshareAllowed(post)) {
        DebugLogService().warn('Feed', 'Dropping reshare: the author forbade it');
        return;
      }
      _mergePost(post);
    } else if (json['type'] == 'event_rsvp') {
      final index = _posts.indexWhere((p) => p.id == json['post_id']);
      if (index != -1 && _posts[index].isEvent) {
        _applyRsvp(index, authorId, json['status'] as String? ?? '');
      }
    } else if (json['type'] == 'event_update') {
      final index = _posts.indexWhere((p) => p.id == json['post_id']);
      if (index != -1 && _posts[index].isEvent) {
        _applyEventUpdate(index, authorId, json);
      }
    } else if (json['type'] == 'event_photo') {
      final index = _posts.indexWhere((p) => p.id == json['post_id']);
      final ref = json['ref'];
      final id = json['id'];
      if (index != -1 && _posts[index].isEvent && ref is String && id is String) {
        String local = ref;
        if (BlobRef.looksLikeRef(ref) && !(dataSaver?.call() ?? false)) {
          local = await MediaService.decodeAndSaveImage(ref) ?? ref;
        }
        _applyEventPhoto(index, id: id, by: authorId, ref: local,
            caption: json['caption'] is String ? json['caption'] as String : '');
      }
    } else if (json['type'] == 'post_vote') {
      final index = _posts.indexWhere((p) => p.id == json['post_id']);
      if (index != -1 && _posts[index].isPoll) {
        _applyPostVote(index, authorId,
            (json['choices'] as List?)?.whereType<int>().toList() ?? const []);
      }
    } else if (json['type'] == 'coauthor_accept') {
      final index = _posts.indexWhere((p) => p.id == json['post_id']);
      if (index != -1) _applyCoAuthor(index, authorId);
    } else if (json['type'] == 'report') {
      // Only admins of that sphere keep reports; everyone else drops them.
      final sphere = spheres.sphere(sphereId);
      final me = _myPublicKey;
      if (sphere != null && me != null && sphere.isAdmin(me)) {
        final list = _reports.putIfAbsent(sphereId, () => []);
        list.add({
          'post_id': json['post_id'],
          'reason': json['reason'],
          'by': authorId,
          'at': DateTime.now().toIso8601String(),
        });
        await SecureStore.instance.setString(_reportsKey, jsonEncode(_reports));
        notifyListeners();
        InboundEvents.emit(InboundEvent(
          kind: InboundKind.post,
          id: 'report:${json['post_id']}:$authorId',
          title: sphere.name,
          body: 'A post was reported to the admins',
          route: '/sphere/${sphereId}',
          thread: 'sphere:${sphereId}',
        ));
      }
    } else if (json['type'] == 'post_edit') {
      final postId = json['post_id'] as String;
      final index = _posts.indexWhere((p) => p.id == postId);
      if (index == -1) return;
      // Only the author, as proven by the signature, may change the text.
      if (_posts[index].authorId != authorId) {
        DebugLogService().warn('Feed', 'Dropping edit from a non-author');
        return;
      }
      final editedAt = DateTime.tryParse(json['edited_at'] as String? ?? '');
      _posts[index] = _posts[index].copyWith(
        content: json['content'] as String? ?? _posts[index].content,
        editedAt: editedAt ?? DateTime.now(),
        authorSig: json['sig'] is String ? json['sig'] as String : null,
      );
      await _persistPosts();
      notifyListeners();
    } else if (json['type'] == 'post_pin') {
      final sphere = spheres.sphere(sphereId);
      if (sphere == null || !sphere.isAdmin(authorId)) {
        DebugLogService().warn('Feed', 'Dropping pin from a non-admin');
        return;
      }
      final postId = json['post_id'];
      if (postId is String) {
        _applyPin(sphereId, postId, json['pinned'] == true);
      }
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
    } else if (json['type'] == 'story_view') {
      final postId = json['post_id'] as String;
      final index = _posts.indexWhere((p) => p.id == postId);
      // Only meaningful on our own story, and each viewer counts once.
      if (index != -1 &&
          _posts[index].authorId == _myPublicKey &&
          !_posts[index].viewedBy.contains(authorId)) {
        _posts[index] = _posts[index]
            .copyWith(viewedBy: [..._posts[index].viewedBy, authorId]);
        await _persistPosts();
        notifyListeners();
      }
    } else if (json['type'] == 'comment') {
      final comment = Comment.fromJson(json['comment']);
      if (comment.authorId != authorId) {
        DebugLogService()
            .warn('Feed', 'Dropping comment: author disagrees with signature');
        return;
      }
      final postId = json['post_id'] as String;
      final target = _posts.where((p) => p.id == postId).firstOrNull;
      // A closed post takes no new comments from anyone but its author; a
      // peer that missed the setting still cannot get one in.
      if (target != null && target.commentsOff && target.authorId != authorId) {
        DebugLogService().info('Feed', 'Dropping comment: comments are off');
        return;
      }
      // Hidden, pinned and reactions are decided by other envelopes, not
      // claimed by the comment itself.
      _applyComment(postId,
          comment.copyWith(hidden: false, pinned: false, reactions: const []));
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
        _notifyReaction(postId, authorId, emoji, onComment: false,
            target: post.authorId);
      }
      _posts[index] = post.copyWith(reactions: newReactions);
      _persistPosts();
      notifyListeners();
    } else if (json['type'] == 'post_delete') {
      final postId = json['post_id'];
      if (postId is! String) return;
      final index = _posts.indexWhere((p) => p.id == postId);
      if (index == -1) return;
      final post = _posts[index];
      if (post.authorId != authorId &&
          !(spheres.sphere(post.sphereId)?.isAdmin(authorId) ?? false)) {
        DebugLogService().warn('Feed', 'Dropping post delete from a non-author');
        return;
      }
      _posts.removeAt(index);
      // So a peer offering it back during a sync does not resurrect it.
      _hiddenPostIds.add(postId);
      await _persistHidden();
      await _persistPosts();
      notifyListeners();
    } else if (json['type'] == 'post_suggest') {
      final postId = json['post_id'];
      final text = json['text'];
      if (postId is! String || text is! String) return;
      final index = _posts.indexWhere((p) => p.id == postId);
      if (index == -1 || !_posts[index].isRecommend) return;
      _applySuggestion(index, authorId, text);
    } else if (json['type'] == 'comment_edit') {
      final postId = json['post_id'];
      final commentId = json['comment_id'];
      final text = json['text'];
      if (postId is! String || commentId is! String || text is! String) return;
      final at = DateTime.tryParse(json['edited_at'] as String? ?? '');
      _updateComment(postId, commentId, (post, c) {
        if (c.authorId != authorId) {
          DebugLogService().warn('Feed', 'Dropping comment edit from a non-author');
          return null;
        }
        return _editedComment(c, text, at ?? DateTime.now());
      });
    } else if (json['type'] == 'comment_delete') {
      final postId = json['post_id'];
      final commentId = json['comment_id'];
      if (postId is! String || commentId is! String) return;
      _removeComment(postId, commentId, (post, c) =>
          c.authorId == authorId || _moderates(spheres, post, authorId));
    } else if (json['type'] == 'comment_hide' || json['type'] == 'comment_pin') {
      final postId = json['post_id'];
      final commentId = json['comment_id'];
      if (postId is! String || commentId is! String) return;
      final hide = json['type'] == 'comment_hide';
      final flag = json[hide ? 'hidden' : 'pinned'] == true;
      _updateComment(postId, commentId, (post, c) {
        if (!_moderates(spheres, post, authorId)) {
          DebugLogService().warn('Feed', 'Dropping ${json['type']} from a non-moderator');
          return null;
        }
        return hide ? c.copyWith(hidden: flag) : c.copyWith(pinned: flag);
      });
    } else if (json['type'] == 'comment_react') {
      final postId = json['post_id'];
      final commentId = json['comment_id'];
      final emoji = json['emoji'];
      if (postId is! String || commentId is! String || emoji is! String) return;
      if (!ReactionKinds.contains(emoji)) return;
      _updateComment(postId, commentId, (post, c) {
        final toggled = _toggledReaction(c.reactions, authorId, emoji);
        if (toggled.length > c.reactions.length) {
          _notifyReaction(postId, authorId, emoji, onComment: true,
              target: c.authorId);
        }
        return c.copyWith(reactions: toggled);
      });
    } else if (json['type'] == 'post_settings') {
      final postId = json['post_id'];
      if (postId is! String) return;
      final index = _posts.indexWhere((p) => p.id == postId);
      if (index == -1) return;
      if (_posts[index].authorId != authorId) {
        DebugLogService().warn('Feed', 'Dropping post settings from a non-author');
        return;
      }
      if (json.containsKey('comments_off')) {
        _posts[index] =
            _posts[index].copyWith(commentsOff: json['comments_off'] == true);
        await _persistPosts();
        notifyListeners();
      }
    }
  }


  /// Encode local image paths as base64 data URIs for relay transfer.
  Future<Post> _encodePostMedia(Post post) async {
    if (post.mediaRefs.isEmpty) return post;
    final encoded = <String>[];
    final provenance = <MediaProvenance?>[];
    for (var i = 0; i < post.mediaRefs.length; i++) {
      final ref = post.mediaRefs[i];
      final claim = MediaProvenance.at(post.provenance, i);
      if (ref.startsWith('data:')) {
        encoded.add(ref);
        provenance.add(claim);
      } else {
        final b64 = await MediaService.prepareForRelay(ref,
            videoLimit: MediaService.feedVideoLimit);
        if (b64 != null) {
          encoded.add(b64);
          // Kept aligned: a dropped item takes its claim with it.
          provenance.add(claim);
        }
      }
    }
    return post.copyWith(mediaRefs: encoded, provenance: provenance);
  }

  /// Decode base64 data URIs received from relay into local file paths.
  Future<Post> _decodePostMedia(Post post) async {
    if (post.mediaRefs.isEmpty) return post;
    if (dataSaver?.call() ?? false) return post;
    final decoded = <String>[];
    for (final ref in post.mediaRefs) {
      if (BlobRef.looksLikeRef(ref)) {
        final localPath = await MediaService.decodeAndSaveImage(ref);
        // Keep the reference when the blob cannot be fetched right now: the
        // inline thumbnail still renders and the fetch can be retried, which
        // is better than the media silently vanishing.
        decoded.add(localPath ?? ref);
      } else {
        decoded.add(ref);
      }
    }
    return post.copyWith(mediaRefs: decoded);
  }

  void _mergePost(Post post) {
    final existing = _posts.indexWhere((p) => p.id == post.id);
    if (existing != -1) {
      // The same post reaching us through a second sphere we are in. One post,
      // now known to belong to both.
      final merged = _posts[existing];
      final union = {...merged.sphereIds, ...post.sphereIds};
      if (union.length != merged.sphereIds.length) {
        _posts[existing] = merged.copyWith(sphereIds: union);
        _persistPosts();
        notifyListeners();
      }
      return;
    }
    // Deleting is permanent and personal. Now that a peer can offer content
    // back, refusing it here is what stops a post someone removed reappearing
    // every time they sync.
    if (_hiddenPostIds.contains(post.id)) return;
    
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

    if (post.authorId != _myPublicKey) {
      final name = post.authorName.trim().isNotEmpty
          ? post.authorName
          : (resolveName?.call(post.authorId) ?? 'Someone');
      final hasVideo = post.mediaRefs.any(MediaService.looksLikeVideo);
      final body = post.content.trim().isNotEmpty
          ? post.content
          : (post.mediaRefs.isEmpty
              ? 'Posted'
              : (hasVideo ? 'Shared a video' : 'Shared a photo'));
      InboundEvents.emit(InboundEvent(
        kind: InboundKind.post,
        id: 'post:${post.id}',
        title: post.isStory ? '$name · story' : name,
        body: body,
        route: post.isStory ? '/' : '/post/${post.id}',
        thread: 'feed',
        from: post.authorId,
      ));
    }
  }

  /// Display name for an identity key, for notifications. Set by the app.
  String Function(String identityKey)? resolveName;

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

  /// Seal to the sphere but deliver to a single member.
  ///
  /// Used for view receipts: the author is entitled to know who watched, but
  /// the rest of the sphere is not, so this must not fan out.
  Future<void> _publishToMember({
    required String sphereId,
    required String recipient,
    required String type,
    required String payloadJson,
  }) async {
    final spheres = _spheres;
    if (spheres == null || recipient == _myPublicKey) return;

    final sphere = spheres.sphere(sphereId);
    if (sphere == null || !sphere.contains(recipient)) return;

    try {
      final sealed = await spheres.sealContent(
        sphereId: sphereId,
        type: type,
        plaintext: payloadJson,
      );
      _feedRelay.sendViaRelay(recipient, sealed);
    } catch (e) {
      DebugLogService().warn('Feed', 'Could not send $type: $e');
    }
  }

  /// Whether this device tells authors that we watched their stories.
  ///
  /// A view receipt is a disclosure — it tells someone you looked, and when.
  /// Mainstream apps make that unconditional; here it is a choice, defaulting
  /// on so the feature behaves as people expect.
  bool _sendViewReceipts = true;
  bool get sendViewReceipts => _sendViewReceipts;

  Future<void> setSendViewReceipts(bool value) async {
    _sendViewReceipts = value;
    final prefs = SecureStore.instance;
    await prefs.setBool('spheres_story_view_receipts', value);
    notifyListeners();
  }

  /// Record that we watched a story, and tell its author.
  ///
  /// Idempotent: re-opening a story does not send a second receipt.
  Future<void> markStoryViewed(String postId) async {
    final me = _myPublicKey;
    if (me == null) return;

    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    if (!post.isStory || post.authorId == me) return;
    if (post.viewedBy.contains(me)) return;

    _posts[index] = post.copyWith(viewedBy: [...post.viewedBy, me]);
    await _persistPosts();

    if (!_sendViewReceipts) return;
    await _publishToMember(
      sphereId: post.sphereId,
      recipient: post.authorId,
      type: 'story_view',
      payloadJson: jsonEncode({'type': 'story_view', 'post_id': postId}),
    );
  }

  /// Who has watched one of our stories.
  List<String> viewersOf(String postId) {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return const [];
    return _posts[index].viewedBy;
  }

  /// Add a comment, save it, and send it to the sphere.
  ///
  /// This previously did none of those last two things: it updated the list in
  /// memory and called notifyListeners, so comments vanished on restart and
  /// were never seen by anyone else, including the post's author.
  Future<void> commentOnPost(String postId, String text,
      {String? replyToId, String? authorName}) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final comment = Comment(
      id: const Uuid().v4(),
      authorId: _myPublicKey ?? 'self',
      authorName: authorName ?? _authorName,
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

    final post = _posts[index];
    _posts[index] = post.copyWith(
      comments: [...post.comments, comment]
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
    _persistPosts();
    notifyListeners();

    // Notify the people in the conversation: the author of the post, anyone
    // who has commented on it, and anyone who asked to follow it — not the
    // whole sphere, and nobody who asked to stop hearing about it.
    final me = _myPublicKey;
    final wants = postNotifies(post);
    if (me != null && comment.authorId != me && wants) {
      final name = comment.authorName.trim().isNotEmpty
          ? comment.authorName
          : (resolveName?.call(comment.authorId) ?? 'Someone');
      final parent = comment.replyToId == null
          ? null
          : post.comments.where((c) => c.id == comment.replyToId).firstOrNull;
      final toMe = parent != null && parent.authorId == me;
      InboundEvents.emit(InboundEvent(
        kind: InboundKind.comment,
        id: 'comment:${comment.id}',
        title: toMe ? '$name replied to your comment' : name,
        body: comment.text,
        route: '/post/$postId',
        thread: 'post:$postId',
        from: comment.authorId,
      ));
    }
  }

  // ── Author signature ───────────────────────────────────────────────────

  /// Sign the post's core with our identity key, or null when we have none.
  String? _signCore(Post post) {
    final secret = _mySecretKey;
    if (secret == null || secret.isEmpty) return null;
    try {
      final sig = ed.sign(ed.PrivateKey(hex.decode(secret)),
          Uint8List.fromList(utf8.encode(post.signedCore())));
      return hex.encode(sig);
    } catch (_) {
      return null;
    }
  }

  /// Whether [post]'s words are proven to be its author's: the signature in
  /// it verifies under the author's identity key. False for unsigned posts.
  static bool authorSignatureHolds(Post post) {
    final sig = post.authorSig;
    if (sig == null) return false;
    try {
      return ed.verify(
        ed.PublicKey(hex.decode(post.authorId)),
        Uint8List.fromList(utf8.encode(post.signedCore())),
        Uint8List.fromList(hex.decode(sig)),
      );
    } catch (_) {
      return false;
    }
  }

  /// The original inside a reshare, as a [Post], or null when malformed.
  static Post? originalOf(Post reshare) {
    final o = reshare.payload?['original'];
    if (o is! Map) return null;
    try {
      return Post.fromJson(o.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// A reshare is honoured only when the original is signed, the signature
  /// holds, and the signed core allows resharing. An unsigned original is
  /// the resharer's word; it is shown as such but not refused.
  static bool reshareAllowed(Post reshare) {
    final original = originalOf(reshare);
    if (original == null) return false;
    if (original.authorSig == null) return true;
    return authorSignatureHolds(original) && original.allowReshare;
  }

  /// Carry a post we have into other spheres, with its author's signed words.
  /// Media is re-uploaded, so attribution of pictures is our word, which the
  /// card says.
  Future<void> resharePost(
    String postId, {
    required Set<String> targets,
    String note = '',
  }) async {
    final original = _posts.where((p) => p.id == postId).firstOrNull;
    if (original == null) return;
    if (original.authorSig != null && !original.allowReshare) {
      throw StateError('The author does not allow this post to be reshared');
    }
    final core = original.copyWith(
      // Only what the signature covers travels, plus the name to show.
      reactions: const [],
      likes: const [],
      comments: const [],
      mediaRefs: const [],
      provenance: const [],
      viewedBy: const [],
    );
    final members = <String>{};
    for (final id in targets) {
      members.addAll(membersOf?.call(id) ?? const []);
    }
    await createPost(
      note,
      sphereIds: targets,
      audienceMembers: members.toList(),
      mediaRefs: List.of(original.mediaRefs),
      kind: 'reshare',
      payload: {'original': core.toJson()},
    );
  }

  // ── Events: hosts, details, photos, what is coming ────────────────────

  static List<String> coHostsOf(Post post) =>
      (post.payload?['co_hosts'] as List?)?.whereType<String>().toList() ?? const [];

  /// The author, or a co-host the author named.
  static bool hostedBy(Post post, String? who) =>
      who != null && (post.authorId == who || coHostsOf(post).contains(who));

  bool isEventHost(Post post) => hostedBy(post, _myPublicKey);

  static const _eventFields = {'title', 'starts_at', 'ends_at', 'place', 'ticket_url', 'recurrence'};

  /// Change an event's details. Any host may; the list of co-hosts only the
  /// author. [fields] uses the payload's own names; a null value clears.
  Future<void> updateEvent(String postId, Map<String, Object?> fields) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1 || !_posts[index].isEvent) return;
    final json = <String, dynamic>{'type': 'event_update', 'post_id': postId, ...fields};
    if (!_applyEventUpdate(index, me, json)) return;
    for (final sphereId in _posts[index].sphereIds) {
      await _publishToSphere(sphereId: sphereId, type: 'event_update', payloadJson: jsonEncode(json));
    }
  }

  bool _applyEventUpdate(int index, String by, Map<String, dynamic> json) {
    final post = _posts[index];
    if (!hostedBy(post, by)) {
      DebugLogService().warn('Feed', 'Dropping event update from a non-host');
      return false;
    }
    final payload = Map<String, dynamic>.from(post.payload ?? {});
    var changed = false;
    for (final f in _eventFields) {
      if (!json.containsKey(f)) continue;
      final v = json[f];
      if (v == null || (v is String && v.isEmpty)) {
        if (f == 'title' || f == 'starts_at') continue; // an event keeps a title and a start
        changed |= payload.remove(f) != null;
      } else if (v is String) {
        if ((f == 'starts_at' || f == 'ends_at') && DateTime.tryParse(v) == null) continue;
        if (f == 'recurrence' && !EventTime.recurrences.contains(v)) continue;
        payload[f] = v.length > 400 ? v.substring(0, 400) : v;
        changed = true;
      }
    }
    if (json.containsKey('co_hosts')) {
      if (by != post.authorId) {
        DebugLogService().warn('Feed', 'Only the author names co-hosts');
      } else {
        final hosts = (json['co_hosts'] as List?)?.whereType<String>().take(10).toList() ?? const <String>[];
        payload['co_hosts'] = hosts;
        changed = true;
      }
    }
    if (!changed) return false;
    _posts[index] = post.copyWith(payload: payload);
    _persistPosts();
    notifyListeners();
    return true;
  }

  /// Add a picture to an event, as anyone in its sphere may.
  Future<void> addEventPhoto(String postId, String localPath, {String caption = ''}) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1 || !_posts[index].isEvent) return;
    final id = const Uuid().v4();
    _applyEventPhoto(index, id: id, by: me, ref: localPath, caption: caption);
    final ref = await MediaService.prepareForRelay(localPath);
    if (ref == null) {
      DebugLogService().warn('Feed', 'Event photo could not be uploaded; kept here only');
      return;
    }
    final json = {'type': 'event_photo', 'post_id': postId, 'id': id, 'ref': ref, 'caption': caption};
    for (final sphereId in _posts[index].sphereIds) {
      await _publishToSphere(sphereId: sphereId, type: 'event_photo', payloadJson: jsonEncode(json));
    }
  }

  void _applyEventPhoto(int index,
      {required String id, required String by, required String ref, String caption = ''}) {
    final post = _posts[index];
    final payload = Map<String, dynamic>.from(post.payload ?? {});
    final photos = List<dynamic>.from(payload['photos'] as List? ?? const []);
    if (photos.any((p) => p is Map && p['id'] == id)) return;
    if (photos.length >= 60) return;
    photos.add({
      'id': id,
      'by': by,
      'ref': ref,
      'caption': caption.length > 200 ? caption.substring(0, 200) : caption,
      'at': DateTime.now().toIso8601String(),
    });
    payload['photos'] = photos;
    _posts[index] = post.copyWith(payload: payload);
    _persistPosts();
    notifyListeners();
  }

  /// Events still to come, soonest first; a recurring event by its next
  /// occurrence.
  List<Post> get upcomingEvents {
    final now = DateTime.now();
    final entries = <(DateTime, Post)>[];
    for (final p in posts.where((p) => p.isEvent)) {
      final starts = DateTime.tryParse(p.payload?['starts_at'] as String? ?? '');
      if (starts == null) continue;
      final ends = DateTime.tryParse(p.payload?['ends_at'] as String? ?? '');
      final recurrence = p.payload?['recurrence'] as String? ?? 'none';
      if (EventTime.isPast(starts: starts, ends: ends, recurrence: recurrence, now: now)) continue;
      final next = EventTime.occurrence(starts: starts, ends: ends, recurrence: recurrence, now: now);
      entries.add((next.starts, p));
    }
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final e in entries) e.$2];
  }

  // ── Recommendations ───────────────────────────────────────────────────

  /// Offer, change, or withdraw (empty text) our suggestion on a
  /// recommendation post. One per person.
  Future<void> suggest(String postId, String text) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1 || !_posts[index].isRecommend) return;
    _applySuggestion(index, me, text);
    for (final sphereId in _posts[index].sphereIds) {
      await _publishToSphere(
        sphereId: sphereId,
        type: 'post_suggest',
        payloadJson:
            jsonEncode({'type': 'post_suggest', 'post_id': postId, 'text': text}),
      );
    }
  }

  void _applySuggestion(int index, String who, String text) {
    final post = _posts[index];
    final payload = Map<String, dynamic>.from(post.payload ?? {});
    final suggestions =
        Map<String, dynamic>.from(payload['suggestions'] as Map? ?? {});
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      suggestions.remove(who);
    } else {
      suggestions[who] = trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
    }
    payload['suggestions'] = suggestions;
    _posts[index] = post.copyWith(payload: payload);
    _persistPosts();
    notifyListeners();
  }

  // ── Delete, trash, archive ─────────────────────────────────────────────

  static const _trashKey = 'spheres_post_trash_v1';
  static const _archivedKey = 'spheres_archived_posts_v1';
  static const trashKeepsFor = Duration(days: 30);

  /// Our deleted posts, kept here for [trashKeepsFor] in case the delete was
  /// the mistake. Local; the sphere was told to drop them.
  final List<Map<String, dynamic>> _trash = [];
  final Set<String> _archivedIds = {};

  List<Post> get trashedPosts =>
      _trash.map((e) => Post.fromJson(e['post'] as Map<String, dynamic>)).toList();

  DateTime? trashedAt(String postId) {
    final e = _trash.where((t) => (t['post'] as Map)['id'] == postId).firstOrNull;
    return e == null ? null : DateTime.tryParse(e['at'] as String? ?? '');
  }

  bool isArchived(String postId) => _archivedIds.contains(postId);

  List<Post> get archivedPosts =>
      _posts.where((p) => _archivedIds.contains(p.id) && !p.isStory).toList();

  /// Remove a post of ours from every sphere it went to, keeping a copy in
  /// the trash. An admin removing someone else's post sends the same thing
  /// and keeps nothing.
  Future<void> deletePost(String postId) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1) return;
    final post = _posts[index];
    final spheres = _spheres;
    final mine = post.authorId == me;
    final admin = spheres != null &&
        post.sphereIds.any((id) => spheres.sphere(id)?.isAdmin(me) ?? false);
    if (!mine && !admin) return;
    _posts.removeAt(index);
    _archivedIds.remove(postId);
    if (mine) {
      _trash.insert(0, {'post': post.toJson(), 'at': DateTime.now().toIso8601String()});
      await _persistTrash();
    }
    _hiddenPostIds.add(postId);
    await _persistHidden();
    await _persistPosts();
    notifyListeners();
    for (final sphereId in post.sphereIds) {
      await _publishToSphere(
        sphereId: sphereId,
        type: 'post_delete',
        payloadJson: jsonEncode({'type': 'post_delete', 'post_id': postId}),
      );
    }
  }

  /// Put a deleted post back, for us and for the sphere.
  Future<void> restoreFromTrash(String postId) async {
    final i = _trash.indexWhere((t) => (t['post'] as Map)['id'] == postId);
    if (i == -1) return;
    final post = Post.fromJson(_trash[i]['post'] as Map<String, dynamic>);
    _trash.removeAt(i);
    await _persistTrash();
    _hiddenPostIds.remove(postId);
    await _persistHidden();
    _mergePost(post);
    final relayPost = await _encodePostMedia(post);
    for (final target in post.sphereIds) {
      final copy = relayPost.copyWith(sphereId: target, sphereIds: {target});
      await _publishToSphere(
        sphereId: target,
        type: 'post',
        payloadJson: jsonEncode({'type': 'post', 'post': copy.toJson()}),
      );
    }
  }

  Future<void> emptyTrash({String? onlyId}) async {
    if (onlyId == null) {
      _trash.clear();
    } else {
      _trash.removeWhere((t) => (t['post'] as Map)['id'] == onlyId);
    }
    await _persistTrash();
    notifyListeners();
  }

  /// Take a post out of the feed on this device only. Nothing is sent.
  Future<void> setArchived(String postId, bool archived) async {
    if (archived) {
      _archivedIds.add(postId);
    } else {
      _archivedIds.remove(postId);
    }
    await SecureStore.instance.setStringList(_archivedKey, _archivedIds.toList());
    notifyListeners();
  }

  Future<void> _persistTrash() =>
      SecureStore.instance.setString(_trashKey, jsonEncode(_trash));

  Future<void> _loadTrashAndArchive() async {
    final store = SecureStore.instance;
    _archivedIds
      ..clear()
      ..addAll(await store.getStringList(_archivedKey) ?? const []);
    _trash.clear();
    final raw = await store.getString(_trashKey);
    if (raw != null) {
      var total = 0;
      try {
        final cutoff = DateTime.now().subtract(trashKeepsFor);
        final all = (jsonDecode(raw) as List).whereType<Map>().toList();
        total = all.length;
        for (final e in all) {
          final at = DateTime.tryParse(e['at'] as String? ?? '');
          // Thirty days, then gone for good.
          if (at != null && at.isAfter(cutoff)) _trash.add(e.cast<String, dynamic>());
        }
      } catch (_) {}
      if (_trash.length != total) await _persistTrash();
    }
  }

  // ── Comments: edit, delete, hide, pin, react; comments off ─────────────

  /// Whether [who] may hide, pin or delete comments on [post]: its author, or
  /// an admin of the sphere it is in.
  bool _moderates(SphereService spheres, Post post, String who) =>
      post.authorId == who || (spheres.sphere(post.sphereId)?.isAdmin(who) ?? false);

  /// For the UI: can we moderate the comments on this post?
  bool canModerateComments(Post post) {
    final me = _myPublicKey;
    final spheres = _spheres;
    if (me == null || spheres == null) return false;
    return _moderates(spheres, post, me);
  }

  static Comment _editedComment(Comment c, String text, DateTime at) =>
      c.copyWith(text: text, editedAt: at, history: [...c.history, c.text]);

  static List<Reaction> _toggledReaction(
      List<Reaction> reactions, String who, String emoji) {
    final next = List<Reaction>.from(reactions);
    final existing =
        next.indexWhere((r) => r.reactorId == who && r.emoji == emoji);
    if (existing != -1) {
      next.removeAt(existing);
    } else {
      // One reaction per person, as on a post.
      next.removeWhere((r) => r.reactorId == who);
      next.add(Reaction(reactorId: who, emoji: emoji, timestamp: DateTime.now()));
    }
    return next;
  }

  /// Replace one comment. [change] returns the new comment, or null to leave
  /// it alone (the usual reason: the signer may not do this).
  bool _updateComment(String postId, String commentId,
      Comment? Function(Post post, Comment c) change) {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return false;
    final post = _posts[index];
    final ci = post.comments.indexWhere((c) => c.id == commentId);
    if (ci == -1) return false;
    final changed = change(post, post.comments[ci]);
    if (changed == null) return false;
    final comments = List<Comment>.from(post.comments);
    comments[ci] = changed;
    _posts[index] = post.copyWith(comments: comments);
    _persistPosts();
    notifyListeners();
    return true;
  }

  bool _removeComment(String postId, String commentId,
      bool Function(Post post, Comment c) allowed) {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return false;
    final post = _posts[index];
    final ci = post.comments.indexWhere((c) => c.id == commentId);
    if (ci == -1) return false;
    if (!allowed(post, post.comments[ci])) {
      DebugLogService().warn('Feed', 'Dropping comment delete: not allowed');
      return false;
    }
    // Replies to it stay; the thread helper shows them at the top level.
    _posts[index] = post.copyWith(
        comments: post.comments.where((c) => c.id != commentId).toList());
    _persistPosts();
    notifyListeners();
    return true;
  }

  Future<void> _sendCommentOp(String postId, String type,
      Map<String, Object?> fields) async {
    final post = _posts.where((p) => p.id == postId).firstOrNull;
    if (post == null) return;
    await _publishToSphere(
      sphereId: post.sphereId,
      type: type,
      payloadJson: jsonEncode({'type': type, 'post_id': postId, ...fields}),
    );
  }

  /// Change the text of our own comment. Everyone keeps the earlier text.
  Future<void> editComment(String postId, String commentId, String text) async {
    final me = _myPublicKey;
    if (me == null || text.trim().isEmpty) return;
    final at = DateTime.now();
    final ok = _updateComment(postId, commentId,
        (post, c) => c.authorId == me ? _editedComment(c, text, at) : null);
    if (!ok) return;
    await _sendCommentOp(postId, 'comment_edit', {
      'comment_id': commentId,
      'text': text,
      'edited_at': at.toIso8601String(),
    });
  }

  /// Remove a comment: our own, or any comment on a post we moderate.
  Future<void> deleteComment(String postId, String commentId) async {
    final me = _myPublicKey;
    final spheres = _spheres;
    if (me == null || spheres == null) return;
    final ok = _removeComment(postId, commentId,
        (post, c) => c.authorId == me || _moderates(spheres, post, me));
    if (!ok) return;
    await _sendCommentOp(postId, 'comment_delete', {'comment_id': commentId});
  }

  Future<void> setCommentHidden(
      String postId, String commentId, bool hidden) async {
    final me = _myPublicKey;
    final spheres = _spheres;
    if (me == null || spheres == null) return;
    final ok = _updateComment(postId, commentId, (post, c) =>
        _moderates(spheres, post, me) ? c.copyWith(hidden: hidden) : null);
    if (!ok) return;
    await _sendCommentOp(postId, 'comment_hide',
        {'comment_id': commentId, 'hidden': hidden});
  }

  Future<void> setCommentPinned(
      String postId, String commentId, bool pinned) async {
    final me = _myPublicKey;
    final spheres = _spheres;
    if (me == null || spheres == null) return;
    final ok = _updateComment(postId, commentId, (post, c) =>
        _moderates(spheres, post, me) ? c.copyWith(pinned: pinned) : null);
    if (!ok) return;
    await _sendCommentOp(postId, 'comment_pin',
        {'comment_id': commentId, 'pinned': pinned});
  }

  Future<void> reactToComment(
      String postId, String commentId, String emoji) async {
    final me = _myPublicKey;
    if (me == null || !ReactionKinds.contains(emoji)) return;
    final ok = _updateComment(postId, commentId,
        (post, c) => c.copyWith(reactions: _toggledReaction(c.reactions, me, emoji)));
    if (!ok) return;
    await _sendCommentOp(postId, 'comment_react',
        {'comment_id': commentId, 'emoji': emoji});
  }

  /// Close or reopen comments on our own post.
  Future<void> setCommentsOff(String postId, bool off) async {
    final me = _myPublicKey;
    final index = _posts.indexWhere((p) => p.id == postId);
    if (me == null || index == -1 || _posts[index].authorId != me) return;
    _posts[index] = _posts[index].copyWith(commentsOff: off);
    await _persistPosts();
    notifyListeners();
    await _sendCommentOp(postId, 'post_settings', {'comments_off': off});
  }

  // ── Which posts notify us ──────────────────────────────────────────────

  static const _watchedPostsKey = 'spheres_post_watch_v1';
  static const _mutedPostsKey = 'spheres_post_mute_v1';

  /// Posts we asked to hear about although we are not in the conversation,
  /// and posts we asked to stop hearing about although we are. Local only.
  final Set<String> _watchedPosts = {};
  final Set<String> _mutedPosts = {};

  bool isWatching(String postId) => _watchedPosts.contains(postId);
  bool isPostMuted(String postId) => _mutedPosts.contains(postId);

  /// Whether a comment or reaction on [post] would notify us by default,
  /// before any explicit choice: we wrote it or commented on it.
  bool _involvedIn(Post post) {
    final me = _myPublicKey;
    return me != null &&
        (post.authorId == me || post.comments.any((c) => c.authorId == me));
  }

  /// What the menu shows: on when involved or watching, unless muted.
  bool postNotifies(Post post) =>
      !_mutedPosts.contains(post.id) &&
      (_involvedIn(post) || _watchedPosts.contains(post.id));

  Future<void> setPostNotifications(String postId, bool on) async {
    if (on) {
      _mutedPosts.remove(postId);
      _watchedPosts.add(postId);
    } else {
      _watchedPosts.remove(postId);
      _mutedPosts.add(postId);
    }
    final prefs = SecureStore.instance;
    await prefs.setStringList(_watchedPostsKey, _watchedPosts.toList());
    await prefs.setStringList(_mutedPostsKey, _mutedPosts.toList());
    notifyListeners();
  }

  Future<void> _loadPostNotificationPrefs() async {
    final prefs = SecureStore.instance;
    _watchedPosts
      ..clear()
      ..addAll(await prefs.getStringList(_watchedPostsKey) ?? const []);
    _mutedPosts
      ..clear()
      ..addAll(await prefs.getStringList(_mutedPostsKey) ?? const []);
  }

  void _notifyReaction(String postId, String reactor, String emoji,
      {required bool onComment, required String target}) {
    final me = _myPublicKey;
    if (me == null || reactor == me || target != me) return;
    if (_mutedPosts.contains(postId)) return;
    final name = resolveName?.call(reactor) ?? 'Someone';
    InboundEvents.emit(InboundEvent(
      kind: InboundKind.reaction,
      id: 'react:$postId:$reactor',
      title: name,
      body: '$emoji ${onComment ? 'on your comment' : 'on your post'}',
      route: '/post/$postId',
      thread: 'post:$postId',
      from: reactor,
    ));
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
    final prefs = SecureStore.instance;
    await prefs.setStringList(_hiddenKey, _hiddenPostIds.toList());
  }

  Future<void> _persistPosts() async {
    final prefs = SecureStore.instance;
    // Only persist non-expired stories
    final now = DateTime.now();
    final validPosts = _posts.where((p) => !(p.isStory && p.expiresAt != null && p.expiresAt!.isBefore(now)));
    await prefs.setString(_postsKey, jsonEncode(validPosts.take(100).map((e) => e.toJson()).toList()));
  }
}
