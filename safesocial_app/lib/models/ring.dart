import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';

/// A private circle of contacts for granular sharing.
class Ring with EquatableMixin {
  final String id;
  final String name;
  final Color color;
  final List<String> memberPublicKeys;

  const Ring({
    required this.id,
    required this.name,
    this.color = Colors.blue,
    this.memberPublicKeys = const [],
  });

  factory Ring.fromJson(Map<String, dynamic> json) {
    return Ring(
      id: json['id'] as String,
      name: json['name'] as String,
      color: Color(json['color'] as int),
      memberPublicKeys: (json['memberPublicKeys'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'color': color.value,
      'memberPublicKeys': memberPublicKeys,
    };
  }

  Ring copyWith({
    String? id,
    String? name,
    Color? color,
    List<String>? memberPublicKeys,
  }) {
    return Ring(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      memberPublicKeys: memberPublicKeys ?? this.memberPublicKeys,
    );
  }

  @override
  List<Object?> get props => [id, name, color, memberPublicKeys];
}
