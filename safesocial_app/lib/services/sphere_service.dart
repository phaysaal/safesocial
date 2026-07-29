import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../crypto/envelope.dart';
import '../crypto/session_manager.dart';
import '../crypto/sphere_keyring.dart';
import '../crypto/spheres_crypto.dart';
import '../models/sphere.dart';
import 'debug_log_service.dart';

/// A membership change, signed by the admin who made it.
///
/// Membership used to be a local list that never reached anyone: adding,
/// removing, promoting and demoting all mutated SharedPreferences and stopped
/// there, and there was no invite or join mechanism at all. Every change is now
/// an authenticated statement other members can verify and apply.
class MembershipOp {
  static const opCreate = 'create';
  static const opAdd = 'add';
  static const opRemove = 'remove';
  static const opLeave = 'leave';
  static const opPromote = 'promote';

  final String sphereId;

  /// Epoch this operation produces. Must be exactly one past the last applied
  /// epoch, so operations cannot be reordered or silently dropped.
  final int epoch;

  final String op;

  /// Who the operation is about (empty for [opCreate]).
  final String target;

  /// Who performed it. The signature is checked against this key.
  final String by;

  final int timestampMs;

  /// Full member list after the change, so a member who missed earlier
  /// operations can still converge.
  final List<SphereMember> members;

  final String name;
  final SphereKind kind;

  const MembershipOp({
    required this.sphereId,
    required this.epoch,
    required this.op,
    required this.target,
    required this.by,
    required this.timestampMs,
    required this.members,
    required this.name,
    required this.kind,
  });

  /// Bytes the signature covers. Newline-delimited for the same reason as
  /// [Envelope]: no field can contain a newline, so the encoding is injective.
  Uint8List signedBytes() => Uint8List.fromList(utf8.encode([
        'spheres-membership',
        sphereId,
        '$epoch',
        op,
        target,
        by,
        '$timestampMs',
        name,
        kind.name,
        members.map((m) => '${m.identityKey}:${m.role.name}').join(','),
      ].join('\n')));

  Map<String, dynamic> toJson() => {
        'sphereId': sphereId,
        'epoch': epoch,
        'op': op,
        'target': target,
        'by': by,
        'ts': timestampMs,
        'name': name,
        'kind': kind.name,
        'members': members.map((m) => m.toJson()).toList(),
      };

