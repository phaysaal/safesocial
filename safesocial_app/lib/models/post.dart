import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'media_lock.dart';
import 'media_protection.dart';
import 'media_provenance.dart';

/// A social feed post authored by a peer.
class Post with EquatableMixin {
  final String id;
  final String authorId;
  final String authorName;
  final String content;
  final List<String> mediaRefs;
  final DateTime createdAt;
  final DateTime? editedAt;
  final List<Reaction> reactions;
  final List<String> likes;
  final List<Comment> comments;
  /// The sphere this belongs to. Every post has one — there is no public feed.
  /// The sphere this copy was addressed to.
  final String sphereId;

  /// Every sphere we know this post was shared with.
  ///
  /// One post can go to several spheres. It cannot be *sent* once, because
  /// each sphere has its own key — so one envelope is sealed per sphere, all
  /// carrying the same post id, and the receiving side unions them back
  /// together here.
  ///
  /// Each envelope names only its own sphere, which means this set contains
  /// exactly the spheres the reader is in. Someone in Family learns nothing
  /// about the post also going to Work; the audience is disclosed to nobody,
  /// not even partially, and that falls out of the design rather than needing
  /// to be enforced.
  final Set<String> sphereIds;
  final bool isStory;
  final DateTime? expiresAt;

  /// Identity keys of sphere members who have viewed this story.
  ///
  /// Only ever populated on the author's own copy: a view receipt is sent to
  /// the author alone, not fanned out to the sphere, so members do not learn
  /// who else is watching.
  final List<String> viewedBy;

  /// 'post' (default), 'event', 'poll'. Structured content in [payload]:
  /// events carry title, starts_at, ends_at, place and rsvps; polls carry
  /// question, options, multiple, anonymous and votes; stories may carry an
  /// overlay caption and a sticker.
  final String kind;
  final Map<String, dynamic>? payload;

  /// One description per entry of [mediaRefs], for screen readers. Empty
  /// strings where none was given.
  final List<String> altTexts;

  /// What the sender's device could tell about each media item's origin, one
  /// entry per [mediaRefs] entry (null where nothing was assessed).
  final List<MediaProvenance?> provenance;

  /// People named as co-authors, and those who have confirmed it. Only the
  /// confirmed ones are shown as authors.
  final List<String> coAuthors;
  final List<String> acceptedCoAuthors;

  /// The author closed comments. Existing comments stay; new ones are refused
  /// on receipt and the composer says so.
  final bool commentsOff;

  /// The author's Ed25519 signature over [signedCore], so a copy of this post
  /// carried into another sphere by someone else still proves who wrote the
  /// words. Null for posts made before signatures existed.
  final String? authorSig;

  /// Whether the author lets members carry this post into other spheres.
  /// Part of what is signed, so a resharer cannot strip it.
  final bool allowReshare;

  bool get isLifeEvent => kind == 'life_event';
  bool get isRecommend => kind == 'recommend';
  bool get isReshare => kind == 'reshare';

  /// Media shown only while held, never kept; see [MediaProtection].
  MediaProtection? get protection => MediaProtection.fromPayload(payload);
  bool get isProtected => protection != null;

  /// Pictures waiting for the people tagged in them; see [MediaLock].
  MediaLock? get lock => MediaLock.fromPayload(payload);

  /// Identity keys tagged in this post (`payload['tags']`).
  List<String> get tags => (payload?['tags'] as List?)?.whereType<String>().toList() ?? const [];

  /// What the author signs: the identity of the post and its words. Media and
  /// the audience are not in it; media is re-uploaded by a resharer and the
  /// audience is whoever receives the copy.
  String signedCore() => jsonEncode({
        'id': id,
        'authorId': authorId,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'kind': kind,
        'allowReshare': allowReshare,
      });

