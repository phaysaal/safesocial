import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/foundation.dart';
import 'secure_store.dart';

import '../crypto/envelope.dart';
import '../crypto/session_manager.dart';
import '../crypto/sphere_keyring.dart';
import '../crypto/spheres_crypto.dart';
import '../models/sphere.dart';
import '../models/sphere_event.dart';
import 'debug_log_service.dart';

/// A standalone signed assertion by one member, carried inside a membership
/// operation as proof that the operation was allowed.
///
/// This is how authority works without a server. An operation that one member
/// is not entitled to make on their own becomes legitimate when it carries
/// signed statements from the members who are — an owner's offer of ownership
/// today, a set of removal votes tomorrow. Every recipient checks the proof
/// themselves rather than trusting whoever transmitted it.
class SignedStatement {
  static const kindTransferOffer = 'transfer-offer';

  final String kind;
  final String sphereId;

  /// The epoch the statement was made at, so it can be judged against the
  /// membership that existed when it was signed.
  final int atEpoch;

  /// Who the statement is about.
  final String subject;

  /// Who signed it. The signature is checked against this key.
  final String by;

  final int timestampMs;
  final String signatureHex;

  const SignedStatement({
    required this.kind,
    required this.sphereId,
    required this.atEpoch,
    required this.subject,
    required this.by,
    required this.timestampMs,
    required this.signatureHex,
  });

  /// Newline-delimited for the same reason as everything else here: no field
  /// can contain a newline, so the encoding cannot be made ambiguous.
  static Uint8List bytesToSign({
    required String kind,
    required String sphereId,
    required int atEpoch,
    required String subject,
    required String by,
    required int timestampMs,
  }) =>
      Uint8List.fromList(utf8.encode([
        'spheres-statement',
        kind,
        sphereId,
        '$atEpoch',
        subject,
        by,
        '$timestampMs',
      ].join('\n')));

  Uint8List signedBytes() => bytesToSign(
        kind: kind,
        sphereId: sphereId,
        atEpoch: atEpoch,
        subject: subject,
        by: by,
        timestampMs: timestampMs,
      );

  /// Whether the signature really is [by]'s.
  bool get isSignatureValid {
    try {
      return ed.verify(
        ed.PublicKey(hex.decode(by)),
        signedBytes(),
        Uint8List.fromList(hex.decode(signatureHex)),
      );
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'sphereId': sphereId,
        'atEpoch': atEpoch,
        'subject': subject,
        'by': by,
        'ts': timestampMs,
        'sig': signatureHex,
      };

  static SignedStatement fromJson(Map<String, dynamic> json) => SignedStatement(
        kind: json['kind'] as String,
        sphereId: json['sphereId'] as String,
        atEpoch: json['atEpoch'] as int,
        subject: json['subject'] as String,
        by: json['by'] as String,
        timestampMs: json['ts'] as int,
        signatureHex: json['sig'] as String,
      );
}

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
  static const opDemote = 'demote';
  static const opTransfer = 'transfer';
  static const opRename = 'rename';

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
  final String description;
  final SphereKind kind;

  /// Statements that authorise this operation, when the author could not have
  /// made it alone. Empty for operations that rest on the author's own role.
  final List<SignedStatement> proof;

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
    this.description = '',
    this.proof = const [],
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
        if (description.isNotEmpty) 'description': description,
        if (proof.isNotEmpty) 'proof': proof.map((p) => p.toJson()).toList(),
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
      description: json['description'] as String? ?? '',
      kind: kind,
      members: (json['members'] as List<dynamic>)
          .map((m) => SphereMember.fromJson(m as Map<String, dynamic>))
          .toList(),
      proof: (json['proof'] as List<dynamic>? ?? const [])
          .map((p) => SignedStatement.fromJson(p as Map<String, dynamic>))
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
  static const _prefsAuditKey = 'spheres_sphere_audit_v1';
  static const _prefsOffersKey = 'spheres_transfer_offers_v1';

  /// Entries kept per sphere. Enough to cover any argument worth having, and
  /// bounded so a long-lived sphere cannot grow local storage without limit.
  static const int auditLimit = 200;

  final SphereKeyring keyring = SphereKeyring();
  final Map<String, Sphere> _spheres = {};

  /// Spheres we have been named in but have not agreed to join.
  ///
  /// Nothing is applied until the user accepts. Without this, anyone we have a
  /// session with could silently add us to a sphere and start receiving our
  /// posts to it.
  final Map<String, PendingInvite> _invites = {};

