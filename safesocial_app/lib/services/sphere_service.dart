import 'dart:convert';

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
import '../models/removal_vote.dart';
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

  /// A proposal to remove a member. [subject] is who would go, [detail] is the
  /// reason, and the statement's own signature is the proposal's identity.
  static const kindRemovalProposal = 'removal-proposal';

  /// A vote on a proposal. [ref] is the proposal it answers, and [detail] is
  /// 'yes' or 'no' — bound by the signature, so a vote cannot be flipped or
  /// replayed onto a different proposal.
  static const kindRemovalVote = 'removal-vote';

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

  /// What this statement answers, when it answers something — the signature of
  /// the proposal a vote is cast on. Empty otherwise.
  final String ref;

  /// Free text whose meaning depends on [kind]: a reason for a proposal, a
  /// 'yes' or 'no' for a vote.
  final String detail;

  final String signatureHex;

  const SignedStatement({
    required this.kind,
    required this.sphereId,
    required this.atEpoch,
    required this.subject,
    required this.by,
    required this.timestampMs,
    required this.signatureHex,
    this.ref = '',
    this.detail = '',
  });

  /// A statement's signature is its identity: unique, and bound to everything
  /// the statement says.
  String get id => signatureHex;

  /// Newline-delimited for the same reason as everything else here: no field
  /// can contain a newline, so the encoding cannot be made ambiguous.
  static Uint8List bytesToSign({
    required String kind,
    required String sphereId,
    required int atEpoch,
    required String subject,
    required String by,
    required int timestampMs,
    String ref = '',
    String detail = '',
  }) =>
      Uint8List.fromList(utf8.encode([
        'spheres-statement',
        kind,
        sphereId,
        '$atEpoch',
        subject,
        by,
        '$timestampMs',
        ref,
        // Newlines would make the encoding ambiguous, so they are stripped
        // rather than trusted. Callers should not send them in the first place.
        detail.replaceAll('\n', ' '),
      ].join('\n')));

  Uint8List signedBytes() => bytesToSign(
        kind: kind,
        sphereId: sphereId,
        atEpoch: atEpoch,
        subject: subject,
        by: by,
        timestampMs: timestampMs,
        ref: ref,
        detail: detail,
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
        if (ref.isNotEmpty) 'ref': ref,
        if (detail.isNotEmpty) 'detail': detail,
      };

  static SignedStatement fromJson(Map<String, dynamic> json) => SignedStatement(
        kind: json['kind'] as String,
        sphereId: json['sphereId'] as String,
        atEpoch: json['atEpoch'] as int,
        subject: json['subject'] as String,
        by: json['by'] as String,
        timestampMs: json['ts'] as int,
        signatureHex: json['sig'] as String,
        ref: json['ref'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
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

  /// A deterministic name for this operation, identical on every device.
  ///
  /// Derived rather than carried, so it cannot be chosen or lied about: it is
  /// a hash of exactly the bytes the author signed.
  String get id => hex.encode(sha256.convert(signedBytes()).bytes);

  /// Whether this operation should win against a concurrent sibling.
  ///
  /// Two operations can legitimately claim the same epoch — two admins acting
  /// at once, neither having seen the other. Somebody has to lose, and every
  /// device has to agree on which, or they diverge for good. Earlier wins;
  /// identical timestamps are broken by the hash, which is arbitrary but the
  /// same everywhere.
  ///
  /// Ordering by wall clock means a device with a slow clock tends to win.
  /// That decides which of two honest changes lands first and nothing else —
  /// authority is still checked separately — so it is not worth a distributed
  /// clock to fix.
  bool beats(MembershipOp other) {
    if (timestampMs != other.timestampMs) {
      return timestampMs < other.timestampMs;
    }
    return id.compareTo(other.id) < 0;
  }

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
        // The exchange keys are signed too. They only address transport, but
        // an unsigned field an admin could rewrite in flight is not worth
        // leaving lying around.
        members
            .map((m) =>
                '${m.identityKey}:${m.role.name}:${m.keyExchangePublicKey ?? ''}')
            .join(','),
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

/// What produced a sphere's current epoch, and what it was applied to.
class _AppliedOp {
  final String id;
  final MembershipOp op;

  /// The sphere as it was immediately before. A concurrent sibling has to be
  /// judged against this, because that is the state its author was looking at.
  final Sphere previous;

  const _AppliedOp({
    required this.id,
    required this.op,
    required this.previous,
  });
}

/// Verified, decrypted sphere content.
class OpenedSphereContent {
  /// Author, proven by signature and confirmed to be a member.
  final String from;
  final String sphereId;
  final String type;
  final String plaintext;

  /// The envelope's own unique id.
  ///
  /// Used to name content without needing to understand it: a post, a like and
  /// a group message all arrive in exactly one envelope, so this is what lets
  /// two members compare what they hold without either having to interpret it.
  final String envelopeId;

  const OpenedSphereContent({
    required this.from,
    required this.sphereId,
    required this.type,
    required this.envelopeId,
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
  static const _prefsProposalsKey = 'spheres_removal_proposals_v1';

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

  /// The operation that produced each sphere's current epoch, and the state it
  /// was applied to.
  ///
  /// Kept so a concurrent sibling arriving afterwards can be judged against
  /// the same starting point its author had, rather than against a state that
  /// has already moved. Without it the winner of a tie would be rejected for
  /// describing a membership that no longer matches.
  final Map<String, _AppliedOp> _applied = {};

  /// Superseded operations of our own that we have already re-issued, so a
  /// losing change is retried once and does not loop.
  final Set<String> _reissued = {};

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
    String? myExchangeKey,
  }) {
    _sessions = sessions;
    _myIdentityKey = identityKey;
    _myIdentitySecret = identitySecret;
    _resolveExchangeKey = resolveExchangeKey;
    _myExchangeKey = myExchangeKey;
  }

  String? _myExchangeKey;

  /// The X25519 key to record for [identityKey] in a member list.
  String? _exchangeKeyFor(String identityKey) => identityKey == _myIdentityKey
      ? _myExchangeKey
      : _resolveExchangeKey?.call(identityKey);

  /// A fellow member's X25519 key, for reaching them directly.
  ///
  /// Falls back to the address book, which is the better source when we have
  /// it: a contact's key came from them, and this one came from whoever wrote
  /// the membership operation.
  String? memberExchangeKey(String sphereId, String memberKey) =>
      _resolveExchangeKey?.call(memberKey) ??
      _spheres[sphereId]?.memberFor(memberKey)?.keyExchangePublicKey;

  /// Members we could reach directly, for asking a peer rather than the author.
  List<String> reachableMembers(String sphereId) {
    final sphere = _spheres[sphereId];
    if (sphere == null) return const [];
    return sphere.members
        .map((m) => m.identityKey)
        .where((k) =>
            k != _myIdentityKey && memberExchangeKey(sphereId, k) != null)
        .toList(growable: false);
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
          keyExchangePublicKey: _myExchangeKey,
        ),
        ...initialMembers.where((k) => k != me).map((k) => SphereMember(
              identityKey: k,
              role: k == coAdmin ? SphereRole.admin : SphereRole.member,
              joinedAt: now,
              invitedBy: me,
              keyExchangePublicKey: _exchangeKeyFor(k),
            )),
      ],
    );

    _spheres[sphere.id] = sphere;
    keyring.rotate(sphere.id, sphere.epoch);
    // Every other path that rotates writes the keyring straight after; this
    // one did not. The key survived only in memory, so the creator of a sphere
    // lost the ability to post to it at the next restart — permanently, since
    // the one person who could re-key it was them.
    await keyring.persist();
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
          keyExchangePublicKey: _exchangeKeyFor(identityKey),
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

  // ── Removing someone by vote ───────────────────────────────────────────────

  /// How long a removal vote stays open.
  ///
  /// People are offline. A vote that closes in an hour disenfranchises anyone
  /// asleep, and a decision nobody could take part in is not legitimacy, it is
  /// just a faster way to reach the same place.
  static const Duration removalWindow = Duration(hours: 72);

  /// How long before the same person can be proposed again after a failed
  /// vote, so a majority cannot wear a minority down by repetition.
  static const Duration removalCooldown = Duration(days: 7);

  /// Open and recently-closed proposals, by their id (the proposal signature).
  final Map<String, SignedStatement> _proposals = {};

  /// Votes, keyed by proposal id then voter.
  final Map<String, Map<String, SignedStatement>> _votes = {};

  /// Proposals in a sphere, newest first.
  List<SignedStatement> proposalsFor(String sphereId) {
    final list = _proposals.values
        .where((p) => p.sphereId == sphereId)
        .toList()
      ..sort((a, b) => b.timestampMs.compareTo(a.timestampMs));
    return list;
  }

  SignedStatement? proposal(String proposalId) => _proposals[proposalId];

  /// Our own vote on a proposal, if we have cast one.
  bool? myVoteOn(String proposalId) {
    final vote = _votes[proposalId]?[_myIdentityKey];
    if (vote == null) return null;
    return vote.detail == 'yes';
  }

  /// Where a proposal stands right now.
  RemovalTally tallyFor(SignedStatement proposal, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final sphere = _spheres[proposal.sphereId];
    final cast = _votes[proposal.id] ?? const <String, SignedStatement>{};

    // Recomputed against current membership, not membership at proposal time:
    // someone who has since left should not be counted as an absent voter.
    final eligible = sphere == null
        ? 0
        : sphere.members
            .where((m) =>
                m.identityKey != proposal.by && m.identityKey != proposal.subject)
            .length;

    var yes = 0;
    var no = 0;
    for (final entry in cast.entries) {
      if (sphere != null && !sphere.contains(entry.key)) continue;
      if (entry.key == proposal.subject || entry.key == proposal.by) continue;
      if (entry.value.detail == 'yes') {
        yes++;
      } else {
        no++;
      }
    }

    final closesAt = DateTime.fromMillisecondsSinceEpoch(proposal.timestampMs)
        .add(removalWindow);
    return RemovalTally(
      eligible: eligible,
      inFavour: yes,
      against: no,
      withinWindow: at.isBefore(closesAt),
    );
  }

  DateTime closesAt(SignedStatement proposal) =>
      DateTime.fromMillisecondsSinceEpoch(proposal.timestampMs)
          .add(removalWindow);

  /// Propose removing a member. Any member may do this.
  Future<void> proposeRemoval(
    String sphereId,
    String subject,
    String reason,
  ) async {
    _requireReady();
    final sphere = _spheres[sphereId];
    if (sphere == null) throw StateError('Unknown sphere $sphereId');
    final me = _myIdentityKey!;

    final refusal =
        removalProposalRefusal(sphere: sphere, proposer: me, subject: subject);
    if (refusal != null) throw StateError(refusal);

    final now = DateTime.now();
    for (final existing in proposalsFor(sphereId)) {
      if (existing.subject != subject) continue;
      final tally = tallyFor(existing, now: now);
      if (tally.outcome == RemovalOutcome.open) {
        throw StateError('There is already an open vote about this person');
      }
      final since =
          now.difference(DateTime.fromMillisecondsSinceEpoch(existing.timestampMs));
      if (since < removalCooldown) {
        final days = (removalCooldown - since).inDays + 1;
        throw StateError(
          'A vote about this person closed recently. Another can be raised in '
          '$days day${days == 1 ? '' : 's'}.',
        );
      }
    }

    final statement = _sign(
      kind: SignedStatement.kindRemovalProposal,
      sphereId: sphereId,
      atEpoch: sphere.epoch,
      subject: subject,
      timestampMs: now.millisecondsSinceEpoch,
      detail: reason.trim(),
    );

    _proposals[statement.id] = statement;
    await _persistProposals();
    await _record(sphere, 'removal-proposal', subject, me, detail: reason.trim());
    await _sendStatement(sphere, statement);
    notifyListeners();
  }

  /// Cast a vote. Voting again replaces the earlier vote — people change their
  /// minds, and the alternative is a first-click-wins race.
  Future<void> voteOnRemoval(String proposalId, {required bool inFavour}) async {
    _requireReady();
    final proposal = _proposals[proposalId];
    if (proposal == null) throw StateError('That vote no longer exists');
    final sphere = _spheres[proposal.sphereId];
    if (sphere == null) throw StateError('You are not in this sphere');
    final me = _myIdentityKey!;

    if (me == proposal.subject) {
      throw StateError('You cannot vote on your own removal');
    }
    if (me == proposal.by) {
      throw StateError('Proposing already counts as your view');
    }
    if (tallyFor(proposal).outcome != RemovalOutcome.open) {
      throw StateError('That vote has closed');
    }

    final vote = _sign(
      kind: SignedStatement.kindRemovalVote,
      sphereId: proposal.sphereId,
      atEpoch: sphere.epoch,
      subject: proposal.subject,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      ref: proposalId,
      detail: inFavour ? 'yes' : 'no',
    );

    _votes.putIfAbsent(proposalId, () => {})[me] = vote;
    await _persistProposals();
    await _sendStatement(sphere, vote);
    notifyListeners();
    await _executeIfPassed(proposal);
  }

  /// Carry out a removal that has passed.
  ///
  /// The votes travel with the operation, so every member verifies the outcome
  /// from the signatures rather than trusting whoever happened to execute it.
  Future<void> executeRemoval(String proposalId) async {
    _requireReady();
    final proposal = _proposals[proposalId];
    if (proposal == null) throw StateError('That vote no longer exists');
    final sphere = _spheres[proposal.sphereId];
    if (sphere == null) throw StateError('You are not in this sphere');

    if (!tallyFor(proposal).hasPassed) {
      throw StateError('That vote has not passed');
    }
    if (!sphere.contains(proposal.subject)) return; // Someone got there first.

    final proof = <SignedStatement>[
      proposal,
      ...(_votes[proposal.id] ?? const <String, SignedStatement>{})
          .values
          .where((v) => v.detail == 'yes'),
    ];

    final next = sphere.copyWith(
      epoch: sphere.epoch + 1,
      members: sphere.members
          .where((m) => m.identityKey != proposal.subject)
          .toList(),
    );

    await _applyLocally(next);
    await _record(next, MembershipOp.opRemove, proposal.subject, _myIdentityKey!,
        detail: 'by vote');
    await _broadcast(next, MembershipOp.opRemove, proposal.subject, proof: proof);
  }

  /// Execute automatically once a vote passes, so a decision does not sit
  /// waiting for somebody to notice.
  ///
  /// Admins act first because they are the ones expected to. If the sphere has
  /// no admin left — the orphaned case — any member may, since otherwise the
  /// vote would be decided and permanently unenforceable.
  Future<void> _executeIfPassed(SignedStatement proposal) async {
    final sphere = _spheres[proposal.sphereId];
    if (sphere == null) return;
    if (!tallyFor(proposal).hasPassed) return;
    if (!sphere.contains(proposal.subject)) return;

    final me = _myIdentityKey!;
    final anyAdmin = sphere.members.any((m) => m.isAdmin);
    if (!sphere.isAdmin(me) && anyAdmin) return;

    try {
      await executeRemoval(proposal.id);
    } catch (e) {
      DebugLogService().error('Sphere', 'Could not carry out a removal: $e');
    }
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
    _forgetProposals(sphereId);
    keyring.forget(sphereId);
    await keyring.persist();
    await _persistAudit();
    await _persistOffers();
    await _persistProposals();
    await _persist();
    notifyListeners();
  }

  /// State a local change was applied to, waiting for the operation that
  /// describes it to be built.
  final Map<String, Sphere> _pendingPrevious = {};

  Future<void> _applyLocally(Sphere next) async {
    final previous = _spheres[next.id];
    if (previous != null) _pendingPrevious[next.id] = previous;
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
    String ref = '',
    String detail = '',
  }) {
    final me = _myIdentityKey!;
    // Stripped here as well as in the encoding, so what we store matches what
    // we signed and a recipient's verification cannot disagree with ours.
    final safeDetail = detail.replaceAll('\n', ' ');
    final signature = ed.sign(
      ed.PrivateKey(hex.decode(_myIdentitySecret!)),
      SignedStatement.bytesToSign(
        kind: kind,
        sphereId: sphereId,
        atEpoch: atEpoch,
        subject: subject,
        by: me,
        timestampMs: timestampMs,
        ref: ref,
        detail: safeDetail,
      ),
    );
    return SignedStatement(
      kind: kind,
      sphereId: sphereId,
      atEpoch: atEpoch,
      subject: subject,
      by: me,
      timestampMs: timestampMs,
      ref: ref,
      detail: safeDetail,
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

    // Record what we changed and what we changed it from, before anything is
    // sent. A sibling from someone who had not seen this yet is judged against
    // the same starting point we used.
    final previous = _pendingPrevious.remove(sphere.id);
    if (previous != null) {
      _applied[sphere.id] = _AppliedOp(
        id: membershipOp.id,
        op: membershipOp,
        previous: previous,
      );
    }

    final send = sendToPeer;
    final sessions = _sessions;
    if (send == null || sessions == null) return;

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
        if (op.epoch < existing.epoch) {
          // Genuinely old, or a replay.
          return;
        }

        if (op.epoch == existing.epoch) {
          // A sibling: someone else changed the same epoch without having seen
          // our change, or this is simply the one we already applied.
          final resolved = await _resolveConcurrent(existing, op, payload);
          if (!resolved) return;
          // The incoming operation won and has been applied.
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
        _forgetProposals(op.sphereId);
        keyring.forget(op.sphereId);
        await keyring.persist();
        await _persistAudit();
        await _persistOffers();
        await _persistProposals();
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
      _applied[op.sphereId] = _AppliedOp(
        id: op.id,
        op: op,
        previous: existing,
      );
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
        if (existing.isOwner(op.target)) return 'the owner cannot be removed';
        // Either the author holds the power themselves, or they carry the
        // votes of members who do. Anything else is somebody helping
        // themselves to a decision that was not theirs.
        if (existing.isAdmin(op.by)) return null;
        return _removalVoteRefusal(existing, op);

      default:
        if (!existing.isAdmin(op.by)) return '${op.by} is not an admin';
        return null;
    }
  }

  /// Why a vote-backed removal is not valid, or null if it is.
  ///
  /// The executor may be any member — often the only one online — so their
  /// authority comes entirely from the proof they carry. Every signature is
  /// checked here rather than trusted, and the tally is recomputed from
  /// membership this device already holds.
  String? _removalVoteRefusal(Sphere existing, MembershipOp op) {
    final proposals = op.proof.where((p) =>
        p.kind == SignedStatement.kindRemovalProposal &&
        p.sphereId == existing.id &&
        p.subject == op.target);
    if (proposals.isEmpty) return '${op.by} is not an admin, and carries no vote';

    final proposal = proposals.first;
    if (!proposal.isSignatureValid) return 'the proposal is forged';

    final refusal = removalProposalRefusal(
      sphere: existing,
      proposer: proposal.by,
      subject: proposal.subject,
    );
    if (refusal != null) return 'the proposal was not allowed: $refusal';

    final voters = <String>{};
    for (final vote in op.proof) {
      if (vote.kind != SignedStatement.kindRemovalVote) continue;
      if (vote.ref != proposal.id) continue;
      if (vote.detail != 'yes') continue;
      if (!vote.isSignatureValid) return 'a vote is forged';
      if (!existing.contains(vote.by)) continue;
      if (vote.by == proposal.by || vote.by == proposal.subject) continue;
      if (DateTime.fromMillisecondsSinceEpoch(vote.timestampMs)
          .isAfter(closesAt(proposal))) {
        continue;
      }
      voters.add(vote.by);
    }

    final eligible = existing.members
        .where((m) =>
            m.identityKey != proposal.by && m.identityKey != proposal.subject)
        .length;
    // Only the yes votes travel, so the tally is judged on those alone: it has
    // to clear the quorum and be a majority of what was cast.
    final tally = RemovalTally(
      eligible: eligible,
      inFavour: voters.length,
      against: 0,
      withinWindow: false,
    );
    if (!tally.quorumMet) return 'not enough members voted';
    if (!tally.majority) return 'the vote did not carry';
    return null;
  }

  /// Whether two member lists name the same people in the same roles. Order is
  /// not significant; it is a set comparison in list form.
  static bool _membersMatch(List<SphereMember> a, List<SphereMember> b) {
    if (a.length != b.length) return false;
    String describe(SphereMember m) =>
        '${m.identityKey}:${m.role.name}:${m.keyExchangePublicKey ?? ''}';
    final left = a.map(describe).toList()..sort();
    final right = b.map(describe).toList()..sort();
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  Future<void> _handleRemovalProposal(SignedStatement statement) async {
    final sphere = _spheres[statement.sphereId];
    if (sphere == null) return;

    // The same rule the proposer's device applied, checked independently.
    final refusal = removalProposalRefusal(
      sphere: sphere,
      proposer: statement.by,
      subject: statement.subject,
    );
    if (refusal != null) {
      DebugLogService().warn('Sphere', 'Rejecting removal proposal: $refusal');
      return;
    }
    if (_proposals.containsKey(statement.id)) return;

    _proposals[statement.id] = statement;
    await _persistProposals();
    await _record(sphere, 'removal-proposal', statement.subject, statement.by,
        detail: statement.detail,
        at: DateTime.fromMillisecondsSinceEpoch(statement.timestampMs));
    notifyListeners();
  }

  Future<void> _handleRemovalVote(SignedStatement vote) async {
    final proposal = _proposals[vote.ref];
    if (proposal == null) {
      // The vote arrived before the proposal it answers. Dropping it is safe:
      // the voter's device keeps its own copy, and a resend will carry it.
      DebugLogService()
          .info('Sphere', 'Ignoring a vote for a proposal we do not have');
      return;
    }
    if (vote.sphereId != proposal.sphereId) return;

    final sphere = _spheres[proposal.sphereId];
    if (sphere == null) return;
    if (!sphere.contains(vote.by)) return;
    if (vote.by == proposal.subject || vote.by == proposal.by) return;
    if (vote.detail != 'yes' && vote.detail != 'no') return;

    // Late votes do not count, and cannot be used to reopen a closed decision.
    final at = DateTime.fromMillisecondsSinceEpoch(vote.timestampMs);
    if (at.isAfter(closesAt(proposal))) return;

    final existing = _votes.putIfAbsent(proposal.id, () => {})[vote.by];
    // A voter may change their mind; only their latest vote counts.
    if (existing != null && existing.timestampMs >= vote.timestampMs) return;

    _votes[proposal.id]![vote.by] = vote;
    await _persistProposals();
    notifyListeners();
    await _executeIfPassed(proposal);
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
    if (statement.kind == SignedStatement.kindRemovalProposal) {
      await _handleRemovalProposal(statement);
      return;
    }
    if (statement.kind == SignedStatement.kindRemovalVote) {
      await _handleRemovalVote(statement);
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

  /// Decide between an operation we already applied and a sibling claiming the
  /// same epoch.
  ///
  /// Returns true when [op] won and has been applied. Both devices run the
  /// same comparison over the same two operations and reach the same answer,
  /// which is the whole point: previously the second to arrive was discarded
  /// as a replay, so two admins acting at once left the sphere with two
  /// different member lists and nothing to notice it.
  Future<bool> _resolveConcurrent(
    Sphere existing,
    MembershipOp op,
    Map<String, dynamic> payload,
  ) async {
    final applied = _applied[existing.id];
    if (applied == null) {
      // We joined at this epoch rather than applying an operation to reach it,
      // so we have no basis for comparison and nothing to roll back to.
      return false;
    }
    if (applied.id == op.id) return false; // The very one we applied.

    if (!op.beats(applied.op)) {
      DebugLogService().info('Sphere',
          'A concurrent change by ${op.by} was superseded by an earlier one');
      await _record(existing, 'superseded', op.target, op.by);
      return false;
    }

    // It wins. Judge it against the state its author saw, not ours.
    final refusal = _authorityRefusal(applied.previous, op);
    if (refusal != null) {
      DebugLogService().warn('Sphere', 'Rejecting concurrent op: $refusal');
      return false;
    }

    final updated = Sphere(
      id: op.sphereId,
      name: op.name,
      description: op.description,
      kind: op.kind,
      createdBy: applied.previous.createdBy,
      createdAt: applied.previous.createdAt,
      epoch: op.epoch,
      members: Sphere.normaliseOwnership(op.members, applied.previous.createdBy),
    );

    final displaced = applied.op;

    if (!updated.contains(_myIdentityKey!)) {
      // The change that won removes us. Leave exactly as we would have if it
      // had arrived first.
      await _dropSphere(op.sphereId);
      DebugLogService().info('Sphere', 'Removed from "${updated.name}"');
      return true;
    }

    // Its key replaces the one we stored for this epoch, so everyone ends up
    // encrypting to the same thing. Content we sealed in the gap — usually
    // seconds — is unreadable to others, which is the unavoidable cost of two
    // people having changed the same epoch.
    final keyB64 = payload['sphereKey'];
    if (keyB64 is String) {
      try {
        keyring.store(
            op.sphereId, op.epoch, Uint8List.fromList(base64Decode(keyB64)));
        await keyring.persist();
      } catch (e) {
        DebugLogService().error('Sphere', 'Bad key on a concurrent op: $e');
      }
    }

    _spheres[op.sphereId] = updated;
    _applied[op.sphereId] =
        _AppliedOp(id: op.id, op: op, previous: applied.previous);
    await _record(updated, op.op, op.target, op.by,
        detail: op.op == MembershipOp.opRename ? op.name : '',
        at: DateTime.fromMillisecondsSinceEpoch(op.timestampMs));
    await _record(updated, 'superseded', displaced.target, displaced.by);
    await _persist();
    notifyListeners();

    DebugLogService().warn(
      'Sphere',
      'A change by ${displaced.by} was superseded by an earlier one from '
      '${op.by}',
    );

    // Ours lost. Put it back, once, if it still needs doing.
    if (displaced.by == _myIdentityKey) {
      await _reapplyOurIntent(displaced, updated);
    }
    return true;
  }

  /// Re-issue a change of ours that lost a tie, if it is still wanted.
  ///
  /// Without this the losing change is simply forgotten — an admin's removal
  /// or promotion quietly undone by someone else's unrelated edit landing at
  /// the same moment. Guarded so it happens once and cannot loop, and skipped
  /// when the winner already achieved the same thing.
  Future<void> _reapplyOurIntent(MembershipOp displaced, Sphere now) async {
    if (!_reissued.add(displaced.id)) return;
    if (!now.isAdmin(_myIdentityKey!)) return;

    try {
      switch (displaced.op) {
        case MembershipOp.opAdd:
          if (!now.contains(displaced.target)) {
            await addMember(now.id, displaced.target);
          }
        case MembershipOp.opRemove:
          if (now.contains(displaced.target)) {
            await removeMember(now.id, displaced.target);
          }
        case MembershipOp.opPromote:
          if (now.memberFor(displaced.target)?.isAdmin == false) {
            await promote(now.id, displaced.target);
          }
        case MembershipOp.opDemote:
          if (now.memberFor(displaced.target)?.isAdmin == true) {
            await demote(now.id, displaced.target);
          }
        case MembershipOp.opRename:
          if (now.name != displaced.name) {
            await rename(now.id,
                name: displaced.name, description: displaced.description);
          }
        default:
          // Transfers and leaves are not retried: both are decisions about a
          // state that has since changed, and redoing them unasked would be
          // presumptuous.
          break;
      }
    } catch (e) {
      DebugLogService()
          .warn('Sphere', 'Could not re-apply a superseded change: $e');
    }
  }

  /// Forget a sphere and everything hanging off it.
  Future<void> _dropSphere(String sphereId) async {
    _spheres.remove(sphereId);
    _audit.remove(sphereId);
    _transferOffers.remove(sphereId);
    _applied.remove(sphereId);
    _forgetProposals(sphereId);
    keyring.forget(sphereId);
    await keyring.persist();
    await _persistAudit();
    await _persistOffers();
    await _persistProposals();
    await _persist();
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
      envelopeId: envelope.id,
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

    final proposalsRaw = await prefs.getString(_prefsProposalsKey);
    if (proposalsRaw != null) {
      try {
        final decoded = jsonDecode(proposalsRaw) as Map<String, dynamic>;
        for (final item in decoded['proposals'] as List<dynamic>? ?? const []) {
          final statement =
              SignedStatement.fromJson(item as Map<String, dynamic>);
          _proposals[statement.id] = statement;
        }
        (decoded['votes'] as Map<String, dynamic>? ?? {}).forEach((id, list) {
          for (final item in list as List<dynamic>) {
            final vote = SignedStatement.fromJson(item as Map<String, dynamic>);
            _votes.putIfAbsent(id, () => {})[vote.by] = vote;
          }
        });
      } catch (e) {
        DebugLogService().error('Sphere', 'Could not read removal votes: $e');
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

  void _forgetProposals(String sphereId) {
    final ids = _proposals.entries
        .where((e) => e.value.sphereId == sphereId)
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      _proposals.remove(id);
      _votes.remove(id);
    }
  }

  Future<void> _persistProposals() async {
    await SecureStore.instance.setString(
      _prefsProposalsKey,
      jsonEncode({
        'proposals': _proposals.values.map((p) => p.toJson()).toList(),
        'votes': _votes.map((id, byVoter) =>
            MapEntry(id, byVoter.values.map((v) => v.toJson()).toList())),
      }),
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