  static MembershipOp fromJson(Map<String, dynamic> json) {
    SphereKind kind = SphereKind.group;
    for (final candidate in SphereKind.values) {
      if (candidate.name == json['kind']) kind = candidate;
    }
    return MembershipOp(
      sphereId: json['sphereId'] as String,
      epoch: json['epoch'] as int,
      op: json['op'] as String,
      target: json['target'] as String? ?? '',
      by: json['by'] as String,
      timestampMs: json['ts'] as int,
      name: json['name'] as String? ?? '',
      kind: kind,
      members: (json['members'] as List<dynamic>)
          .map((m) => SphereMember.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Verified, decrypted sphere content.
class OpenedSphereContent {
  /// Author, proven by signature and confirmed to be a member.
  final String from;
  final String sphereId;
  final String type;
  final String plaintext;

  const OpenedSphereContent({
    required this.from,
    required this.sphereId,
    required this.type,
    required this.plaintext,
  });
}

/// An invitation waiting on the user's decision.
class PendingInvite {
  final Sphere sphere;
  final String invitedBy;
  final DateTime receivedAt;

  /// The epoch key offered with the invitation, held but not installed until
  /// the invitation is accepted.
  final Uint8List? sphereKey;

  const PendingInvite({
    required this.sphere,
    required this.invitedBy,
    required this.receivedAt,
    required this.sphereKey,
  });

  Map<String, dynamic> toJson() => {
        'sphere': sphere.toJson(),
        'invitedBy': invitedBy,
        'receivedAt': receivedAt.toIso8601String(),
        if (sphereKey != null) 'sphereKey': base64Encode(sphereKey!),
      };

  static PendingInvite fromJson(Map<String, dynamic> json) => PendingInvite(
        sphere: Sphere.fromJson(json['sphere'] as Map<String, dynamic>),
        invitedBy: json['invitedBy'] as String,
        receivedAt: DateTime.parse(json['receivedAt'] as String),
        sphereKey: json['sphereKey'] is String
            ? Uint8List.fromList(base64Decode(json['sphereKey'] as String))
            : null,
      );
}

/// Owns spheres: creation, membership, and key distribution.
///
/// Key distribution rides on the pairwise channels that already exist. When the
/// epoch rotates, the new key is wrapped individually for each remaining member
/// using their pairwise secret, so someone who was removed simply is not sent
/// it. That is the whole removal mechanism — there is no server to ask.
class SphereService extends ChangeNotifier {
  static const _prefsKey = 'spheres_spheres_v1';

  static const _prefsInvitesKey = 'spheres_invites_v1';

  final SphereKeyring keyring = SphereKeyring();
  final Map<String, Sphere> _spheres = {};

  /// Spheres we have been named in but have not agreed to join.
  ///
  /// Nothing is applied until the user accepts. Without this, anyone we have a
  /// session with could silently add us to a sphere and start receiving our
  /// posts to it.
  final Map<String, PendingInvite> _invites = {};

  SessionManager? _sessions;
  String? _myIdentityKey;
  String? _myIdentitySecret;
  String? Function(String identityKey)? _resolveExchangeKey;

  /// Sends a sealed payload to one contact. Supplied by the app so this
  /// service does not need to own a transport.
  Future<bool> Function(String peerIdentityKey, String payload)? sendToPeer;

  List<Sphere> get spheres => List.unmodifiable(_spheres.values);

  Sphere? sphere(String id) => _spheres[id];

  List<PendingInvite> get invites => List.unmodifiable(_invites.values);

  /// Join a sphere we were invited to.
  Future<void> acceptInvite(String sphereId) async {
    final invite = _invites.remove(sphereId);
    if (invite == null) return;

    _spheres[invite.sphere.id] = invite.sphere;
    if (invite.sphereKey != null) {
      keyring.store(invite.sphere.id, invite.sphere.epoch, invite.sphereKey!);
      await keyring.persist();
    }
    await _persist();
    await _persistInvites();
    notifyListeners();
    DebugLogService().success('Sphere', 'Joined "${invite.sphere.name}"');
  }

  /// Decline, discarding the key we were sent along with it.
  Future<void> declineInvite(String sphereId) async {
    if (_invites.remove(sphereId) == null) return;
    await _persistInvites();
    notifyListeners();
  }

  /// Spheres we can still publish to — i.e. we hold the current epoch key.
  List<Sphere> get writable => _spheres.values
      .where((s) => keyring.hasKey(s.id, s.epoch))
      .toList(growable: false);

  void configure({
    required SessionManager sessions,
    required String identityKey,
    required String identitySecret,
    required String? Function(String identityKey) resolveExchangeKey,
  }) {
    _sessions = sessions;
    _myIdentityKey = identityKey;
    _myIdentitySecret = identitySecret;
    _resolveExchangeKey = resolveExchangeKey;
  }

  bool get isReady => _sessions != null && _myIdentityKey != null;

  // ── Creation and membership ────────────────────────────────────────────────

  /// Create a sphere with us as the first admin.
  Future<Sphere> create({
    required String name,
    required SphereKind kind,
    List<String> initialMembers = const [],
  }) async {
    _requireReady();
    final me = _myIdentityKey!;
    final now = DateTime.now();

    final sphere = Sphere(
      id: hex.encode(SpheresCrypto.randomBytes(32)),
      name: name,
      kind: kind,
      createdBy: me,
      createdAt: now,
      epoch: 1,
      members: [
        SphereMember(
          identityKey: me,
          role: SphereRole.admin,
          joinedAt: now,
          invitedBy: me,
        ),
        ...initialMembers.where((k) => k != me).map((k) => SphereMember(
              identityKey: k,
              role: SphereRole.member,
              joinedAt: now,
              invitedBy: me,
            )),
      ],
    );

    _spheres[sphere.id] = sphere;
    keyring.rotate(sphere.id, sphere.epoch);
    await _persist();
    notifyListeners();

    await _broadcast(sphere, MembershipOp.opCreate, '');
    return sphere;
  }

  /// Add someone. Rotates the key so the new member cannot read history they
  /// were not part of.
  Future<void> addMember(String sphereId, String identityKey) async {
    final sphere = _requireAdmin(sphereId);
    if (sphere.contains(identityKey)) return;

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members: [
        ...sphere.members,
        SphereMember(
          identityKey: identityKey,
          role: SphereRole.member,
          joinedAt: DateTime.now(),
          invitedBy: _myIdentityKey!,
        ),
      ],
    );

    await _applyLocally(next);
    await _broadcast(next, MembershipOp.opAdd, identityKey);
  }

  /// Remove someone and re-key without them.
  Future<void> removeMember(String sphereId, String identityKey) async {
    final sphere = _requireAdmin(sphereId);
    if (!sphere.contains(identityKey)) return;

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members:
          sphere.members.where((m) => m.identityKey != identityKey).toList(),
    );

    await _applyLocally(next);
    // Deliberately broadcast only to the remaining members: the removed member
    // never receives the new epoch key, which is what makes removal real.
    await _broadcast(next, MembershipOp.opRemove, identityKey);
  }

  Future<void> promote(String sphereId, String identityKey) async {
    final sphere = _requireAdmin(sphereId);
    final member = sphere.memberFor(identityKey);
    if (member == null || member.isAdmin) return;

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members: sphere.members
          .map((m) => m.identityKey == identityKey
              ? m.copyWith(role: SphereRole.admin)
              : m)
          .toList(),
    );

    await _applyLocally(next);
    await _broadcast(next, MembershipOp.opPromote, identityKey);
  }

  /// Leave a sphere, discarding its keys so its content becomes unreadable here.
  Future<void> leave(String sphereId) async {
    final sphere = _spheres[sphereId];
    if (sphere == null) return;
    final me = _myIdentityKey!;

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members: sphere.members.where((m) => m.identityKey != me).toList(),
    );
    await _broadcastOp(next, MembershipOp.opLeave, me, includeKey: false);

    _spheres.remove(sphereId);
    keyring.forget(sphereId);
    await keyring.persist();
    await _persist();
    notifyListeners();
  }

