import 'package:equatable/equatable.dart';

/// A collaborative collection of media items.
class Album with EquatableMixin {
  final String dhtKey;
  final String name;
  final String description;
  final String createdBy;
  final DateTime createdAt;
  final List<AlbumItem> items;
  final List<String> memberPublicKeys;

  const Album({
    required this.dhtKey,
    required this.name,
    this.description = '',
    required this.createdBy,
    required this.createdAt,
    this.items = const [],
    this.memberPublicKeys = const [],
  });

  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      dhtKey: json['dhtKey'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      createdBy: json['createdBy'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      items: (json['items'] as List<dynamic>?)
              ?.map((e) => AlbumItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      memberPublicKeys: (json['memberPublicKeys'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dhtKey': dhtKey,
      'name': name,
      'description': description,
      'createdBy': createdBy,
      'createdAt': createdAt.toIso8601String(),
      'items': items.map((e) => e.toJson()).toList(),
      'memberPublicKeys': memberPublicKeys,
    };
  }

  Album copyWith({
    String? name,
    String? description,
    List<AlbumItem>? items,
    List<String>? memberPublicKeys,
  }) {
    return Album(
      dhtKey: dhtKey,
      name: name ?? this.name,
      description: description ?? this.description,
      createdBy: createdBy,
      createdAt: createdAt,
      items: items ?? this.items,
      memberPublicKeys: memberPublicKeys ?? this.memberPublicKeys,
    );
  }

  @override
  List<Object?> get props =>
      [dhtKey, name, description, createdBy, createdAt, items, memberPublicKeys];
}

/// A single media item (photo/video) within an album.
class AlbumItem with EquatableMixin {
  final String id;
  final String authorId;
  final String mediaRef; // BLAKE3 hash or local path
  final String type; // 'image' or 'video'
  final DateTime addedAt;

  const AlbumItem({
    required this.id,
    required this.authorId,
    required this.mediaRef,
    required this.type,
    required this.addedAt,
  });

  factory AlbumItem.fromJson(Map<String, dynamic> json) {
    return AlbumItem(
      id: json['id'] as String,
      authorId: json['authorId'] as String,
      mediaRef: json['mediaRef'] as String,
      type: json['type'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'authorId': authorId,
      'mediaRef': mediaRef,
      'type': type,
      'addedAt': addedAt.toIso8601String(),
    };
  }

  @override
  List<Object?> get props => [id, authorId, mediaRef, type, addedAt];
}
