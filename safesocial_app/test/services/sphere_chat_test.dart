import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/message.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_chat_service.dart';
import 'package:spheres_app/services/sphere_service.dart';

/// Group chat is addressed to a sphere rather than to a person, so the sphere
/// id stands where a recipient normally would. Everything that makes it safe
/// is enforced a layer down — the envelope proves the author and the sphere
/// layer checks they are a member — so what is worth testing here is what this
/// service adds: that it refuses payloads disagreeing with their envelope,
/// respects who may post, and does not lose or duplicate messages.
void main() {
  late String alice, aliceSecret, bob, carol;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await SecureStore.instance.init();

    final a = ed.generateKey();
    alice = hex.encode(a.publicKey.bytes);
    aliceSecret = hex.encode(a.privateKey.bytes);
    bob = hex.encode(ed.generateKey().publicKey.bytes);
    carol = hex.encode(ed.generateKey().publicKey.bytes);
  });

  SphereService sphereServiceFor(String identity, String secret) {
    final service = SphereService();
    service.configure(
      sessions: SessionManager(),
      identityKey: identity,
      identitySecret: secret,
      resolveExchangeKey: (_) => null,
    );
    return service;
  }

  /// Alice's device, owning a sphere with Bob and Carol in it.
  Future<(SphereChatService, Sphere, List<String>)> alicesChat({
    SphereKind kind = SphereKind.group,
  }) async {
    final spheres = sphereServiceFor(alice, aliceSecret);
    final sphere = await spheres.create(
      name: 'Trips',
      kind: kind,
      initialMembers: [bob, carol],
    );

    final sent = <String>[];
    final chat = SphereChatService(spheres)
      ..configure(identityKey: alice)
      ..sendToPeer = (peer, payload) async {
        sent.add(peer);
        return true;
      };
    return (chat, sphere, sent);
  }

  Map<String, dynamic> wirePayload(Message message) =>
      jsonDecode(jsonEncode({'type': 'sphere_msg', 'message': message.toJson()}))
          as Map<String, dynamic>;

  Message messageFrom(String sender, String sphereId, {String id = 'm1'}) =>
      Message(
        id: id,
        senderId: sender,
        recipientId: sphereId,
        content: 'hello everyone',
        timestamp: DateTime(2026, 7, 31, 12),
      );

  group('sending', () {
    test('a message is stored and goes to every other member', () async {
      final (chat, sphere, sent) = await alicesChat();

      await chat.sendMessage(sphere.id, 'hello everyone');

      expect(chat.messagesIn(sphere.id).single.content, 'hello everyone');
      // Everyone but us. Sealing once and fanning out is the same shape as a
      // feed post, because it is the same problem.
      expect(sent.toSet(), {bob, carol});
    });

    test('the sphere is the recipient', () async {
      final (chat, sphere, _) = await alicesChat();

      await chat.sendMessage(sphere.id, 'hello');

      expect(chat.messagesIn(sphere.id).single.recipientId, sphere.id);
    });

    test('sending to a sphere we are not in is refused', () async {
      final (chat, _, _) = await alicesChat();

      expect(() => chat.sendMessage('n' * 64, 'hello'),
          throwsA(isA<StateError>()));
    });

    test('a member cannot post in a broadcast sphere', () async {
      final spheres = sphereServiceFor(bob, aliceSecret);
      final chat = SphereChatService(spheres)..configure(identityKey: bob);
      // Bob's device holding a broadcast sphere he does not administer.
      await spheres.handleIncomingOp(
        alice,
        jsonEncode({
          'op': MembershipOp(
            sphereId: 'b' * 64,
            epoch: 1,
            op: MembershipOp.opCreate,
            target: '',
            by: alice,
            timestampMs: DateTime(2026).millisecondsSinceEpoch,
            members: [
              SphereMember(
                  identityKey: alice,
                  role: SphereRole.owner,
                  joinedAt: DateTime(2026),
                  invitedBy: alice),
              SphereMember(
                  identityKey: bob,
                  role: SphereRole.member,
                  joinedAt: DateTime(2026),
                  invitedBy: alice),
            ],
            name: 'Announcements',
            kind: SphereKind.broadcast,
          ).toJson(),
          'signature': hex.encode(ed.sign(
            ed.PrivateKey(hex.decode(aliceSecret)),
            MembershipOp(
              sphereId: 'b' * 64,
              epoch: 1,
              op: MembershipOp.opCreate,
              target: '',
              by: alice,
              timestampMs: DateTime(2026).millisecondsSinceEpoch,
              members: [
                SphereMember(
                    identityKey: alice,
                    role: SphereRole.owner,
                    joinedAt: DateTime(2026),
                    invitedBy: alice),
                SphereMember(
                    identityKey: bob,
                    role: SphereRole.member,
                    joinedAt: DateTime(2026),
                    invitedBy: alice),
              ],
              name: 'Announcements',
              kind: SphereKind.broadcast,
            ).signedBytes(),
          )),
        }),
      );
      await spheres.acceptInvite('b' * 64);

      expect(() => chat.sendMessage('b' * 64, 'let me in'),
          throwsA(isA<StateError>()));
    });

    test('a blocked member is skipped', () async {
      final (chat, sphere, sent) = await alicesChat();
      chat.blockedKeys = () => {carol};

      await chat.sendMessage(sphere.id, 'hello');

      expect(sent, [bob]);
    });
  });

  group('receiving', () {
    test('a message from a member is kept', () async {
      final (chat, sphere, _) = await alicesChat();

      await chat.handleIncoming(
          bob, sphere.id, wirePayload(messageFrom(bob, sphere.id)));

      expect(chat.messagesIn(sphere.id).single.senderId, bob);
    });

    test('a payload claiming a different author is dropped', () async {
      // The envelope proves who sent it; the payload does not get to disagree.
      final (chat, sphere, _) = await alicesChat();

      await chat.handleIncoming(
          bob, sphere.id, wirePayload(messageFrom(carol, sphere.id)));

      expect(chat.messagesIn(sphere.id), isEmpty);
    });

    test('a payload claiming a different sphere is dropped', () async {
      final (chat, sphere, _) = await alicesChat();

      await chat.handleIncoming(
          bob, sphere.id, wirePayload(messageFrom(bob, 'z' * 64)));

      expect(chat.messagesIn(sphere.id), isEmpty);
    });

    test('the same message twice is only kept once', () async {
      // The relay can deliver twice, live and again from the mailbox.
      final (chat, sphere, _) = await alicesChat();
      final payload = wirePayload(messageFrom(bob, sphere.id));

      await chat.handleIncoming(bob, sphere.id, payload);
      await chat.handleIncoming(bob, sphere.id, payload);

      expect(chat.messagesIn(sphere.id), hasLength(1));
    });

    test('out-of-order arrivals are shown in time order', () async {
      final (chat, sphere, _) = await alicesChat();
      final later = Message(
        id: 'm2',
        senderId: bob,
        recipientId: sphere.id,
        content: 'second',
        timestamp: DateTime(2026, 7, 31, 13),
      );

      await chat.handleIncoming(bob, sphere.id, wirePayload(later));
      await chat.handleIncoming(
          bob, sphere.id, wirePayload(messageFrom(bob, sphere.id)));

      expect(chat.messagesIn(sphere.id).map((m) => m.content),
          ['hello everyone', 'second']);
    });

    test('a message for a sphere we do not have is ignored', () async {
      final (chat, _, _) = await alicesChat();

      await chat.handleIncoming(
          bob, 'q' * 64, wirePayload(messageFrom(bob, 'q' * 64)));

      expect(chat.messagesIn('q' * 64), isEmpty);
    });
  });

  group('unread', () {
    test('messages count as unread while the thread is closed', () async {
      final (chat, sphere, _) = await alicesChat();

      await chat.handleIncoming(
          bob, sphere.id, wirePayload(messageFrom(bob, sphere.id)));

      expect(chat.unreadIn(sphere.id), 1);
    });

    test('nothing is unread while the thread is on screen', () async {
      final (chat, sphere, _) = await alicesChat();
      chat.setOpenThread(sphere.id);

      await chat.handleIncoming(
          bob, sphere.id, wirePayload(messageFrom(bob, sphere.id)));

      expect(chat.unreadIn(sphere.id), 0);
    });

    test('opening a thread clears its unread count', () async {
      final (chat, sphere, _) = await alicesChat();
      await chat.handleIncoming(
          bob, sphere.id, wirePayload(messageFrom(bob, sphere.id)));

      chat.setOpenThread(sphere.id);

      expect(chat.unreadIn(sphere.id), 0);
    });
  });

  group('storage', () {
    test('messages survive a restart', () async {
      final spheres = sphereServiceFor(alice, aliceSecret);
      final sphere = await spheres.create(
          name: 'Trips', kind: SphereKind.group, initialMembers: [bob]);
      final chat = SphereChatService(spheres)..configure(identityKey: alice);
      await chat.sendMessage(sphere.id, 'remember this');

      final restarted = SphereChatService(spheres);
      await restarted.load();

      expect(restarted.messagesIn(sphere.id).single.content, 'remember this');
    });

    test('they are stored encrypted', () async {
      final (chat, sphere, _) = await alicesChat();
      await chat.sendMessage(sphere.id, 'a private arrangement');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('spheres_sphere_msgs_${sphere.id}');
      expect(raw, isNotNull);
      expect(raw, isNot(contains('a private arrangement')));
    });

    test('leaving a sphere takes its messages with it', () async {
      // The keys are gone, so the thread would be unreadable anyway. Leaving
      // it on disk would only be litter that outlives the sphere.
      final spheres = sphereServiceFor(alice, aliceSecret);
      final sphere = await spheres.create(
          name: 'Trips', kind: SphereKind.group, initialMembers: [bob]);
      final chat = SphereChatService(spheres)..configure(identityKey: alice);
      await chat.sendMessage(sphere.id, 'bye');

      await spheres.leave(sphere.id);
      await chat.pruneDepartedSpheres();

      expect(chat.messagesIn(sphere.id), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('spheres_sphere_msgs_${sphere.id}'), isNull);
    });

    test('a thread is capped so one sphere cannot fill the disk', () async {
      final (chat, sphere, _) = await alicesChat();

      for (var i = 0; i < SphereChatService.maxMessagesPerSphere + 5; i++) {
        await chat.handleIncoming(
            bob,
            sphere.id,
            wirePayload(Message(
              id: 'm$i',
              senderId: bob,
              recipientId: sphere.id,
              content: 'message $i',
              timestamp: DateTime(2026, 7, 31).add(Duration(minutes: i)),
            )));
      }

      expect(chat.messagesIn(sphere.id),
          hasLength(SphereChatService.maxMessagesPerSphere));
      // The oldest go first.
      expect(chat.messagesIn(sphere.id).first.content, 'message 5');
    });
  });

  test('threads are listed most recently active first', () async {
    final spheres = sphereServiceFor(alice, aliceSecret);
    final quiet = await spheres.create(
        name: 'Quiet', kind: SphereKind.group, initialMembers: [bob]);
    final busy = await spheres.create(
        name: 'Busy', kind: SphereKind.group, initialMembers: [bob]);
    final chat = SphereChatService(spheres)..configure(identityKey: alice);

    await chat.sendMessage(quiet.id, 'first');
    await chat.sendMessage(busy.id, 'second');

    expect(chat.activeThreads, [busy.id, quiet.id]);
  });
}
