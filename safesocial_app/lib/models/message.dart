import 'package:equatable/equatable.dart';
import 'media_provenance.dart';

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

  /// What the sender's device could tell about each media item's origin, one
  /// entry per [mediaRefs] entry (null where nothing was assessed).
  final List<MediaProvenance?> provenance;
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

  /// Set when the author changed the text after sending.
  final DateTime? editedAt;

  /// Set when the author deleted it for everyone. The text is gone; a
  /// tombstone stays so the conversation does not silently lose a turn.
  final DateTime? deletedAt;

  /// Disappearing messages: gone from every device after this moment. Carried
  /// in the message so both sides delete on the same schedule.
  final DateTime? expiresAt;

  /// Media that may be opened once, then is deleted on the viewer's device.
  final bool viewOnce;

  /// Re-sent from another conversation.
  final bool forwarded;

  /// What this message is: 'text' (default), 'poll', 'location', 'contact',
  /// 'video_note', 'event', 'system'. Structured content lives in [payload].
  final String kind;
  final Map<String, dynamic>? payload;

  /// Identity keys of members mentioned with @, so clients can highlight and
  /// notify them.
  final List<String> mentions;

  /// Who has read it, by identity key. Filled from read receipts.
  final List<String> readBy;

  const Message({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.timestamp,
    this.delivered = false,
    this.mediaRefs = const [],
    this.provenance = const [],
    this.audioRef,
    this.replyToStoryId,
    this.replyToMessageId,
    this.reactions = const [],
    this.editedAt,
    this.deletedAt,
    this.expiresAt,
    this.viewOnce = false,
    this.forwarded = false,
    this.kind = 'text',
    this.payload,
    this.mentions = const [],
    this.readBy = const [],
  });

  bool get isDeleted => deletedAt != null;
  bool get isExpired => expiresAt != null && expiresAt!.isBefore(DateTime.now());
  bool get isPoll => kind == 'poll';
  bool get isLocation => kind == 'location';
  bool get isContactCard => kind == 'contact';
  bool get isSystem => kind == 'system';

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
      provenance: MediaProvenance.listFromJson(json['provenance']),
      audioRef: json['audioRef'] as String?,
      replyToStoryId: json['replyToStoryId'] as String?,
      replyToMessageId: json['replyToMessageId'] as String?,
      reactions: (json['reactions'] as List<dynamic>?)
              ?.map((e) => MessageReaction.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      editedAt: _date(json['editedAt']),
      deletedAt: _date(json['deletedAt']),
      expiresAt: _date(json['expiresAt']),
      viewOnce: json['viewOnce'] as bool? ?? false,
      forwarded: json['forwarded'] as bool? ?? false,
      kind: json['kind'] as String? ?? 'text',
      payload: (json['payload'] as Map?)?.cast<String, dynamic>(),
      mentions: (json['mentions'] as List<dynamic>?)?.cast<String>() ?? const [],
      readBy: (json['readBy'] as List<dynamic>?)?.cast<String>() ?? const [],
    );
  }

  static DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'senderId': senderId,
      'recipientId': recipientId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'delivered': delivered,
      'mediaRefs': mediaRefs,
      if (MediaProvenance.listToJson(provenance) != null)
        'provenance': MediaProvenance.listToJson(provenance),
      'audioRef': audioRef,
      if (replyToStoryId != null) 'replyToStoryId': replyToStoryId,
      if (replyToMessageId != null) 'replyToMessageId': replyToMessageId,
      // Omitted when empty: reactions arrive separately, so most messages on
      // the wire carry none and there is no reason to send an empty list.
      if (reactions.isNotEmpty)
        'reactions': reactions.map((r) => r.toJson()).toList(),
      if (editedAt != null) 'editedAt': editedAt!.toIso8601String(),
      if (deletedAt != null) 'deletedAt': deletedAt!.toIso8601String(),
      if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      if (viewOnce) 'viewOnce': true,
      if (forwarded) 'forwarded': true,
      if (kind != 'text') 'kind': kind,
      if (payload != null) 'payload': payload,
      if (mentions.isNotEmpty) 'mentions': mentions,
      if (readBy.isNotEmpty) 'readBy': readBy,
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
    List<MediaProvenance?>? provenance,
    String? audioRef,
    String? replyToStoryId,
    String? replyToMessageId,
    List<MessageReaction>? reactions,
    DateTime? editedAt,
    DateTime? deletedAt,
    DateTime? expiresAt,
    bool? viewOnce,
    bool? forwarded,
    String? kind,
    Map<String, dynamic>? payload,
    List<String>? mentions,
    List<String>? readBy,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      delivered: delivered ?? this.delivered,
      mediaRefs: mediaRefs ?? this.mediaRefs,
      provenance: provenance ?? this.provenance,
      audioRef: audioRef ?? this.audioRef,
      replyToStoryId: replyToStoryId ?? this.replyToStoryId,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      reactions: reactions ?? this.reactions,
      editedAt: editedAt ?? this.editedAt,
      deletedAt: deletedAt ?? this.deletedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      viewOnce: viewOnce ?? this.viewOnce,
      forwarded: forwarded ?? this.forwarded,
      kind: kind ?? this.kind,
      payload: payload ?? this.payload,
      mentions: mentions ?? this.mentions,
      readBy: readBy ?? this.readBy,
    );
  }

  @override
  List<Object?> get props => [
        id, senderId, recipientId, content, timestamp, delivered, mediaRefs,
        provenance, audioRef, replyToStoryId, replyToMessageId, reactions, editedAt,
        deletedAt, expiresAt, viewOnce, forwarded, kind, payload, mentions, readBy,
      ];
}
