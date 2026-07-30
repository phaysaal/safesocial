import 'package:equatable/equatable.dart';

/// One entry in a sphere's audit log: something that changed, who changed it,
/// and when.
///
/// With no central authority, the check on admin power is that every member can
/// see what admins did. An admin action nobody can see is indistinguishable
/// from a server quietly doing as it pleases. It is also nearly free: every
/// membership change is already a signed operation that reaches every member,
/// so recording it is a matter of keeping what already arrives.
///
/// Entries are written when an operation is *applied*, so the log reflects what
/// this device actually acted on rather than what it was told. It is therefore
/// each member's own record, not a shared one — two members who were offline at
/// different times may hold different slices, and neither is authoritative.
class SphereEvent with EquatableMixin {
  final String sphereId;

  /// The [MembershipOp] constant this came from.
  final String op;

  /// Who performed it.
  final String by;

  /// Who it was about — empty for operations that are not about a person.
  final String target;

  /// Epoch the operation produced.
  final int epoch;

  final DateTime at;

  /// Extra context worth keeping, such as a sphere's new name after a rename.
  final String detail;

  const SphereEvent({
    required this.sphereId,
    required this.op,
    required this.by,
    required this.target,
    required this.epoch,
    required this.at,
    this.detail = '',
  });

  Map<String, dynamic> toJson() => {
        'sphereId': sphereId,
        'op': op,
        'by': by,
        'target': target,
        'epoch': epoch,
        'at': at.toIso8601String(),
        if (detail.isNotEmpty) 'detail': detail,
      };

  static SphereEvent fromJson(Map<String, dynamic> json) => SphereEvent(
        sphereId: json['sphereId'] as String,
        op: json['op'] as String,
        by: json['by'] as String,
        target: json['target'] as String? ?? '',
        epoch: json['epoch'] as int,
        at: DateTime.parse(json['at'] as String),
        detail: json['detail'] as String? ?? '',
      );

  @override
  List<Object?> get props => [sphereId, op, by, target, epoch, at, detail];
}