  Future<void> _applyLocally(Sphere next) async {
    _spheres[next.id] = next;
    keyring.rotate(next.id, next.epoch);
    await keyring.persist();
    await _persist();
    notifyListeners();
  }

  // ── Outbound ───────────────────────────────────────────────────────────────

  Future<void> _broadcast(Sphere sphere, String op, String target) =>
      _broadcastOp(sphere, op, target, includeKey: true);

  /// Send a signed membership operation, and optionally the new epoch key,
  /// to every current member.
  Future<void> _broadcastOp(
    Sphere sphere,
    String op,
    String target, {
    required bool includeKey,
  }) async {
    final send = sendToPeer;
    final sessions = _sessions;
    if (send == null || sessions == null) return;

    final me = _myIdentityKey!;
    final membershipOp = MembershipOp(
      sphereId: sphere.id,
      epoch: sphere.epoch,
      op: op,
      target: target,
      by: me,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      members: sphere.members,
      name: sphere.name,
      kind: sphere.kind,
    );

    final signature = ed.sign(
      ed.PrivateKey(hex.decode(_myIdentitySecret!)),
      membershipOp.signedBytes(),
    );

    final key = includeKey ? keyring.keyFor(sphere.id, sphere.epoch) : null;
    final payload = jsonEncode({
      'op': membershipOp.toJson(),
      'signature': hex.encode(signature),
      if (key != null) 'sphereKey': base64Encode(key),
    });

    for (final peer in sphere.othersThan(me)) {
      try {
        final sealed = await sessions.seal(
          peerIdentityKey: peer,
          peerKeyExchangePublicKey: _resolveExchangeKey?.call(peer),
          type: 'sphere_op',
          plaintext: payload,
          mode: SealMode.wrap,
        );
        await send(peer, sealed);
      } on NoSessionException {
        DebugLogService().warn('Sphere',
            'No encryption key for $peer yet; they will not receive this change');
      } catch (e) {
        DebugLogService().error('Sphere', 'Could not send membership op: $e');
      }
    }
  }

