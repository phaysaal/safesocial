import 'package:equatable/equatable.dart';

/// One person's reaction to a message.
class MessageReaction with EquatableMixin {
  /// Ed25519 identity key of whoever reacted.
  final String reactorId;
  final String emoji;
  final DateTime timestamp;

  const MessageReaction({
    required this.reactorId,
    required this.emoji,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'reactorId': reactorId,
        'emoji': emoji,
        'timestamp': timestamp.toIso8601String(),
      };

  static MessageReaction fromJson(Map<String, dynamic> json) => MessageReaction(
        reactorId: json['reactorId'] as String,
        emoji: json['emoji'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );

  @override
  List<Object?> get props => [reactorId, emoji, timestamp];
}

/// A chat message between two peers in the Sphere network.
class Message with EquatableMixin {
  final String id;
  final String senderId;
  final String recipientId;
  final String content;
  final DateTime timestamp;
  final bool delivered;
  final List<String> mediaRefs;
  final String? audioRef;

  /// Set when this message is a reply to a story.
  ///
  /// A story reply is a private message to the author, not a comment the
  /// sphere can see — so it travels on the ratcheted direct path like any
  /// other message and simply carries the story it answers.
  ///
  /// Only the id is carried. The story itself is not copied in: the author
  /// already has it, and stories expire, so a reply to one that has gone is
  /// shown as replying to an expired story rather than resurrecting content
  /// that was meant to disappear.
  final String? replyToStoryId;

  /// Set when this message quotes an earlier one in the same conversation.
  final String? replyToMessageId;

  /// Reactions from either participant, keyed by who left them.
  final List<MessageReaction> reactions;

  const Message({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.timestamp,
    this.delivered = false,
    this.mediaRefs = const [],
    this.audioRef,
    this.replyToStoryId,
    this.replyToMessageId,
    this.reactions = const [],
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      senderId: json['senderId'] as String,
      recipientId: json['recipientId'] as String,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      delivered: json['delivered'] as bool? ?? false,
      mediaRefs: (json['mediaRefs'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      audioRef: json['audioRef'] as String?,
      replyToStoryId: json['replyToStoryId'] as String?,
      replyToMessageId: json['replyToMessageId'] as String?,
      reactions: (json['reactions'] as List<dynamic>?)
              ?.map((e) => MessageReaction.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderId': senderId,
      'recipientId': recipientId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'delivered': delivered,
      'mediaRefs': mediaRefs,
      'audioRef': audioRef,
      if (replyToStoryId != null) 'replyToStoryId': replyToStoryId,
      if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
      // Omitted when empty: reactions arrive separately, so most messages on
      // the wire carry none and there is no reason to send an empty list.
      if (reactions.isNotEmpty)
        'reactions': reactions.map((r) => r.toJson()).toList(),
    };
  }

  Message copyWith({
    String? id,
    String? senderId,
    String? recipientId,
    String? content,
    DateTime? timestamp,
    bool? delivered,
    List<String>? mediaRefs,
    String? audioRef,
    String? replyToStoryId,
    String? replyToMessageId,
    List<MessageReaction>? reactions,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      delivered: delivered ?? this.delivered,
      mediaRefs: mediaRefs ?? this.mediaRefs,
      audioRef: audioRef ?? this.audioRef,
      replyToStoryId: replyToStoryId ?? this.replyToStoryId,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      reactions: reactions ?? this.reactions,
    );
  }

  @override
  List<Object?> get props =>
      [id, senderId, recipientId, content, timestamp, delivered, mediaRefs,
        audioRef, replyToStoryId, replyToMessageId, reactions];
}
