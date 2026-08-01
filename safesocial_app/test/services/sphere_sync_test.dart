import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spheres_app/crypto/session_manager.dart';
import 'package:spheres_app/models/sphere.dart';
import 'package:spheres_app/services/secure_store.dart';
import 'package:spheres_app/services/sphere_service.dart';
import 'package:spheres_app/services/sphere_sync_service.dart';

/// Content used to reach you only from its author, and only while the relay
/// still had a copy. Miss that window — away too long, mailbox trimmed, joined
/// afterwards — and it was gone, even though everyone else in the sphere still
/// had it on their phone.
///
/// A member now keeps the sealed envelopes it receives and can hand them to a
/// peer who is missing them. Envelopes are kept exactly as they arrived: a
/// relaying peer cannot sign as their author, so the original signature has to
/// travel with the content, and the receiving side verifies it as usual.
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

  SphereService spheresFor(String identity, String secret) {
    final service = SphereService();
    service.configure(
      sessions: SessionManager(),
      identityKey: identity,
      identitySecret: secret,
      resolveExchangeKey: (k) => '${k.substring(0, 2)}${'0' * 62}',
      myExchangeKey: 'ff${'0' * 62}',
    );
    return service;
  }

  /// A device in a sphere with Bob and Carol, plus its archive.
  Future<(SphereService, SphereSyncService, Sphere, List<String>)>
      deviceFor() async {
    final spheres = spheresFor(alice, aliceSecret);
    final sphere = await spheres.create(
      name: 'Crew',
      kind: SphereKind.group,
      initialMembers: [bob, carol],
    );

    final asked = <String>[];
    final sync = SphereSyncService(spheres, random: Random(1))
      ..sendToPeer = (peer, payload) async {
        asked.add(peer);
        return true;
      };
    return (spheres, sync, sphere, asked);
  }

  Future<void> keep(
    SphereSyncService sync,
    String sphereId,
    String id, {
    DateTime? at,
  }) =>
      sync.remember(
        sphereId: sphereId,
        envelopeId: id,
        sealed: 'sealed-$id',
        at: at,
      );

  group('keeping envelopes', () {
    test('an envelope is remembered so it can be offered later', () async {
      final (_, sync, sphere, _) = await deviceFor();

      await keep(sync, sphere.id, 'e1');

      expect(sync.holds(sphere.id, 'e1'), isTrue);
      expect(sync.heldIn(sphere.id), 1);
    });

    test('the same envelope twice is kept once', () async {
      final (_, sync, sphere, _) = await deviceFor();

      await keep(sync, sphere.id, 'e1');
      await keep(sync, sphere.id, 'e1');

      expect(sync.heldIn(sphere.id), 1);
    });

    test('the archive survives a restart', () async {
      final (spheres, sync, sphere, _) = await deviceFor();
      await keep(sync, sphere.id, 'e1');

      final restored = SphereSyncService(spheres);
      await restored.load();

      expect(restored.holds(sphere.id, 'e1'), isTrue);
    });

    test('it is stored encrypted', () async {
      final (_, sync, sphere, _) = await deviceFor();
      await sync.remember(
          sphereId: sphere.id, envelopeId: 'e1', sealed: 'a-secret-envelope');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('spheres_archive_${sphere.id}');
      expect(raw, isNotNull);
      expect(raw, isNot(contains('a-secret-envelope')));
    });
  });

  group('pruning', () {
    test('drops anything past its retention', () async {
      // A sphere remembers for as long as its most patient member chooses.
      final (_, sync, sphere, _) = await deviceFor();
      sync.retention = const Duration(days: 7);
      await keep(sync, sphere.id, 'old',
          at: DateTime.now().subtract(const Duration(days: 9)));
      await keep(sync, sphere.id, 'new');

      await sync.prune();

      expect(sync.holds(sphere.id, 'old'), isFalse);
      expect(sync.holds(sphere.id, 'new'), isTrue);
    });

    test('drops everything for a sphere we left', () async {
      final (spheres, sync, sphere, _) = await deviceFor();
      await keep(sync, sphere.id, 'e1');

      await spheres.leave(sphere.id);
      await sync.prune();

      expect(sync.heldIn(sphere.id), 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('spheres_archive_${sphere.id}'), isNull);
    });
  });

  group('asking peers', () {
    test('asks a bounded number, not everyone', () async {
      // Gossip converges in a few rounds. Asking the whole sphere every time
      // would multiply traffic for nothing.
      final (_, sync, sphere, asked) = await deviceFor();
      await keep(sync, sphere.id, 'e1');

      await sync.syncSphere(sphere.id);

      expect(asked, hasLength(SphereSyncService.peersPerRound));
      expect(asked.toSet().length, asked.length, reason: 'no peer asked twice');
    });

    test('never asks itself', () async {
      final (_, sync, sphere, asked) = await deviceFor();

      await sync.syncSphere(sphere.id);

      expect(asked, isNot(contains(alice)));
    });

    test('a sphere with no reachable peers is skipped quietly', () async {
      final spheres = spheresFor(alice, aliceSecret);
      final sphere =
          await spheres.create(name: 'Alone', kind: SphereKind.group);
      final asked = <String>[];
      final sync = SphereSyncService(spheres)
        ..sendToPeer = (p, _) async {
          asked.add(p);
          return true;
        };

      await sync.syncSphere(sphere.id);

      expect(asked, isEmpty);
    });
  });

  group('answering a digest', () {
    test('sends back what the peer is missing', () async {
      final (spheres, sync, sphere, _) = await deviceFor();
      await keep(sync, sphere.id, 'e1');
      await keep(sync, sphere.id, 'e2');

      final sent = <String>[];
      sync.sendToPeer = (peer, payload) async {
        sent.add(payload);
        return true;
      };

      await sync.handleDigest(bob, sphere.id, {
        'type': 'sync_digest',
        'have': ['e1'],
      });

      expect(sent, hasLength(1));
      // The reply is itself sealed to the sphere, so what is being recovered
      // stays as private as the content it carries.
      final opened = await spheres.openContent(sent.single);
      final payload = jsonDecode(opened.plaintext) as Map<String, dynamic>;
      expect(payload['type'], 'sync_items');
      expect(payload['items'], ['sealed-e2']);
    });

    test('says nothing when the peer already has everything', () async {
      final (_, sync, sphere, _) = await deviceFor();
      await keep(sync, sphere.id, 'e1');

      final sent = <String>[];
      sync.sendToPeer = (peer, payload) async {
        sent.add(payload);
        return true;
      };

      await sync.handleDigest(bob, sphere.id, {
        'type': 'sync_digest',
        'have': ['e1'],
      });

      expect(sent, isEmpty);
    });

    test('a reply is bounded, and the rest waits for the next round', () async {
      // The relay refuses bodies over 256 KB, and a reply too large to deliver
      // helps nobody.
      final (spheres, sync, sphere, _) = await deviceFor();
      for (var i = 0; i < SphereSyncService.maxItemsPerReply + 10; i++) {
        await keep(sync, sphere.id, 'e$i');
      }

      final sent = <String>[];
      sync.sendToPeer = (peer, payload) async {
        sent.add(payload);
        return true;
      };

      await sync.handleDigest(
          bob, sphere.id, {'type': 'sync_digest', 'have': const []});

      final opened = await spheres.openContent(sent.single);
      final items = (jsonDecode(opened.plaintext)['items'] as List);
      expect(items, hasLength(SphereSyncService.maxItemsPerReply));
    });

    test('a digest for a sphere we are not in is ignored', () async {
      final (_, sync, _, _) = await deviceFor();
      final sent = <String>[];
      sync.sendToPeer = (peer, payload) async {
        sent.add(payload);
        return true;
      };

      await sync.handleDigest(
          bob, 'f' * 64, {'type': 'sync_digest', 'have': const []});

      expect(sent, isEmpty);
    });
  });

  group('applying what comes back', () {
    test('each item goes through the ordinary inbound path', () async {
      // Being handed something by a peer earns it no shortcut: it is verified
      // exactly as if it had arrived from its author.
      final (_, sync, sphere, _) = await deviceFor();
      final delivered = <String>[];
      sync.onRecovered = (from, sealed) async => delivered.add(sealed);

      await sync.handleItems(bob, sphere.id, {
        'type': 'sync_items',
        'items': ['sealed-a', 'sealed-b'],
      });

      expect(delivered, ['sealed-a', 'sealed-b']);
    });

    test('one bad item does not stop the rest', () async {
      final (_, sync, sphere, _) = await deviceFor();
      final delivered = <String>[];
      sync.onRecovered = (from, sealed) async {
        if (sealed == 'bad') throw const FormatException('nope');
        delivered.add(sealed);
      };

      await sync.handleItems(bob, sphere.id, {
        'type': 'sync_items',
        'items': ['sealed-a', 'bad', 'sealed-b'],
      });

      expect(delivered, ['sealed-a', 'sealed-b']);
    });

    test('a reply with nothing in it is harmless', () async {
      final (_, sync, sphere, _) = await deviceFor();
      sync.onRecovered = (from, sealed) async {};

      await sync.handleItems(
          bob, sphere.id, {'type': 'sync_items', 'items': const []});
    });
  });

  test('two members converge on the same set', () async {
    // The point of the whole thing: Alice has something Bob missed, Bob has
    // something Alice missed, and a round in each direction settles it.
    final (spheres, alices, sphere, _) = await deviceFor();
    final bobs = SphereSyncService(spheres);

    await keep(alices, sphere.id, 'shared');
    await keep(alices, sphere.id, 'only-alice');
    await keep(bobs, sphere.id, 'shared');
    await keep(bobs, sphere.id, 'only-bob');

    /// Runs one direction: [asker] tells [holder] what it has, and applies
    /// whatever comes back.
    Future<void> round(
        SphereSyncService asker, SphereSyncService holder) async {
      final replies = <String>[];
      holder.sendToPeer = (peer, payload) async {
        replies.add(payload);
        return true;
      };
      await holder.handleDigest(bob, sphere.id, {
        'type': 'sync_digest',
        'have': asker.idsIn(sphere.id),
      });

      for (final reply in replies) {
        final opened = await spheres.openContent(reply);
        final items = (jsonDecode(opened.plaintext)['items'] as List)
            .whereType<String>();
        for (final sealed in items) {
          // 'sealed-<id>' in this test; the real path reads the envelope.
          await asker.remember(
            sphereId: sphere.id,
            envelopeId: sealed.substring('sealed-'.length),
            sealed: sealed,
          );
        }
      }
    }

    await round(bobs, alices);
    await round(alices, bobs);

    expect(bobs.idsIn(sphere.id).toSet(), alices.idsIn(sphere.id).toSet());
    expect(bobs.idsIn(sphere.id).toSet(),
        {'shared', 'only-alice', 'only-bob'});
  });
}
