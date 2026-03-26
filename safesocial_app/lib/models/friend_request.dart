import 'package:equatable/equatable.dart';

/// Status of a friend request.
enum FriendRequestStatus { pending, accepted, rejected }

/// A friend request exchanged between two users.
/// Both parties must accept for a full friendship to form.
class FriendRequest with EquatableMixin {
  final String id;
  final String fromPublicKey;
  final String fromDisplayName;
  final String toPublicKey;
  final FriendRequestStatus status;
  final DateTime createdAt;
  final bool isIncoming;

  const FriendRequest({
    required this.id,
    required this.fromPublicKey,
    required this.fromDisplayName,
    required this.toPublicKey,
    required this.status,
    required this.createdAt,
    required this.isIncoming,
  });

  factory FriendRequest.fromJson(Map<String, dynamic> json) {
    return FriendRequest(
      id: json['id'] as String,
      fromPublicKey: json['fromPublicKey'] as String,
      fromDisplayName: json['fromDisplayName'] as String? ?? '',
      toPublicKey: json['toPublicKey'] as String,
      status: FriendRequestStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => FriendRequestStatus.pending,
      ),
      createdAt: DateTime.parse(json['createdAt'] as String),
      isIncoming: json['isIncoming'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'fromPublicKey': fromPublicKey,
      'fromDisplayName': fromDisplayName,
      'toPublicKey': toPublicKey,
      'status': status.name,
      'createdAt': createdAt.toIso8601String(),
      'isIncoming': isIncoming,
    };
  }

  FriendRequest copyWith({FriendRequestStatus? status}) {
    return FriendRequest(
      id: id,
      fromPublicKey: fromPublicKey,
      fromDisplayName: fromDisplayName,
      toPublicKey: toPublicKey,
      status: status ?? this.status,
      createdAt: createdAt,
      isIncoming: isIncoming,
    );
  }

  @override
  List<Object?> get props => [
        id,
        fromPublicKey,
        fromDisplayName,
        toPublicKey,
        status,
        createdAt,
        isIncoming,
      ];
}