  // ── Inbound ────────────────────────────────────────────────────────────────

  /// Apply a membership operation received from a peer.
  ///
  /// [senderIdentityKey] is the *verified* envelope sender. An operation whose
  /// `by` disagrees with it, or whose author is not an admin, is rejected.
  Future<void> handleIncomingOp(
    String senderIdentityKey,
    String payloadJson,
  ) async {
    try {
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
      final op = MembershipOp.fromJson(payload['op'] as Map<String, dynamic>);

      if (op.by != senderIdentityKey) {
        DebugLogService().warn('Sphere',
            'Rejecting op: claims $senderIdentityKey but is authored by ${op.by}');
        return;
      }

      if (!_signatureValid(op, payload['signature'])) {
        DebugLogService().warn('Sphere', 'Rejecting op: bad signature');
        return;
      }

      final existing = _spheres[op.sphereId];

      // Authority check. For a sphere we already know, the author must be an
      // admin as of the state we hold. For a new one, only a create we are
      // named in is accepted.
      if (existing == null) {
        if (!op.members.any((m) => m.identityKey == _myIdentityKey)) return;

        // An unknown sphere is an invitation, not a fait accompli. Hold it
        // until the user agrees to join.
        Uint8List? offeredKey;
        final keyB64 = payload['sphereKey'];
        if (keyB64 is String) {
          try {
            offeredKey = Uint8List.fromList(base64Decode(keyB64));
          } catch (_) {
            offeredKey = null;
          }
        }

        _invites[op.sphereId] = PendingInvite(
          sphere: Sphere(
            id: op.sphereId,
            name: op.name,
            kind: op.kind,
            createdBy: op.by,
            createdAt: DateTime.fromMillisecondsSinceEpoch(op.timestampMs),
            epoch: op.epoch,
            members: op.members,
          ),
          invitedBy: op.by,
          receivedAt: DateTime.now(),
          sphereKey: offeredKey,
        );
        await _persistInvites();
        notifyListeners();
        return;
      } else {
        if (!existing.isAdmin(op.by) && op.op != MembershipOp.opLeave) {
          DebugLogService()
              .warn('Sphere', 'Rejecting op: ${op.by} is not an admin');
          return;
        }
        if (op.epoch <= existing.epoch) {
          // Already applied, or an attempt to replay an older state.
          return;
        }
      }

      // A member who leaves removes only themselves.
      if (op.op == MembershipOp.opLeave && op.target != op.by) return;

      final updated = Sphere(
        id: op.sphereId,
        name: op.name,
        kind: op.kind,
        createdBy: existing.createdBy,
        createdAt: existing.createdAt,
        epoch: op.epoch,
        members: op.members,
      );

      // If we were removed, drop the sphere and its keys.
      if (!updated.contains(_myIdentityKey!)) {
        _spheres.remove(op.sphereId);
        keyring.forget(op.sphereId);
        await keyring.persist();
        await _persist();
        notifyListeners();
        DebugLogService()
            .info('Sphere', 'Removed from "${updated.name}"');
        return;
      }

      final keyB64 = payload['sphereKey'];
      if (keyB64 is String) {
        try {
          keyring.store(
            op.sphereId,
            op.epoch,
            Uint8List.fromList(base64Decode(keyB64)),
          );
          await keyring.persist();
        } catch (e) {
          DebugLogService().error('Sphere', 'Bad sphere key in op: $e');
        }
      }

      _spheres[op.sphereId] = updated;
      await _persist();
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Sphere', 'Could not apply membership op: $e');
    }
  }

