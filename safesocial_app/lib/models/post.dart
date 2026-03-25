import 'package:equatable/equatable.dart';

/// Post audience — who can see this post.
enum PostAudience { everyone, closeFriends }

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
  final PostAudience audience;

  const Post({
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
    this.audience = PostAudience.everyone,
  });

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
      audience: json['audience'] == 'closeFriends'
          ? PostAudience.closeFriends
          : PostAudience.everyone,
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
      'audience': audience == PostAudience.closeFriends ? 'closeFriends' : 'everyone',
    };
  }

  bool get isLikedBySelf => likes.contains('self');

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
    PostAudience? audience,
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
      audience: audience ?? this.audience,
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
        audience,
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
