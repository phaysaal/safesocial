import 'package:equatable/equatable.dart';

/// A collaborative collection of media items.
/// A shared photo album.
///
/// Membership is the sphere's — an album no longer keeps its own member list,
/// which was a third parallel notion of "who can see this".
class Album with EquatableMixin {
  final String dhtKey;
  final String name;
  final String description;
  final String createdBy;
  final DateTime createdAt;
  final List<AlbumItem> items;
  /// The sphere this album belongs to.
  final String sphereId;

  const Album({
    required this.dhtKey,
    required this.name,
    this.description = '',
    required this.createdBy,
    required this.createdAt,
    this.items = const [],
    required this.sphereId,
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
      sphereId: json['sphereId'] as String? ?? '',
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
      'sphereId': sphereId,
    };
  }

  Album copyWith({
    String? name,
    String? description,
    List<AlbumItem>? items,
    String? sphereId,
  }) {
    return Album(
      dhtKey: dhtKey,
      name: name ?? this.name,
      description: description ?? this.description,
      createdBy: createdBy,
      createdAt: createdAt,
      items: items ?? this.items,
      sphereId: sphereId ?? this.sphereId,
    );
  }

  @override
  List<Object?> get props =>
      [dhtKey, name, description, createdBy, createdAt, items, sphereId];
}

/// A single media item (photo/video) within an album.
class AlbumItem with EquatableMixin {
  final String id;
  final String authorId;
  final String mediaRef; // BLAKE3 hash or local path
  final String type; // 'image' or 'video'
  final DateTime addedAt;

  /// Colour and light as numbers (`models/look.dart`), applied by every
  /// viewer at draw time; null for none.
  final Map<String, dynamic>? look;

  const AlbumItem({
    required this.id,
    required this.authorId,
    required this.mediaRef,
    required this.type,
    required this.addedAt,
    this.look,
  });

  factory AlbumItem.fromJson(Map<String, dynamic> json) {
    final look = json['look'];
    return AlbumItem(
      id: json['id'] as String,
      authorId: json['authorId'] as String,
      mediaRef: json['mediaRef'] as String,
      type: json['type'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
      look: look is Map ? Map<String, dynamic>.from(look) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'authorId': authorId,
      'mediaRef': mediaRef,
      'type': type,
      'addedAt': addedAt.toIso8601String(),
      if (look != null) 'look': look,
    };
  }

  AlbumItem copyWith({String? mediaRef, Map<String, dynamic>? look, bool clearLook = false}) => AlbumItem(
        id: id,
        authorId: authorId,
        mediaRef: mediaRef ?? this.mediaRef,
        type: type,
        addedAt: addedAt,
        look: clearLook ? null : (look ?? this.look),
      );

  @override
  List<Object?> get props => [id, authorId, mediaRef, type, addedAt, look];
}