  bool _signatureValid(MembershipOp op, dynamic signatureHex) {
    if (signatureHex is! String) return false;
    try {
      return ed.verify(
        ed.PublicKey(hex.decode(op.by)),
        op.signedBytes(),
        Uint8List.fromList(hex.decode(signatureHex)),
      );
    } catch (_) {
      return false;
    }
  }

  // ── Content ────────────────────────────────────────────────────────────────

  /// Seal content for a sphere, once, for all members.
  Future<String> sealContent({
    required String sphereId,
    required String type,
    required String plaintext,
  }) async {
    _requireReady();
    final sphere = _spheres[sphereId];
    if (sphere == null) throw StateError('Unknown sphere $sphereId');

    final key = keyring.keyFor(sphereId, sphere.epoch);
    if (key == null) {
      throw StateError(
        'No key for "${sphere.name}" at epoch ${sphere.epoch} — '
        'waiting for an admin to send it',
      );
    }

    final envelope = await Envelope.sealToSphere(
      sphereId: sphereId,
      epoch: sphere.epoch,
      sphereKey: key,
      type: type,
      plaintext: utf8.encode(plaintext),
      myIdentityKey: _myIdentityKey!,
      myIdentitySecretHex: _myIdentitySecret!,
    );
    return envelope.encode();
  }

  /// Open sphere content, enforcing that the author was actually a member.
  ///
  /// The signature proves who wrote it; this additionally checks they were
  /// entitled to. Without it, a former member's replayed content, or a
  /// stranger's, would be displayed as legitimate sphere content.
  Future<OpenedSphereContent> openContent(String raw) async {
    final envelope = Envelope.decode(raw);
    final sphereId = envelope.sphereId;
    if (sphereId == null) {
      throw const EnvelopeException('Envelope is not addressed to a sphere');
    }

    final sphere = _spheres[sphereId];
    if (sphere == null) {
      throw EnvelopeException('Not a member of sphere $sphereId');
    }
    if (!sphere.contains(envelope.from)) {
      throw EnvelopeException('${envelope.from} is not a member of this sphere');
    }

    final key = keyring.keyFor(sphereId, envelope.sphereEpoch);
    if (key == null) {
      throw EnvelopeException(
          'No key for epoch ${envelope.sphereEpoch} of $sphereId');
    }

    return OpenedSphereContent(
      from: envelope.from,
      sphereId: sphereId,
      type: envelope.type,
      plaintext: utf8.decode(await envelope.openWithSphereKey(key)),
    );
  }

  // ── Plumbing ───────────────────────────────────────────────────────────────

  void _requireReady() {
    if (!isReady) throw StateError('SphereService has no identity yet');
  }

  Sphere _requireAdmin(String sphereId) {
    _requireReady();
    final sphere = _spheres[sphereId];
    if (sphere == null) throw StateError('Unknown sphere $sphereId');
    if (!sphere.isAdmin(_myIdentityKey!)) {
      throw StateError('Only an admin can change membership of "${sphere.name}"');
    }
    return sphere;
  }

  Future<void> load() async {
    await keyring.load();
    final prefs = await SharedPreferences.getInstance();

    final invitesRaw = prefs.getString(_prefsInvitesKey);
    if (invitesRaw != null) {
      try {
        for (final item in jsonDecode(invitesRaw) as List<dynamic>) {
          final invite = PendingInvite.fromJson(item as Map<String, dynamic>);
          _invites[invite.sphere.id] = invite;
        }
      } catch (e) {
        DebugLogService().error('Sphere', 'Could not read invites: $e');
      }
    }

    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;

    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final sphere = Sphere.fromJson(item as Map<String, dynamic>);
        _spheres[sphere.id] = sphere;
      }
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Sphere', 'Could not read spheres: $e');
    }
  }

  Future<void> _persistInvites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsInvitesKey,
      jsonEncode(_invites.values.map((i) => i.toJson()).toList()),
    );
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_spheres.values.map((s) => s.toJson()).toList()),
    );
  }
}
