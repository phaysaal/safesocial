import 'package:equatable/equatable.dart';

/// A chat message between two peers in the Sphere network.
class Message with EquatableMixin {
  final String id;
  final String senderId;
  final String recipientId;
  final String content;
  final DateTime timestamp;
  final bool delivered;
  final List<String> mediaRefs;

  const Message({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.timestamp,
    this.delivered = false,
    this.mediaRefs = const [],
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
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      delivered: delivered ?? this.delivered,
      mediaRefs: mediaRefs ?? this.mediaRefs,
    );
  }

  @override
  List<Object?> get props =>
      [id, senderId, recipientId, content, timestamp, delivered, mediaRefs];
}