  /// Audit entries, newest last, keyed by sphere id.
  final Map<String, List<SphereEvent>> _audit = {};

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

  /// What has happened in a sphere, newest first.
  List<SphereEvent> eventsFor(String sphereId) =>
      (_audit[sphereId] ?? const <SphereEvent>[]).reversed.toList();

  /// Append an audit entry.
  Future<void> _record(
    Sphere sphere,
    String op,
    String target,
    String by, {
    String detail = '',
    DateTime? at,
  }) async {
    final entries = _audit.putIfAbsent(sphere.id, () => []);
    entries.add(SphereEvent(
      sphereId: sphere.id,
      op: op,
      by: by,
      target: target,
      epoch: sphere.epoch,
      at: at ?? DateTime.now(),
      detail: detail,
    ));
    if (entries.length > auditLimit) {
      entries.removeRange(0, entries.length - auditLimit);
    }
    await _persistAudit();
  }

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

  /// The sphere representing a one-to-one conversation.
  ///
  /// Derived deterministically from the two identity keys rather than created
  /// and negotiated: both sides compute the same id and the same two-member
  /// list without exchanging anything, so a DM needs no invitation and cannot
  /// drift out of sync.
  ///
  /// It carries no sphere key. Direct messages keep the ratcheted pairwise
  /// path, which gives forward secrecy that a shared sphere key cannot — the
  /// sphere here is the membership and presentation model, not the transport.
  Sphere directSphereWith(String peerIdentityKey) {
    _requireReady();
    final me = _myIdentityKey!;
    final ordered = [me, peerIdentityKey]..sort();
    final id = hex.encode(
      Uint8List.fromList(
        sha256.convert(utf8.encode('spheres-direct-v1:${ordered.join(':')}')).bytes,
      ),
    );

    final joinedAt = DateTime.fromMillisecondsSinceEpoch(0);
    return Sphere(
      id: id,
      name: 'Direct message',
      kind: SphereKind.direct,
      createdBy: ordered.first,
      createdAt: joinedAt,
      epoch: 1,
      members: ordered
          .map((k) => SphereMember(
                identityKey: k,
                role: SphereRole.admin,
                joinedAt: joinedAt,
                invitedBy: k,
              ))
          .toList(),
    );
  }

  /// True when [sphereId] is the derived DM sphere for some contact.
  bool isDirectSphere(String sphereId, List<String> contactKeys) {
    if (!isReady) return false;
    for (final contact in contactKeys) {
      if (directSphereWith(contact).id == sphereId) return true;
    }
    return false;
  }

  /// Create a sphere with us as its owner.
  ///
  /// [coAdmin] is strongly encouraged and the UI asks for one. A sphere whose
  /// only privileged member loses their phone cannot be re-keyed by anybody,
  /// which means no invites and no removals, ever. A second admin costs
  /// nothing and closes that hole before it can open.
  Future<Sphere> create({
    required String name,
    required SphereKind kind,
    List<String> initialMembers = const [],
    String? coAdmin,
    String description = '',
  }) async {
    _requireReady();
    final me = _myIdentityKey!;
    final now = DateTime.now();

    final sphere = Sphere(
      id: hex.encode(SpheresCrypto.randomBytes(32)),
      name: name,
      description: description,
      kind: kind,
      createdBy: me,
      createdAt: now,
      epoch: 1,
      members: [
        SphereMember(
          identityKey: me,
          role: SphereRole.owner,
          joinedAt: now,
          invitedBy: me,
        ),
        ...initialMembers.where((k) => k != me).map((k) => SphereMember(
              identityKey: k,
              role: k == coAdmin ? SphereRole.admin : SphereRole.member,
              joinedAt: now,
              invitedBy: me,
            )),
      ],
    );

    _spheres[sphere.id] = sphere;
    keyring.rotate(sphere.id, sphere.epoch);
    await _record(sphere, MembershipOp.opCreate, '', me, detail: name);
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
    await _record(next, MembershipOp.opAdd, identityKey, _myIdentityKey!);
    await _broadcast(next, MembershipOp.opAdd, identityKey);
  }

  /// Remove someone and re-key without them.
  Future<void> removeMember(String sphereId, String identityKey) async {
    final sphere = _requireAdmin(sphereId);
    if (!sphere.contains(identityKey)) return;
    if (sphere.isOwner(identityKey)) {
      // An admin removing the owner would be a coup, and would orphan the
      // sphere. Owners leave by leaving, which hands ownership on.
      throw StateError('The owner of "${sphere.name}" cannot be removed');
    }

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members:
          sphere.members.where((m) => m.identityKey != identityKey).toList(),
    );