  // Not const: sphereIds defaults to a set built from sphereId.
  Post({
    required this.id,
    required this.authorId,
    this.authorName = '',
    required this.content,
    this.mediaRefs = const [],
    required this.createdAt,
    this.editedAt,
    this.reactions = const [],
    this.likes = const [],
    this.comments = const [],
    required this.sphereId,
    Set<String>? sphereIds,
    this.isStory = false,
    this.expiresAt,
    this.viewedBy = const [],
    this.kind = 'post',
    this.payload,
    this.altTexts = const [],
    this.provenance = const [],
    this.coAuthors = const [],
    this.acceptedCoAuthors = const [],
    this.commentsOff = false,
    this.authorSig,
    this.allowReshare = true,
  }) : sphereIds = sphereIds ?? {sphereId};

  /// Comments that are shown to [viewer]: a hidden one is still shown to the
  /// person who wrote it, as on most networks, and to whoever can unhide it.
  List<Comment> visibleComments(String? viewer, {bool moderator = false}) =>
      comments
          .where((c) => !c.hidden || moderator || c.authorId == viewer)
          .toList();

  bool get isEvent => kind == 'event';
  bool get isPoll => kind == 'poll';

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'] as String,
      authorId: json['authorId'] as String,
      authorName: json['authorName'] as String? ?? '',
      content: json['content'] as String,
      mediaRefs: (json['mediaRefs'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      createdAt: DateTime.parse(json['createdAt'] as String),
      editedAt: json['editedAt'] != null
          ? DateTime.parse(json['editedAt'] as String)
          : null,
      reactions: (json['reactions'] as List<dynamic>?)
              ?.map((e) => Reaction.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      likes: (json['likes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      comments: (json['comments'] as List<dynamic>?)
              ?.map((e) => Comment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      sphereId: json['sphereId'] as String? ?? '',
      sphereIds: (json['sphereIds'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toSet(),
      viewedBy: (json['viewedBy'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      isStory: json['isStory'] as bool? ?? false,
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
      kind: json['kind'] as String? ?? 'post',
      payload: (json['payload'] as Map?)?.cast<String, dynamic>(),
      altTexts: (json['altTexts'] as List<dynamic>?)?.cast<String>() ?? const [],
      provenance: MediaProvenance.listFromJson(json['provenance']),
      coAuthors: (json['coAuthors'] as List<dynamic>?)?.cast<String>() ?? const [],
      acceptedCoAuthors:
          (json['acceptedCoAuthors'] as List<dynamic>?)?.cast<String>() ?? const [],
      commentsOff: json['commentsOff'] == true,
      authorSig: json['authorSig'] is String ? json['authorSig'] as String : null,
      allowReshare: json['allowReshare'] != false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'authorId': authorId,
      'authorName': authorName,
      'content': content,
      'mediaRefs': mediaRefs,
      'createdAt': createdAt.toIso8601String(),
      'editedAt': editedAt?.toIso8601String(),
      'reactions': reactions.map((r) => r.toJson()).toList(),
      'likes': likes,
      'comments': comments.map((c) => c.toJson()).toList(),
      'sphereId': sphereId,
      if (sphereIds.length > 1) 'sphereIds': sphereIds.toList(),
      'viewedBy': viewedBy,
      'isStory': isStory,
      'expiresAt': expiresAt?.toIso8601String(),
      if (kind != 'post') 'kind': kind,
      if (payload != null) 'payload': payload,
      if (altTexts.isNotEmpty) 'altTexts': altTexts,
      if (MediaProvenance.listToJson(provenance) != null)
        'provenance': MediaProvenance.listToJson(provenance),
      if (coAuthors.isNotEmpty) 'coAuthors': coAuthors,
      if (acceptedCoAuthors.isNotEmpty) 'acceptedCoAuthors': acceptedCoAuthors,
      if (commentsOff) 'commentsOff': true,
      if (authorSig != null) 'authorSig': authorSig,
      if (!allowReshare) 'allowReshare': false,
    };
  }

  /// Whether [identityKey] has liked this post.
  ///
  /// Own likes used to be stored as the literal string 'self' while the wire
  /// carried the real key, so they were not portable and self-detection broke
  /// for anything received from another device.
  bool isLikedBy(String? identityKey) =>
      identityKey != null && likes.contains(identityKey);

  bool hasReactionFrom(String? identityKey, String emoji) =>
      identityKey != null &&
      reactions.any((r) => r.reactorId == identityKey && r.emoji == emoji);

  Post copyWith({
    String? id,
    String? authorId,
    String? authorName,
    String? content,
    List<String>? mediaRefs,
    DateTime? createdAt,
    DateTime? editedAt,
    List<Reaction>? reactions,
    List<String>? likes,
    List<Comment>? comments,
    String? sphereId,
    Set<String>? sphereIds,
    List<String>? viewedBy,
    bool? isStory,
    DateTime? expiresAt,
    String? kind,
    Map<String, dynamic>? payload,
    List<String>? altTexts,
    List<MediaProvenance?>? provenance,
    List<String>? coAuthors,
    List<String>? acceptedCoAuthors,
    bool? commentsOff,
    String? authorSig,
    bool? allowReshare,
  }) {
    return Post(
      id: id ?? this.id,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      content: content ?? this.content,
      mediaRefs: mediaRefs ?? this.mediaRefs,
      createdAt: createdAt ?? this.createdAt,
      editedAt: editedAt ?? this.editedAt,
      reactions: reactions ?? this.reactions,
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      sphereId: sphereId ?? this.sphereId,
      sphereIds: sphereIds ?? this.sphereIds,
      viewedBy: viewedBy ?? this.viewedBy,
      isStory: isStory ?? this.isStory,
      expiresAt: expiresAt ?? this.expiresAt,
      kind: kind ?? this.kind,
      payload: payload ?? this.payload,
      altTexts: altTexts ?? this.altTexts,
      provenance: provenance ?? this.provenance,
      coAuthors: coAuthors ?? this.coAuthors,
      acceptedCoAuthors: acceptedCoAuthors ?? this.acceptedCoAuthors,
      commentsOff: commentsOff ?? this.commentsOff,
      authorSig: authorSig ?? this.authorSig,
      allowReshare: allowReshare ?? this.allowReshare,
    );
  }

  @override
  List<Object?> get props => [
        id,
        authorId,
        authorName,
        content,
        mediaRefs,
        createdAt,
        editedAt,
        reactions,
        likes,
        comments,
        sphereId,
        sphereIds,
        viewedBy,
        isStory,
        expiresAt,
        kind,
        payload,
        altTexts,
        provenance,
        coAuthors,
        acceptedCoAuthors,
        commentsOff,
        authorSig,
        allowReshare,
      ];
}

/// A reaction (emoji) on a post.
class Reaction with EquatableMixin {
  final String reactorId;
  final String emoji;
  final DateTime timestamp;

  const Reaction({
    required this.reactorId,
    required this.emoji,
    required this.timestamp,
  });

  factory Reaction.fromJson(Map<String, dynamic> json) {
    return Reaction(
      reactorId: json['reactorId'] as String,
      emoji: json['emoji'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'reactorId': reactorId,
      'emoji': emoji,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  Reaction copyWith({
    String? reactorId,
    String? emoji,
    DateTime? timestamp,
  }) {
    return Reaction(
      reactorId: reactorId ?? this.reactorId,
      emoji: emoji ?? this.emoji,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  @override
  List<Object?> get props => [reactorId, emoji, timestamp];
}

/// A comment on a post, with optional reply threading.
class Comment with EquatableMixin {
  final String id;
  final String authorId;
  final String authorName;
  final String text;
  final DateTime createdAt;
  final String? replyToId;

  /// When the author last changed the text; null if never.
  final DateTime? editedAt;

  /// Every earlier text, oldest first, so an edit is not a way to rewrite
  /// what people already answered.
  final List<String> history;

  final List<Reaction> reactions;

  /// Hidden by the post's author or a sphere admin. Still shown to its own
  /// author and to moderators; others see that something was hidden.
  final bool hidden;

  /// Pinned by the post's author or an admin: shown first.
  final bool pinned;

  const Comment({
    required this.id,
    required this.authorId,
    this.authorName = '',
    required this.text,
    required this.createdAt,
    this.replyToId,
    this.editedAt,
    this.history = const [],
    this.reactions = const [],
    this.hidden = false,
    this.pinned = false,
  });

  bool get isEdited => editedAt != null;

  bool hasReactionFrom(String? identityKey, String emoji) =>
      reactions.any((r) => r.reactorId == identityKey && r.emoji == emoji);

  factory Comment.fromJson(Map<String, dynamic> json) {
    return Comment(
      id: json['id'] as String,
      authorId: json['authorId'] as String,
      authorName: json['authorName'] as String? ?? '',
      text: json['text'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      replyToId: json['replyToId'] as String?,
      editedAt: json['editedAt'] is String
          ? DateTime.tryParse(json['editedAt'] as String)
          : null,
      history: (json['history'] as List<dynamic>?)
              ?.whereType<String>()
              .toList() ??
          const [],
      reactions: (json['reactions'] as List<dynamic>?)
              ?.whereType<Map>()
              .map((e) => Reaction.fromJson(e.cast<String, dynamic>()))
              .toList() ??
          const [],
      hidden: json['hidden'] == true,
      pinned: json['pinned'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'authorId': authorId,
      'authorName': authorName,
      'text': text,
      'createdAt': createdAt.toIso8601String(),
      'replyToId': replyToId,
      if (editedAt != null) 'editedAt': editedAt!.toIso8601String(),
      if (history.isNotEmpty) 'history': history,
      if (reactions.isNotEmpty)
        'reactions': reactions.map((r) => r.toJson()).toList(),
      if (hidden) 'hidden': true,
      if (pinned) 'pinned': true,
    };
  }

  Comment copyWith({
    String? text,
    DateTime? editedAt,
    List<String>? history,
    List<Reaction>? reactions,
    bool? hidden,
    bool? pinned,
  }) {
    return Comment(
      id: id,
      authorId: authorId,
      authorName: authorName,
      text: text ?? this.text,
      createdAt: createdAt,
      replyToId: replyToId,
      editedAt: editedAt ?? this.editedAt,
      history: history ?? this.history,
      reactions: reactions ?? this.reactions,
      hidden: hidden ?? this.hidden,
      pinned: pinned ?? this.pinned,
    );
  }

  @override
  List<Object?> get props => [
        id,
        authorId,
        authorName,
        text,
        createdAt,
        replyToId,
        editedAt,
        history,
        reactions,
        hidden,
        pinned,
      ];
}

/// The reactions a person can leave on a post or a comment. One list for
/// both, so every picker and every count row reads the same set. The set is
/// the product's own: no thumb, no "Like". [primary] is what a plain tap
/// leaves; the rest are behind a long press.
class ReactionKinds {
  ReactionKinds._();

  static const List<(String, String)> all = [
    ('🙌', 'Respect'),
    ('😎', 'Cool'),
    ('😮', 'Wow!'),
    ('🥰', 'Adorable'),
    ('😂', 'LOL'),
    ('😢', 'Sad'),
    ('😠', 'Angry'),
    ('🙅', 'Not for me'),
  ];

  /// What one tap on the reaction button leaves.
  static const (String, String) primary = ('🙌', 'Respect');

  /// What clients before 0.11 could send. Still accepted and still named,
  /// so a reaction left last month keeps its meaning, but no longer offered.
  static const List<(String, String)> legacy = [
    ('👍', 'Like'),
    ('❤️', 'Love'),
    ('🤗', 'Care'),
    ('✅', 'Agree'),
    ('❌', 'Disagree'),
  ];

  static bool contains(String emoji) =>
      all.any((k) => k.$1 == emoji) || legacy.any((k) => k.$1 == emoji);

  static String labelFor(String emoji) {
    for (final k in all) {
      if (k.$1 == emoji) return k.$2;
    }
    for (final k in legacy) {
      if (k.$1 == emoji) return k.$2;
    }
    return emoji;
  }

  /// Counts per emoji, most used first.
  static Map<String, int> tally(Iterable<Reaction> reactions) {
    final counts = <String, int>{};
    for (final r in reactions) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    }
    return Map.fromEntries(
      counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
    );
  }
}
