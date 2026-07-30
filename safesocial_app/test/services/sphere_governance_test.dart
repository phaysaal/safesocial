import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/removal_vote.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/models/sphere_event.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Governance without a server. Every power has to come from either the key
/// (you can always leave) or the members (a signed statement anyone can check),
/// so the tests here are mostly about what a peer is *refused*: authority they
/// do not hold, and member lists that do not match the operation they claim.
void main() {
  late String alice, aliceSecret;
  late String bob, bobSecret;
  late String carol, carolSecret;
  late String mallory, mallorySecret;

  String idOf(ed.KeyPair k) => hex.encode(k.publicKey.bytes);
  String secretOf(ed.KeyPair k) => hex.encode(k.privateKey.bytes);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();

    final a = ed.generateKey();
    final b = ed.generateKey();
    final c = ed.generateKey();
    final m = ed.generateKey();
    alice = idOf(a);
    aliceSecret = secretOf(a);
    bob = idOf(b);
    bobSecret = secretOf(b);
    carol = idOf(c);
    carolSecret = secretOf(c);
    mallory = idOf(m);
    mallorySecret = secretOf(m);
  });

  SphereService serviceFor(String identity, String secret) {
    final service = SphereService();
    service.configure(
      sessions: SessionManager(),
      identityKey: identity,
      identitySecret: secret,
      resolveExchangeKey: (_) => null,
    );
    return service;
  }

  SphereMember member(
    String key,
    SphereRole role, {
    DateTime? joinedAt,
  }) =>
      SphereMember(
        identityKey: key,
        role: role,
        joinedAt: joinedAt ?? DateTime(2026),
        invitedBy: alice,
      );

  SignedStatement statement({
    required String kind,
    required String sphereId,
    required int atEpoch,
    required String subject,
    required String by,
    required String bySecret,
    String ref = '',
    String detail = '',
    DateTime? at,
  }) {
    final ts = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final bytes = SignedStatement.bytesToSign(
      kind: kind,
      sphereId: sphereId,
      atEpoch: atEpoch,
      subject: subject,
      by: by,
      timestampMs: ts,
      ref: ref,
      detail: detail,
    );
    return SignedStatement(
      kind: kind,
      sphereId: sphereId,
      atEpoch: atEpoch,
      subject: subject,
      by: by,
      timestampMs: ts,
      ref: ref,
      detail: detail,
      signatureHex:
          hex.encode(ed.sign(ed.PrivateKey(hex.decode(bySecret)), bytes)),
    );
  }

  SignedStatement offer({
    required String sphereId,
    required int atEpoch,
    required String subject,
    required String by,
    required String bySecret,
    DateTime? at,
  }) {
    final ts = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final bytes = SignedStatement.bytesToSign(
      kind: SignedStatement.kindTransferOffer,
      sphereId: sphereId,
      atEpoch: atEpoch,
      subject: subject,
      by: by,
      timestampMs: ts,
    );
    return SignedStatement(
      kind: SignedStatement.kindTransferOffer,
      sphereId: sphereId,
      atEpoch: atEpoch,
      subject: subject,
      by: by,
      timestampMs: ts,
      signatureHex: hex.encode(ed.sign(ed.PrivateKey(hex.decode(bySecret)), bytes)),
    );
  }

  String signedOp({
    required String sphereId,
    required int epoch,
    required String op,
    required String target,
    required String author,
    required String authorSecret,
    required List<SphereMember> members,
    String name = 'Family',
    String description = '',
    List<SignedStatement> proof = const [],
    DateTime? at,
  }) {
    final membershipOp = MembershipOp(
      sphereId: sphereId,
      epoch: epoch,
      op: op,
      target: target,
      by: author,
      timestampMs: (at ?? DateTime(2026, 6)).millisecondsSinceEpoch,
      members: members,
      name: name,
      description: description,
      kind: SphereKind.group,
      proof: proof,
    );
    return jsonEncode({
      'op': membershipOp.toJson(),
      'signature': hex.encode(ed.sign(
        ed.PrivateKey(hex.decode(authorSecret)),
        membershipOp.signedBytes(),
      )),
    });
  }

  const sphereId =
      '1111111111111111111111111111111111111111111111111111111111111111';

  /// Bob's device, holding a sphere Alice owns with Carol also a member.
  Future<SphereService> bobInAlicesSphere({
    SphereRole bobRole = SphereRole.member,
    SphereRole carolRole = SphereRole.member,
  }) async {
    final service = serviceFor(bob, bobSecret);
    await service.handleIncomingOp(
      alice,
      signedOp(
        sphereId: sphereId,
        epoch: 1,
        op: MembershipOp.opCreate,
        target: '',
        author: alice,
        authorSecret: aliceSecret,
        members: [
          member(alice, SphereRole.owner),
          member(bob, bobRole),
          member(carol, carolRole),
        ],
      ),
    );
    await service.acceptInvite(sphereId);
    return service;
  }

  // ── Roles ─────────────────────────────────────────────────────────────────

  group('the owner role', () {
    test('the creator owns the sphere, and owning implies admin', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      expect(sphere.ownerKey, alice);
      expect(sphere.isOwner(alice), isTrue);
      expect(sphere.isAdmin(alice), isTrue);
    });

    test('a co-admin can be named at creation', () async {
      // The cheapest defence against an orphaned sphere: two people who can
      // re-key it, from the moment it exists.
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob, carol],
        coAdmin: bob,
      );

      expect(sphere.isAdmin(bob), isTrue);
      expect(sphere.isOwner(bob), isFalse);
      expect(sphere.isAdmin(carol), isFalse);
    });

    test('an admin cannot remove the owner', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob],
      );

      expect(() => service.removeMember(sphere.id, alice),
          throwsA(isA<StateError>()));
    });

    test('an unknown role is read as the least privileged one', () {
      // A client that meets a role from a future version must not guess
      // generously and hand out powers it does not understand.
      final decoded = SphereMember.fromJson({
        'identityKey': bob,
        'role': 'superuser',
        'joinedAt': DateTime(2026).toIso8601String(),
        'invitedBy': alice,
      });

      expect(decoded.role, SphereRole.member);
      expect(decoded.isAdmin, isFalse);
    });
  });

  group('surviving a restart', () {
    // Found on two emulators: Alice created a sphere, posted to it, restarted
    // the app, and the composer then said "No spheres yet". create() rotated
    // the keyring but never persisted it, so the epoch key lived only in
    // memory. The creator lost the ability to post to their own sphere, and
    // nobody could fix it — re-keying needs the key you no longer have.
    test('a sphere you created is still writable after a restart', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob],
      );

      final restarted = serviceFor(alice, aliceSecret);
      await restarted.load();

      expect(restarted.keyring.hasKey(sphere.id, 1), isTrue);
      expect(restarted.writable.map((s) => s.id), [sphere.id]);
    });

    test('a sphere you joined is still writable after a restart', () async {
      // This half already worked — acceptInvite persists — and it is what made
      // the bug so confusing: the invitee kept working, the creator did not.
      final service = await bobInAlicesSphere();
      expect(service.sphere(sphereId), isNotNull);

      final restarted = serviceFor(bob, bobSecret);
      await restarted.load();

      expect(restarted.sphere(sphereId), isNotNull);
    });

    test('sealing still works after a restart', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere =
          await service.create(name: 'Family', kind: SphereKind.group);

      final restarted = serviceFor(alice, aliceSecret);
      await restarted.load();

      // Threw "No key for ... waiting for an admin to send it" — to the admin.
      await restarted.sealContent(
          sphereId: sphere.id, type: 'post', plaintext: 'hello');
    });
  });

  // ── Demotion ──────────────────────────────────────────────────────────────

  group('demotion', () {
    test('the owner can take admin away from someone', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob],
        coAdmin: bob,
      );

      await service.demote(sphere.id, bob);

      expect(service.sphere(sphere.id)!.isAdmin(bob), isFalse);
      expect(service.sphere(sphere.id)!.epoch, 2);
    });

    test('an admin can step down without asking anyone', () async {
      final service = await bobInAlicesSphere(bobRole: SphereRole.admin);

      await service.demote(sphereId, bob);

      expect(service.sphere(sphereId)!.isAdmin(bob), isFalse);
    });

    test('an admin cannot demote another admin', () async {
      // Otherwise two admins who disagree race, and the winner is whoever
      // reaches the most devices first.
      final service = await bobInAlicesSphere(
        bobRole: SphereRole.admin,
        carolRole: SphereRole.admin,
      );

      expect(
        () => service.demote(sphereId, carol),
        throwsA(isA<StateError>()),
      );
    });

    test('the owner cannot demote themselves', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      // It would leave the sphere with nobody able to hand it on.
      expect(() => service.demote(sphere.id, alice),
          throwsA(isA<StateError>()));
    });

    test('demoting a plain member does nothing', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob],
      );

      await service.demote(sphere.id, bob);

      expect(service.sphere(sphere.id)!.epoch, 1);
    });
  });

  // ── Renaming ──────────────────────────────────────────────────────────────

  group('renaming', () {
    test('an admin can change the name and description', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      await service.rename(sphere.id, name: 'Close family', description: 'Us');

      final updated = service.sphere(sphere.id)!;
      expect(updated.name, 'Close family');
      expect(updated.description, 'Us');
    });

    test('a sphere cannot be renamed to nothing', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      expect(() => service.rename(sphere.id, name: '   '),
          throwsA(isA<StateError>()));
    });

    test('renaming to the same thing is not an operation', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      await service.rename(sphere.id, name: 'Family');

      // No epoch bump means no pointless re-key and no traffic.
      expect(service.sphere(sphere.id)!.epoch, 1);
    });

    test('a plain member cannot rename a sphere', () async {
      final service = await bobInAlicesSphere();

      expect(() => service.rename(sphereId, name: 'Bobs sphere'),
          throwsA(isA<StateError>()));
    });
  });

  // ── Transferring ownership ────────────────────────────────────────────────

  group('offering ownership', () {
    test('only the owner may offer it', () async {
      final service = await bobInAlicesSphere(bobRole: SphereRole.admin);

      expect(() => service.offerOwnership(sphereId, carol),
          throwsA(isA<StateError>()));
    });

    test('it can only go to a member', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      expect(() => service.offerOwnership(sphere.id, mallory),
          throwsA(isA<StateError>()));
    });

    test('offering changes nothing until it is accepted', () async {
      // Ownership dropped on someone who has stopped using the app is exactly
      // the orphaned sphere the role exists to prevent.
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob],
      );

      await service.offerOwnership(sphere.id, bob);

      expect(service.sphere(sphere.id)!.ownerKey, alice);
      expect(service.sphere(sphere.id)!.epoch, 1);
    });

    test('an offer reaches the person it names, and only them', () async {
      final bobService = await bobInAlicesSphere();
      final carolService = serviceFor(carol, carolSecret);
      await carolService.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(carol, SphereRole.member),
          ],
        ),
      );
      await carolService.acceptInvite(sphereId);

      final payload = jsonEncode({
        'statement': offer(
          sphereId: sphereId,
          atEpoch: 1,
          subject: bob,
          by: alice,
          bySecret: aliceSecret,
        ).toJson(),
      });

      await bobService.handleIncomingOp(alice, payload);
      await carolService.handleIncomingOp(alice, payload);

      expect(bobService.ownershipOfferFor(sphereId), isNotNull);
      // Carol can see it happened, but it is not hers to accept.
      expect(carolService.ownershipOfferFor(sphereId), isNull);
      expect(carolService.eventsFor(sphereId).first.op, 'transfer-offer');
    });

    test('an offer forged in the owner name is rejected', () async {
      final service = await bobInAlicesSphere();

      await service.handleIncomingOp(
        mallory,
        jsonEncode({
          'statement': offer(
            sphereId: sphereId,
            atEpoch: 1,
            subject: bob,
            by: mallory,
            bySecret: mallorySecret,
          ).toJson(),
        }),
      );

      expect(service.ownershipOfferFor(sphereId), isNull);
    });
  });

  group('accepting ownership', () {
    Future<SphereService> bobOffered({DateTime? at}) async {
      final service = await bobInAlicesSphere();
      await service.handleIncomingOp(
        alice,
        jsonEncode({
          'statement': offer(
            sphereId: sphereId,
            atEpoch: 1,
            subject: bob,
            by: alice,
            bySecret: aliceSecret,
            at: at,
          ).toJson(),
        }),
      );
      return service;
    }

    test('accepting makes the successor owner and the old owner an admin',
        () async {
      final service = await bobOffered();

      await service.acceptOwnership(sphereId);

      final sphere = service.sphere(sphereId)!;
      expect(sphere.ownerKey, bob);
      expect(sphere.memberFor(alice)!.role, SphereRole.admin);
      expect(sphere.memberFor(carol)!.role, SphereRole.member);
      expect(sphere.epoch, 2);
    });

    test('there is nothing to accept without an offer', () async {
      final service = await bobInAlicesSphere();

      expect(() => service.acceptOwnership(sphereId),
          throwsA(isA<StateError>()));
    });

    test('an offer older than a week is no longer good', () async {
      // A forgotten offer must not be cashable against a sphere that has
      // moved on since.
      final service = await bobOffered(
        at: DateTime.now().subtract(const Duration(days: 8)),
      );

      expect(service.ownershipOfferFor(sphereId), isNull);
      expect(() => service.acceptOwnership(sphereId),
          throwsA(isA<StateError>()));
    });

    test('an offer is spent once it is used', () async {
      final service = await bobOffered();
      await service.acceptOwnership(sphereId);

      expect(service.ownershipOfferFor(sphereId), isNull);
    });
  });

  // ── Inbound authority ─────────────────────────────────────────────────────

  group('what a peer is refused', () {
    test('a member cannot demote an admin', () async {
      final service = await bobInAlicesSphere(carolRole: SphereRole.admin);

      await service.handleIncomingOp(
        mallory,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opDemote,
          target: carol,
          author: mallory,
          authorSecret: mallorySecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(carol, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.isAdmin(carol), isTrue);
    });

    test('an admin cannot demote a fellow admin remotely either', () async {
      final service = await bobInAlicesSphere(
        bobRole: SphereRole.admin,
        carolRole: SphereRole.admin,
      );

      await service.handleIncomingOp(
        carol,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opDemote,
          target: bob,
          author: carol,
          authorSecret: carolSecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(carol, SphereRole.admin),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.isAdmin(bob), isTrue);
    });

    test('the owner demoting an admin is applied', () async {
      final service = await bobInAlicesSphere(carolRole: SphereRole.admin);

      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opDemote,
          target: carol,
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(carol, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.isAdmin(carol), isFalse);
    });

    test('a demotion that also changes other people is rejected', () async {
      // The author gets to trigger a change, not to define one. Without this,
      // "demote Carol" could smuggle in "and promote me".
      final service = await bobInAlicesSphere(carolRole: SphereRole.admin);

      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opDemote,
          target: carol,
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(carol, SphereRole.member),
            member(mallory, SphereRole.admin),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(mallory), isFalse);
      expect(service.sphere(sphereId)!.isAdmin(carol), isTrue);
    });

    test('a transfer with no proof of an offer is rejected', () async {
      final service = await bobInAlicesSphere();

      await service.handleIncomingOp(
        carol,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opTransfer,
          target: carol,
          author: carol,
          authorSecret: carolSecret,
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
            member(carol, SphereRole.owner),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.ownerKey, alice);
    });

    test('a transfer proved by someone who is not the owner is rejected',
        () async {
      final service = await bobInAlicesSphere(bobRole: SphereRole.admin);

      await service.handleIncomingOp(
        carol,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opTransfer,
          target: carol,
          author: carol,
          authorSecret: carolSecret,
          proof: [
            offer(
              sphereId: sphereId,
              atEpoch: 1,
              subject: carol,
              by: mallory,
              bySecret: mallorySecret,
            ),
          ],
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.admin),
            member(carol, SphereRole.owner),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.ownerKey, alice);
    });

    test('a transfer nobody offered to its claimant is rejected', () async {
      // The offer names Bob; Carol tries to spend it.
      final service = await bobInAlicesSphere();

      await service.handleIncomingOp(
        carol,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opTransfer,
          target: carol,
          author: carol,
          authorSecret: carolSecret,
          proof: [
            offer(
              sphereId: sphereId,
              atEpoch: 1,
              subject: bob,
              by: alice,
              bySecret: aliceSecret,
            ),
          ],
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
            member(carol, SphereRole.owner),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.ownerKey, alice);
    });

    test('a properly proved transfer is applied by everyone', () async {
      final service = await bobInAlicesSphere();

      await service.handleIncomingOp(
        carol,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opTransfer,
          target: carol,
          author: carol,
          authorSecret: carolSecret,
          at: DateTime.now(),
          proof: [
            offer(
              sphereId: sphereId,
              atEpoch: 1,
              subject: carol,
              by: alice,
              bySecret: aliceSecret,
              at: DateTime.now(),
            ),
          ],
          members: [
            member(alice, SphereRole.admin),
            member(bob, SphereRole.member),
            member(carol, SphereRole.owner),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.ownerKey, carol);
    });

    test('a rename may not smuggle in a membership change', () async {
      final service = await bobInAlicesSphere();

      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRename,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          name: 'Renamed',
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(carol, SphereRole.member),
            member(mallory, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.name, 'Family');
      expect(service.sphere(sphereId)!.contains(mallory), isFalse);
    });

    test('an admin cannot remove the owner', () async {
      final service = await bobInAlicesSphere(carolRole: SphereRole.admin);

      await service.handleIncomingOp(
        carol,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: alice,
          author: carol,
          authorSecret: carolSecret,
          members: [
            member(bob, SphereRole.member),
            member(carol, SphereRole.admin),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.ownerKey, alice);
    });

    test('a leave may not remove anybody else', () async {
      final service = await bobInAlicesSphere();

      await service.handleIncomingOp(
        carol,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opLeave,
          target: carol,
          author: carol,
          authorSecret: carolSecret,
          members: [member(alice, SphereRole.owner)],
        ),
      );

      expect(service.sphere(sphereId)!.contains(bob), isTrue);
      expect(service.sphere(sphereId)!.contains(carol), isTrue);
    });
  });

  // ── An owner walking away ─────────────────────────────────────────────────

  group('the owner leaving', () {
    test('ownership passes to the longest-serving admin', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(
        name: 'Family',
        kind: SphereKind.group,
        initialMembers: [bob, carol],
        coAdmin: carol,
      );

      expect(sphere.successorAfter(alice), carol);
    });

    test('with no other admin it passes to the longest-serving member',
        () async {
      final sphere = Sphere(
        id: sphereId,
        name: 'Family',
        kind: SphereKind.group,
        createdBy: alice,
        createdAt: DateTime(2026),
        epoch: 1,
        members: [
          member(alice, SphereRole.owner, joinedAt: DateTime(2026)),
          member(bob, SphereRole.member, joinedAt: DateTime(2026, 5)),
          member(carol, SphereRole.member, joinedAt: DateTime(2026, 2)),
        ],
      );

      expect(sphere.successorAfter(alice), carol);
    });

    test('every device picks the same successor regardless of list order', () {
      // The whole point of deriving it: nobody negotiates, and nobody ends up
      // disagreeing about who is in charge.
      final members = [
        member(alice, SphereRole.owner),
        member(bob, SphereRole.member, joinedAt: DateTime(2026, 3)),
        member(carol, SphereRole.member, joinedAt: DateTime(2026, 3)),
      ];

      Sphere withOrder(List<SphereMember> m) => Sphere(
            id: sphereId,
            name: 'Family',
            kind: SphereKind.group,
            createdBy: alice,
            createdAt: DateTime(2026),
            epoch: 1,
            members: m,
          );

      expect(
        withOrder(members).successorAfter(alice),
        withOrder(members.reversed.toList()).successorAfter(alice),
      );
    });

    test('the last member leaving has no successor', () {
      final sphere = Sphere(
        id: sphereId,
        name: 'Family',
        kind: SphereKind.group,
        createdBy: alice,
        createdAt: DateTime(2026),
        epoch: 1,
        members: [member(alice, SphereRole.owner)],
      );

      expect(sphere.successorAfter(alice), isNull);
    });

    test('a leave that hands ownership on is accepted', () async {
      final service = await bobInAlicesSphere(carolRole: SphereRole.admin);

      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opLeave,
          target: alice,
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(bob, SphereRole.member),
            member(carol, SphereRole.owner),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.ownerKey, carol);
      expect(service.sphere(sphereId)!.contains(alice), isFalse);
    });

    test('a leave that hands ownership to the wrong person is rejected',
        () async {
      final service = await bobInAlicesSphere(carolRole: SphereRole.admin);

      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opLeave,
          target: alice,
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(bob, SphereRole.owner),
            member(carol, SphereRole.admin),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(alice), isTrue);
    });
  });

  // ── Removal by vote ───────────────────────────────────────────────────────

  group('removal by vote', () {
    late String dave, daveSecret;

    setUp(() {
      final d = ed.generateKey();
      dave = idOf(d);
      daveSecret = secretOf(d);
    });

    /// Alice owns a sphere of four: Bob, Carol and Dave are plain members.
    Future<SphereService> bobInFoursome() async {
      final service = serviceFor(bob, bobSecret);
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(carol, SphereRole.member),
            member(dave, SphereRole.member),
          ],
        ),
      );
      await service.acceptInvite(sphereId);
      return service;
    }

    SignedStatement proposalBy(String who, String whoSecret, String subject,
            {DateTime? at}) =>
        statement(
          kind: SignedStatement.kindRemovalProposal,
          sphereId: sphereId,
          atEpoch: 1,
          subject: subject,
          by: who,
          bySecret: whoSecret,
          detail: 'Kept posting spoilers',
          at: at,
        );

    SignedStatement voteBy(String who, String whoSecret, SignedStatement on,
            {bool yes = true, DateTime? at}) =>
        statement(
          kind: SignedStatement.kindRemovalVote,
          sphereId: sphereId,
          atEpoch: 1,
          subject: on.subject,
          by: who,
          bySecret: whoSecret,
          ref: on.id,
          detail: yes ? 'yes' : 'no',
          at: at,
        );

    Future<void> deliver(SphereService to, String from, SignedStatement s) =>
        to.handleIncomingOp(from, jsonEncode({'statement': s.toJson()}));

    test('a member can propose removing another', () async {
      final service = await bobInFoursome();

      await service.proposeRemoval(sphereId, carol, 'Kept posting spoilers');

      final open = service.proposalsFor(sphereId);
      expect(open, hasLength(1));
      expect(open.single.subject, carol);
      expect(open.single.detail, 'Kept posting spoilers');
    });

    test('the reason is signed, so it cannot be rewritten in transit', () {
      final proposal = proposalBy(carol, carolSecret, dave);

      final tampered = SignedStatement(
        kind: proposal.kind,
        sphereId: proposal.sphereId,
        atEpoch: proposal.atEpoch,
        subject: proposal.subject,
        by: proposal.by,
        timestampMs: proposal.timestampMs,
        detail: 'Something far worse',
        signatureHex: proposal.signatureHex,
      );

      expect(tampered.isSignatureValid, isFalse);
    });

    test('a proposal from a stranger is refused', () async {
      final service = await bobInFoursome();

      await deliver(service, mallory, proposalBy(mallory, mallorySecret, carol));

      expect(service.proposalsFor(sphereId), isEmpty);
    });

    test('a proposal against the owner is refused', () async {
      final service = await bobInFoursome();

      await deliver(service, carol, proposalBy(carol, carolSecret, alice));

      expect(service.proposalsFor(sphereId), isEmpty);
    });

    test('the subject cannot vote on their own removal', () async {
      final service = serviceFor(carol, carolSecret);
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(carol, SphereRole.member),
            member(dave, SphereRole.member),
          ],
        ),
      );
      await service.acceptInvite(sphereId);

      final proposal = proposalBy(bob, bobSecret, carol);
      await deliver(service, bob, proposal);

      // Otherwise a sphere of two deadlocks permanently, and in any sphere the
      // subject holds a veto over their own accountability.
      expect(
        () => service.voteOnRemoval(proposal.id, inFavour: false),
        throwsA(isA<StateError>()),
      );
    });

    test('the proposer does not get a second vote', () async {
      final service = await bobInFoursome();
      await service.proposeRemoval(sphereId, carol, 'reason');
      final proposal = service.proposalsFor(sphereId).single;

      expect(
        () => service.voteOnRemoval(proposal.id, inFavour: true),
        throwsA(isA<StateError>()),
      );
      // Their proposal is their view; counting it twice would let a proposer
      // in a small sphere carry a vote alone.
      expect(service.tallyFor(proposal).inFavour, 0);
    });

    test('votes accumulate and the tally reflects them', () async {
      final service = await bobInFoursome();
      final proposal = proposalBy(bob, bobSecret, carol);
      await deliver(service, bob, proposal);

      await deliver(service, dave, voteBy(dave, daveSecret, proposal));

      final tally = service.tallyFor(proposal);
      expect(tally.eligible, 2); // Alice and Dave; not Bob, not Carol.
      expect(tally.inFavour, 1);
    });

    test('a voter can change their mind, and only the later vote counts',
        () async {
      final service = await bobInFoursome();
      final proposal = proposalBy(bob, bobSecret, carol);
      await deliver(service, bob, proposal);

      final t0 = DateTime.now();
      await deliver(service, dave,
          voteBy(dave, daveSecret, proposal, yes: true, at: t0));
      await deliver(
          service,
          dave,
          voteBy(dave, daveSecret, proposal,
              yes: false, at: t0.add(const Duration(minutes: 1))));

      expect(service.tallyFor(proposal).inFavour, 0);
      expect(service.tallyFor(proposal).against, 1);
    });

    test('an older vote cannot overwrite a newer one', () async {
      // A replayed earlier vote must not undo someone's change of mind.
      final service = await bobInFoursome();
      final proposal = proposalBy(bob, bobSecret, carol);
      await deliver(service, bob, proposal);

      final t0 = DateTime.now();
      await deliver(
          service,
          dave,
          voteBy(dave, daveSecret, proposal,
              yes: false, at: t0.add(const Duration(minutes: 1))));
      await deliver(service, dave,
          voteBy(dave, daveSecret, proposal, yes: true, at: t0));

      expect(service.tallyFor(proposal).against, 1);
    });

    test('a vote arriving after the window closes does not count', () async {
      final service = await bobInFoursome();
      final old = DateTime.now().subtract(const Duration(hours: 80));
      final proposal = proposalBy(bob, bobSecret, carol, at: old);
      await deliver(service, bob, proposal);

      await deliver(service, dave,
          voteBy(dave, daveSecret, proposal, at: DateTime.now()));

      expect(service.tallyFor(proposal).inFavour, 0);
      expect(service.tallyFor(proposal).outcome,
          RemovalOutcome.expiredWithoutQuorum);
    });

    test('a vote for a proposal we never saw is ignored, not invented',
        () async {
      final service = await bobInFoursome();
      final unseen = proposalBy(carol, carolSecret, dave);

      await deliver(service, dave, voteBy(dave, daveSecret, unseen));

      expect(service.proposalsFor(sphereId), isEmpty);
    });

    test('two open votes about the same person are refused', () async {
      final service = await bobInFoursome();
      await service.proposeRemoval(sphereId, carol, 'first');

      expect(
        () => service.proposeRemoval(sphereId, carol, 'again'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('carrying out a vote', () {
    late String dave, daveSecret;

    setUp(() {
      final d = ed.generateKey();
      dave = idOf(d);
      daveSecret = secretOf(d);
    });

    List<SphereMember> foursome() => [
          member(alice, SphereRole.owner),
          member(bob, SphereRole.member),
          member(carol, SphereRole.member),
          member(dave, SphereRole.member),
        ];

    Future<SphereService> deviceFor(String who, String secret) async {
      final service = serviceFor(who, secret);
      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 1,
          op: MembershipOp.opCreate,
          target: '',
          author: alice,
          authorSecret: aliceSecret,
          members: foursome(),
        ),
      );
      await service.acceptInvite(sphereId);
      return service;
    }

    SignedStatement proposal() => statement(
          kind: SignedStatement.kindRemovalProposal,
          sphereId: sphereId,
          atEpoch: 1,
          subject: carol,
          by: bob,
          bySecret: bobSecret,
          detail: 'reason',
        );

    SignedStatement yesFrom(String who, String secret, SignedStatement on) =>
        statement(
          kind: SignedStatement.kindRemovalVote,
          sphereId: sphereId,
          atEpoch: 1,
          subject: carol,
          by: who,
          bySecret: secret,
          ref: on.id,
          detail: 'yes',
        );

    test('a removal carrying the votes is accepted from a non-admin', () async {
      // The point of the design: the executor may be any member, often the
      // only one online. Their authority is the proof, not their role.
      final service = await deviceFor(dave, daveSecret);
      final p = proposal();

      await service.handleIncomingOp(
        bob,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: bob,
          authorSecret: bobSecret,
          proof: [p, yesFrom(alice, aliceSecret, p), yesFrom(dave, daveSecret, p)],
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(dave, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(carol), isFalse);
    });

    test('a removal with no votes at all is refused', () async {
      final service = await deviceFor(dave, daveSecret);

      await service.handleIncomingOp(
        bob,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: bob,
          authorSecret: bobSecret,
          proof: [proposal()],
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(dave, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(carol), isTrue);
    });

    test('a removal with forged votes is refused', () async {
      final service = await deviceFor(dave, daveSecret);
      final p = proposal();
      final real = yesFrom(alice, aliceSecret, p);

      // Mallory's signature, wearing Alice's name.
      final forged = SignedStatement(
        kind: real.kind,
        sphereId: real.sphereId,
        atEpoch: real.atEpoch,
        subject: real.subject,
        by: alice,
        timestampMs: real.timestampMs,
        ref: real.ref,
        detail: 'yes',
        signatureHex: yesFrom(mallory, mallorySecret, p).signatureHex,
      );

      await service.handleIncomingOp(
        bob,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: bob,
          authorSecret: bobSecret,
          proof: [p, forged, yesFrom(dave, daveSecret, p)],
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(dave, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(carol), isTrue);
    });

    test('the subject cannot be counted as voting for their own removal',
        () async {
      final service = await deviceFor(dave, daveSecret);
      final p = proposal();

      await service.handleIncomingOp(
        bob,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: bob,
          authorSecret: bobSecret,
          // Carol's own "vote" padding the count towards quorum.
          proof: [p, yesFrom(carol, carolSecret, p)],
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(dave, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(carol), isTrue);
    });

    test('votes from a different proposal cannot be reused', () async {
      final service = await deviceFor(dave, daveSecret);
      final real = proposal();
      final other = statement(
        kind: SignedStatement.kindRemovalProposal,
        sphereId: sphereId,
        atEpoch: 1,
        subject: dave,
        by: bob,
        bySecret: bobSecret,
        detail: 'a different argument',
      );

      await service.handleIncomingOp(
        bob,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: bob,
          authorSecret: bobSecret,
          // Votes cast about Dave, presented as votes about Carol.
          proof: [
            real,
            yesFrom(alice, aliceSecret, other),
            yesFrom(dave, daveSecret, other),
          ],
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(dave, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(carol), isTrue);
    });

    test('an admin still removes unilaterally, no votes needed', () async {
      // Keeping this is deliberate: in a small sphere a vote is heavy. What
      // changed is that the action is now visible to everyone in the log.
      final service = await deviceFor(dave, daveSecret);

      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
            member(dave, SphereRole.member),
          ],
        ),
      );

      expect(service.sphere(sphereId)!.contains(carol), isFalse);
      expect(service.eventsFor(sphereId).first.op, MembershipOp.opRemove);
    });
  });

  // ── Audit log ─────────────────────────────────────────────────────────────

  group('the audit log', () {
    test('records what was done, newest first', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);
      await service.addMember(sphere.id, bob);
      await service.promote(sphere.id, bob);

      final events = service.eventsFor(sphere.id);
      expect(events.map((e) => e.op),
          [MembershipOp.opPromote, MembershipOp.opAdd, MembershipOp.opCreate]);
      expect(events.first.target, bob);
      expect(events.first.by, alice);
    });

    test('records what admins did to other people, not just to us', () async {
      // The point of the log: an admin action nobody can see is
      // indistinguishable from a server doing as it pleases.
      final service = await bobInAlicesSphere();

      await service.handleIncomingOp(
        alice,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: alice,
          authorSecret: aliceSecret,
          members: [
            member(alice, SphereRole.owner),
            member(bob, SphereRole.member),
          ],
        ),
      );

      final entry = service.eventsFor(sphereId).first;
      expect(entry.op, MembershipOp.opRemove);
      expect(entry.by, alice);
      expect(entry.target, carol);
    });

    test('a rename keeps the new name', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);
      await service.rename(sphere.id, name: 'Close family');

      expect(service.eventsFor(sphere.id).first.detail, 'Close family');
    });

    test('rejected operations are not recorded', () async {
      final service = await bobInAlicesSphere();
      final before = service.eventsFor(sphereId).length;

      await service.handleIncomingOp(
        mallory,
        signedOp(
          sphereId: sphereId,
          epoch: 2,
          op: MembershipOp.opRemove,
          target: carol,
          author: mallory,
          authorSecret: mallorySecret,
          members: [member(alice, SphereRole.owner), member(bob, SphereRole.member)],
        ),
      );

      expect(service.eventsFor(sphereId).length, before);
    });

    test('it survives a restart', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);
      await service.addMember(sphere.id, bob);

      final restarted = serviceFor(alice, aliceSecret);
      await restarted.load();

      expect(restarted.eventsFor(sphere.id).map((e) => e.op),
          [MembershipOp.opAdd, MembershipOp.opCreate]);
    });

    test('it is bounded, so a long-lived sphere cannot fill the disk',
        () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);

      for (var i = 0; i < SphereService.auditLimit + 10; i++) {
        await service.rename(sphere.id, name: 'Family $i');
      }

      expect(service.eventsFor(sphere.id).length, SphereService.auditLimit);
      // The oldest entries are the ones dropped.
      expect(service.eventsFor(sphere.id).last.op, MembershipOp.opRename);
    });

    test('leaving takes the log with it', () async {
      final service = serviceFor(alice, aliceSecret);
      final sphere = await service.create(name: 'Family', kind: SphereKind.group);
      await service.leave(sphere.id);

      expect(service.eventsFor(sphere.id), isEmpty);
    });

    test('an entry survives a JSON round trip', () {
      final entry = SphereEvent(
        sphereId: sphereId,
        op: MembershipOp.opRename,
        by: alice,
        target: '',
        epoch: 4,
        at: DateTime(2026, 7, 30, 9, 15),
        detail: 'Close family',
      );

      expect(SphereEvent.fromJson(entry.toJson()), entry);
    });

    test('it is stored encrypted', () async {
      final service = serviceFor(alice, aliceSecret);
      await service.create(name: 'Secret sphere', kind: SphereKind.group);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('spheres_sphere_audit_v1');
      expect(raw, isNotNull);
      expect(raw, isNot(contains('Secret sphere')));
    });
  });
}