    await _applyLocally(next);
    await _record(next, MembershipOp.opRemove, identityKey, _myIdentityKey!);
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
    await _record(next, MembershipOp.opPromote, identityKey, _myIdentityKey!);
    await _broadcast(next, MembershipOp.opPromote, identityKey);
  }

  /// Take admin away from someone.
  ///
  /// Only the owner may demote another admin, and anyone may demote
  /// themselves. Letting any admin demote any other would turn a disagreement
  /// between admins into a race, decided by whichever operation reached the
  /// most devices first. Routing it through a single owner makes the outcome
  /// unambiguous, and stepping down yourself needs nobody's permission.
  Future<void> demote(String sphereId, String identityKey) async {
    _requireReady();
    final sphere = _spheres[sphereId];
    if (sphere == null) throw StateError('Unknown sphere $sphereId');
    final me = _myIdentityKey!;

    final member = sphere.memberFor(identityKey);
    if (member == null || !member.isAdmin) return;

    if (member.isOwner) {
      throw StateError(
        'The owner cannot be demoted. Transfer ownership first, or leave.',
      );
    }
    if (identityKey != me && !sphere.isOwner(me)) {
      throw StateError('Only the owner can demote another admin');
    }

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members: sphere.members
          .map((m) => m.identityKey == identityKey
              ? m.copyWith(role: SphereRole.member)
              : m)
          .toList(),
    );

    await _applyLocally(next);
    await _record(next, MembershipOp.opDemote, identityKey, me);
    await _broadcast(next, MembershipOp.opDemote, identityKey);
  }

  /// Change the name or description. Admins and the owner may do this.
  Future<void> rename(
    String sphereId, {
    String? name,
    String? description,
  }) async {
    final sphere = _requireAdmin(sphereId);
    final newName = (name ?? sphere.name).trim();
    final newDescription = (description ?? sphere.description).trim();
    if (newName.isEmpty) throw StateError('A sphere needs a name');
    if (newName == sphere.name && newDescription == sphere.description) return;

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      name: newName,
      description: newDescription,
    );

    await _applyLocally(next);
    await _record(next, MembershipOp.opRename, '', _myIdentityKey!,
        detail: newName);
    await _broadcast(next, MembershipOp.opRename, '');
  }

  // ── Ownership ──────────────────────────────────────────────────────────────

  /// How long an offer of ownership stays good for.
  ///
  /// Bounded so an offer made and forgotten cannot be cashed in much later,
  /// against a sphere whose membership has moved on.
  static const Duration transferOfferValidity = Duration(days: 7);

  /// Offers of ownership made to us, by sphere id.
  final Map<String, SignedStatement> _transferOffers = {};

  /// Offers of ownership addressed to us that are still good.
  List<SignedStatement> get ownershipOffers => _transferOffers.values
      .where((o) => !_offerExpired(o, DateTime.now().millisecondsSinceEpoch))
      .toList(growable: false);

  SignedStatement? ownershipOfferFor(String sphereId) {
    final offer = _transferOffers[sphereId];
    if (offer == null) return null;
    if (_offerExpired(offer, DateTime.now().millisecondsSinceEpoch)) return null;
    return offer;
  }

  static bool _offerExpired(SignedStatement offer, int nowMs) =>
      nowMs - offer.timestampMs > transferOfferValidity.inMilliseconds;

  /// Offer ownership to another member.
  ///
  /// Nothing changes yet: the offer only becomes a transfer when the successor
  /// accepts it. Ownership carries obligations, and dropping it on somebody who
  /// has stopped using the app would be exactly the orphaned sphere the role
  /// exists to prevent.
  ///
  /// The offer is broadcast to everyone, not just the successor. Members need
  /// it to verify the eventual transfer, and a pending change of ownership is
  /// something a sphere should be able to see coming.
  Future<void> offerOwnership(String sphereId, String successor) async {
    _requireReady();
    final sphere = _spheres[sphereId];
    if (sphere == null) throw StateError('Unknown sphere $sphereId');
    final me = _myIdentityKey!;

    if (!sphere.isOwner(me)) {
      throw StateError('Only the owner can offer ownership');
    }
    if (successor == me) throw StateError('You already own this sphere');
    if (!sphere.contains(successor)) {
      throw StateError('Ownership can only go to a member');
    }

    final offer = _sign(
      kind: SignedStatement.kindTransferOffer,
      sphereId: sphereId,
      atEpoch: sphere.epoch,
      subject: successor,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );

    await _record(sphere, 'transfer-offer', successor, me);
    await _sendStatement(sphere, offer);
    notifyListeners();
  }

  /// Accept an offer of ownership, becoming the owner.
  ///
  /// We execute this ourselves rather than asking the outgoing owner to,
  /// because they may already be gone — which is often precisely why they
  /// handed it over. The offer travels with the operation as proof, so every
  /// member verifies our authority from the previous owner's signature instead
  /// of taking our word for it.
  Future<void> acceptOwnership(String sphereId) async {
    _requireReady();
    final sphere = _spheres[sphereId];
    if (sphere == null) throw StateError('Unknown sphere $sphereId');
    final me = _myIdentityKey!;

    final offer = ownershipOfferFor(sphereId);
    if (offer == null) {
      throw StateError('There is no current offer of ownership to accept');
    }
    if (offer.subject != me) {
      throw StateError('That offer of ownership was not made to you');
    }
    if (!sphere.isOwner(offer.by)) {
      throw StateError('The member who offered this is no longer the owner');
    }

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members: _membersAfterTransfer(sphere, offer.by, me),
    );

    _transferOffers.remove(sphereId);
    await _persistOffers();
    await _applyLocally(next);
    await _record(next, MembershipOp.opTransfer, me, me);
    await _broadcast(next, MembershipOp.opTransfer, me, proof: [offer]);
  }

  /// The member list a transfer must produce: the outgoing owner keeps admin,
  /// the successor takes owner, nothing else moves.
  static List<SphereMember> _membersAfterTransfer(
    Sphere sphere,
    String from,
    String to,
  ) =>
      sphere.members.map((m) {
        if (m.identityKey == from) return m.copyWith(role: SphereRole.admin);
        if (m.identityKey == to) return m.copyWith(role: SphereRole.owner);
        return m;
      }).toList();

  /// Leave a sphere, discarding its keys so its content becomes unreadable here.
  ///
  /// Leaving is unconditional — nobody should be held in a sphere they are
  /// uncomfortable in, least of all by a rule this app invented. An owner who
  /// leaves therefore hands ownership on in the same operation, to the
  /// longest-serving admin, or the longest-serving member if there is no other
  /// admin. Every device derives the same successor from the member list, so
  /// this needs no negotiation and cannot leave the sphere disagreeing.
  Future<void> leave(String sphereId) async {
    final sphere = _spheres[sphereId];
    if (sphere == null) return;
    final me = _myIdentityKey!;

    final remaining =
        sphere.members.where((m) => m.identityKey != me).toList();
    final heir = sphere.isOwner(me) ? sphere.successorAfter(me) : null;

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members: heir == null
          ? remaining
          : remaining
              .map((m) => m.identityKey == heir
                  ? m.copyWith(role: SphereRole.owner)
                  : m)
              .toList(),
    );
    await _broadcastOp(next, MembershipOp.opLeave, me, includeKey: false);

    _spheres.remove(sphereId);
    _audit.remove(sphereId);
    _transferOffers.remove(sphereId);
    keyring.forget(sphereId);
    await keyring.persist();
    await _persistAudit();
    await _persistOffers();
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

  Future<void> _broadcast(
    Sphere sphere,
    String op,
    String target, {
    List<SignedStatement> proof = const [],
  }) =>
      _broadcastOp(sphere, op, target, includeKey: true, proof: proof);

  /// Sign a statement as ourselves.
  SignedStatement _sign({
    required String kind,
    required String sphereId,
    required int atEpoch,
    required String subject,
    required int timestampMs,
  }) {
    final me = _myIdentityKey!;
    final signature = ed.sign(
      ed.PrivateKey(hex.decode(_myIdentitySecret!)),
      SignedStatement.bytesToSign(
        kind: kind,
        sphereId: sphereId,
        atEpoch: atEpoch,
        subject: subject,
        by: me,
        timestampMs: timestampMs,
      ),
    );
    return SignedStatement(
      kind: kind,
      sphereId: sphereId,
      atEpoch: atEpoch,
      subject: subject,
      by: me,
      timestampMs: timestampMs,
      signatureHex: hex.encode(signature),
    );
  }

  /// Send a standalone statement to every other member.
  Future<void> _sendStatement(Sphere sphere, SignedStatement statement) async {
    final send = sendToPeer;
    final sessions = _sessions;
    if (send == null || sessions == null) return;

    final payload = jsonEncode({'statement': statement.toJson()});
    for (final peer in sphere.othersThan(_myIdentityKey!)) {
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
        DebugLogService().warn(
            'Sphere', 'No encryption key for $peer yet; they will not see this');
      } catch (e) {
        DebugLogService().error('Sphere', 'Could not send statement: $e');
      }
    }
  }

  /// Send a signed membership operation, and optionally the new epoch key,
  /// to every current member.
  Future<void> _broadcastOp(
    Sphere sphere,
    String op,
    String target, {
    required bool includeKey,
    List<SignedStatement> proof = const [],
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
      description: sphere.description,
      kind: sphere.kind,
      proof: proof,
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

      final statementJson = payload['statement'];
      if (statementJson is Map<String, dynamic>) {
        await _handleIncomingStatement(senderIdentityKey, statementJson);
        return;
      }

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
        if (op.epoch <= existing.epoch) {
          // Already applied, or an attempt to replay an older state.
          return;
        }
        final refusal = _authorityRefusal(existing, op);
        if (refusal != null) {
          DebugLogService().warn('Sphere', 'Rejecting op: $refusal');
          return;
        }
      }

      final updated = Sphere(
        id: op.sphereId,
        name: op.name,
        description: op.description,
        kind: op.kind,
        createdBy: existing.createdBy,
        createdAt: existing.createdAt,
        epoch: op.epoch,
        members: Sphere.normaliseOwnership(op.members, existing.createdBy),
      );

      // If we were removed, drop the sphere and its keys.
      if (!updated.contains(_myIdentityKey!)) {
        _spheres.remove(op.sphereId);
        _audit.remove(op.sphereId);
        _transferOffers.remove(op.sphereId);
        keyring.forget(op.sphereId);
        await keyring.persist();
        await _persistAudit();
        await _persistOffers();
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
      await _record(updated, op.op, op.target, op.by,
          detail: op.op == MembershipOp.opRename ? op.name : '',
          at: DateTime.fromMillisecondsSinceEpoch(op.timestampMs));
      await _persist();
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Sphere', 'Could not apply membership op: $e');
    }
  }

  /// Why [op] may not be applied to [existing], or null if it may be.
  ///
  /// Authority used to be one blanket question — is the author an admin? That
  /// is too coarse now that operations differ in who is entitled to make them,
  /// and too trusting: an admin could send any member list they liked. For the
  /// operations added here the resulting membership is *recomputed* from state
  /// we already hold and compared, so the author gets to trigger a change but
  /// not to define it.
  String? _authorityRefusal(Sphere existing, MembershipOp op) {
    switch (op.op) {
      case MembershipOp.opLeave:
        // A member who leaves removes only themselves.
        if (op.target != op.by) return 'a leave may only remove its author';
        if (!existing.contains(op.by)) return '${op.by} is not a member';
        final heir =
            existing.isOwner(op.by) ? existing.successorAfter(op.by) : null;
        final expected = existing.members
            .where((m) => m.identityKey != op.by)
            .map((m) => m.identityKey == heir
                ? m.copyWith(role: SphereRole.owner)
                : m)
            .toList();
        return _membersMatch(expected, op.members)
            ? null
            : 'the member list does not match a leave by ${op.by}';

      case MembershipOp.opTransfer:
        if (op.by != op.target) {
          return 'ownership is claimed by the successor, not handed over';
        }
        if (!existing.contains(op.by)) return '${op.by} is not a member';

        final owner = existing.ownerKey;
        if (owner == null) return 'this sphere has no owner to transfer from';

        final offer = op.proof.where((p) =>
            p.kind == SignedStatement.kindTransferOffer &&
            p.sphereId == existing.id &&
            p.by == owner &&
            p.subject == op.target);
        if (offer.isEmpty) return 'no offer of ownership from the owner';
        final proof = offer.first;
        if (!proof.isSignatureValid) return 'the offer of ownership is forged';
        if (_offerExpired(proof, op.timestampMs)) {
          return 'the offer of ownership has expired';
        }

        return _membersMatch(
                _membersAfterTransfer(existing, owner, op.target), op.members)
            ? null
            : 'the member list does not match a transfer to ${op.target}';

      case MembershipOp.opDemote:
        final subject = existing.memberFor(op.target);
        if (subject == null || !subject.isAdmin) {
          return '${op.target} is not an admin';
        }
        if (subject.isOwner) return 'the owner cannot be demoted';
        if (op.by != op.target && !existing.isOwner(op.by)) {
          return 'only the owner can demote another admin';
        }
        final demoted = existing.members
            .map((m) => m.identityKey == op.target
                ? m.copyWith(role: SphereRole.member)
                : m)
            .toList();
        return _membersMatch(demoted, op.members)
            ? null
            : 'the member list does not match a demotion of ${op.target}';

      case MembershipOp.opRename:
        if (!existing.isAdmin(op.by)) return '${op.by} is not an admin';
        if (op.name.trim().isEmpty) return 'a sphere needs a name';
        return _membersMatch(existing.members, op.members)
            ? null
            : 'a rename may not change the member list';

      case MembershipOp.opRemove:
        if (!existing.isAdmin(op.by)) return '${op.by} is not an admin';
        if (existing.isOwner(op.target)) return 'the owner cannot be removed';
        return null;

      default:
        if (!existing.isAdmin(op.by)) return '${op.by} is not an admin';
        return null;
    }
  }

  /// Whether two member lists name the same people in the same roles. Order is
  /// not significant; it is a set comparison in list form.
  static bool _membersMatch(List<SphereMember> a, List<SphereMember> b) {
    if (a.length != b.length) return false;
    String describe(SphereMember m) => '${m.identityKey}:${m.role.name}';
    final left = a.map(describe).toList()..sort();
    final right = b.map(describe).toList()..sort();
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  /// Hold an offer of ownership made to us.
  Future<void> _handleIncomingStatement(
    String senderIdentityKey,
    Map<String, dynamic> json,
  ) async {
    final statement = SignedStatement.fromJson(json);
    if (statement.by != senderIdentityKey) return;
    if (!statement.isSignatureValid) {
      DebugLogService().warn('Sphere', 'Rejecting statement: bad signature');
      return;
    }
    if (statement.kind != SignedStatement.kindTransferOffer) return;

    final sphere = _spheres[statement.sphereId];
    if (sphere == null || !sphere.isOwner(statement.by)) {
      DebugLogService().warn(
          'Sphere', 'Rejecting ownership offer: ${statement.by} is not owner');
      return;
    }

    await _record(sphere, 'transfer-offer', statement.subject, statement.by,
        at: DateTime.fromMillisecondsSinceEpoch(statement.timestampMs));

    // Everyone records the offer for the audit log, but only the person it
    // names can act on it.
    if (statement.subject == _myIdentityKey) {
      _transferOffers[statement.sphereId] = statement;
      await _persistOffers();
    }
    notifyListeners();
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
    final prefs = SecureStore.instance;

    final invitesRaw = await prefs.getString(_prefsInvitesKey);
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

    final auditRaw = await prefs.getString(_prefsAuditKey);
    if (auditRaw != null) {
      try {
        final decoded = jsonDecode(auditRaw) as Map<String, dynamic>;
        decoded.forEach((sphereId, entries) {
          _audit[sphereId] = (entries as List<dynamic>)
              .map((e) => SphereEvent.fromJson(e as Map<String, dynamic>))
              .toList();
        });
      } catch (e) {
        DebugLogService().error('Sphere', 'Could not read the audit log: $e');
      }
    }

    final offersRaw = await prefs.getString(_prefsOffersKey);
    if (offersRaw != null) {
      try {
        for (final item in jsonDecode(offersRaw) as List<dynamic>) {
          final offer = SignedStatement.fromJson(item as Map<String, dynamic>);
          _transferOffers[offer.sphereId] = offer;
        }
      } catch (e) {
        DebugLogService()
            .error('Sphere', 'Could not read ownership offers: $e');
      }
    }

    final raw = await prefs.getString(_prefsKey);
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
    final prefs = SecureStore.instance;
    await prefs.setString(
      _prefsInvitesKey,
      jsonEncode(_invites.values.map((i) => i.toJson()).toList()),
    );
  }

  Future<void> _persistAudit() async {
    await SecureStore.instance.setString(
      _prefsAuditKey,
      jsonEncode(_audit.map((sphereId, entries) =>
          MapEntry(sphereId, entries.map((e) => e.toJson()).toList()))),
    );
  }

  Future<void> _persistOffers() async {
    await SecureStore.instance.setString(
      _prefsOffersKey,
      jsonEncode(_transferOffers.values.map((o) => o.toJson()).toList()),
    );
  }

  Future<void> _persist() async {
    final prefs = SecureStore.instance;
    await prefs.setString(
      _prefsKey,
      jsonEncode(_spheres.values.map((s) => s.toJson()).toList()),
    );
  }
}
