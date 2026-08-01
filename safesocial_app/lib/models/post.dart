import 'package:equatable/equatable.dart';

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
  }) : sphereIds = sphereIds ?? {sphereId};

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

  const Comment({
    required this.id,
    required this.authorId,
    this.authorName = '',
    required this.text,
    required this.createdAt,
    this.replyToId,
  });

  factory Comment.fromJson(Map<String, dynamic> json) {
    return Comment(
      id: json['id'] as String,
      authorId: json['authorId'] as String,
      authorName: json['authorName'] as String? ?? '',
      text: json['text'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      replyToId: json['replyToId'] as String?,
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
    };
  }

  @override
  List<Object?> get props =>
      [id, authorId, authorName, text, createdAt, replyToId];
}
