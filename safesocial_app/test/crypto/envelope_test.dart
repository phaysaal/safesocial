import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/envelope.dart';
import 'package:spheres_app/crypto/pairwise_session.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';

/// A test participant: an Ed25519 identity plus an X25519 exchange key.
class _Party {
  final String identityPublicHex;
  final String identitySecretHex;
  final SimpleKeyPair exchangeKeyPair;
  final List<int> exchangePublicBytes;

  _Party(this.identityPublicHex, this.identitySecretHex, this.exchangeKeyPair,
      this.exchangePublicBytes);

  static Future<_Party> create() async {
    final id = ed.generateKey();
    final kx = await SpheresCrypto.newKeyExchangeKeyPair();
    final kxPub = await kx.extractPublicKey();
    return _Party(
      hex.encode(id.publicKey.bytes),
      hex.encode(id.privateKey.bytes),
      kx,
      kxPub.bytes,
    );
  }
}

Future<PairwiseSession> _sessionFor(_Party me, _Party them) =>
    PairwiseSession.establish(
      myKeyExchangeKeyPair: me.exchangeKeyPair,
      peerKeyExchangePublicKey: them.exchangePublicBytes,
      myIdentityKey: me.identityPublicHex,
      peerIdentityKey: them.identityPublicHex,
    );

void main() {
  late _Party alice;
  late _Party bob;
  late PairwiseSession aliceSession;
  late PairwiseSession bobSession;

  setUp(() async {
    alice = await _Party.create();
    bob = await _Party.create();
    aliceSession = await _sessionFor(alice, bob);
    bobSession = await _sessionFor(bob, alice);
  });

  group('key agreement', () {
    test('both parties derive the same wrapping key', () async {
      expect(await aliceSession.wrappingKey(),
          equals(await bobSession.wrappingKey()));
    });

    test('a third party derives a different key', () async {
      final mallory = await _Party.create();
      final malloryWithAlice = await _sessionFor(mallory, alice);
      expect(await malloryWithAlice.wrappingKey(),
          isNot(equals(await aliceSession.wrappingKey())));
    });

    // The property the old CryptoService lacked: its "shared key" was
    // SHA256 of the two public keys, so anyone holding both public keys
    // could derive it. Knowing public keys alone must not be enough.
    test('public keys alone do not determine the key', () async {
      final impostor = await _Party.create();
      final forged = await PairwiseSession.establish(
        myKeyExchangeKeyPair: impostor.exchangeKeyPair,
        peerKeyExchangePublicKey: bob.exchangePublicBytes,
        // Impostor claims Alice's identity but lacks her exchange secret.
        myIdentityKey: alice.identityPublicHex,
        peerIdentityKey: bob.identityPublicHex,
      );
      expect(await forged.wrappingKey(),
          isNot(equals(await aliceSession.wrappingKey())));
    });
  });

  group('chain mode round trip', () {
    test('Bob decrypts what Alice sealed', () async {
      final envelope = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('meet me at the usual place'),
        myIdentitySecretHex: alice.identitySecretHex,
      );

      final opened = await Envelope.decode(envelope.encode()).open(bobSession);
      expect(utf8.decode(opened), 'meet me at the usual place');
    });

    test('survives a full JSON round trip', () async {
      final envelope = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('hello'),
        myIdentitySecretHex: alice.identitySecretHex,
      );
      final decoded = Envelope.decode(envelope.encode());

      expect(decoded.from, alice.identityPublicHex);
      expect(decoded.mode, SealMode.chain);
      expect(decoded.sequence, 0);
      expect(utf8.decode(await decoded.open(bobSession)), 'hello');
    });

    test('each message uses a different key', () async {
      final first = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('same text'),
        myIdentitySecretHex: alice.identitySecretHex,
      );
      final second = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('same text'),
        myIdentitySecretHex: alice.identitySecretHex,
      );

      // Identical plaintext must not produce identical ciphertext.
      expect(first.ciphertext, isNot(equals(second.ciphertext)));
      expect(first.sequence, 0);
      expect(second.sequence, 1);
    });

    test('out-of-order delivery still decrypts', () async {
      final messages = <Envelope>[];
      for (var i = 0; i < 5; i++) {
        messages.add(await Envelope.sealChain(
          session: aliceSession,
          type: 'chat',
          plaintext: utf8.encode('message $i'),
          myIdentitySecretHex: alice.identitySecretHex,
        ));
      }

      // The relay does not guarantee ordering; deliver 3, 0, 4, 1, 2.
      for (final i in [3, 0, 4, 1, 2]) {
        final opened = await messages[i].open(bobSession);
        expect(utf8.decode(opened), 'message $i');
      }
    });

    test('replaying a message fails', () async {
      final envelope = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('transfer approved'),
        myIdentitySecretHex: alice.identitySecretHex,
      );

      await envelope.open(bobSession);

      await expectLater(
        envelope.open(bobSession),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('a gap beyond the skip limit is refused', () async {
      // Burn far past the receiver's tolerance without delivering anything.
      for (var i = 0; i < KdfChain.maxSkip + 2; i++) {
        await aliceSession.sending.next();
      }
      final envelope = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('far future'),
        myIdentitySecretHex: alice.identitySecretHex,
      );

      await expectLater(envelope.open(bobSession), throwsA(isA<StateError>()));
    });
  });

  group('wrap mode round trip', () {
    test('Bob decrypts what Alice sealed', () async {
      final envelope = await Envelope.sealWrapped(
        session: aliceSession,
        type: 'post',
        plaintext: utf8.encode('a post for my sphere'),
        myIdentitySecretHex: alice.identitySecretHex,
      );

      final opened = await Envelope.decode(envelope.encode()).open(bobSession);
      expect(utf8.decode(opened), 'a post for my sphere');
    });

    test('re-sending the same content is safe and independent', () async {
      final first = await Envelope.sealWrapped(
        session: aliceSession,
        type: 'post',
        plaintext: utf8.encode('same post'),
        myIdentitySecretHex: alice.identitySecretHex,
      );
      final second = await Envelope.sealWrapped(
        session: aliceSession,
        type: 'post',
        plaintext: utf8.encode('same post'),
        myIdentitySecretHex: alice.identitySecretHex,
      );

      expect(first.ciphertext, isNot(equals(second.ciphertext)));
      expect(first.wrappedKey, isNot(equals(second.wrappedKey)));
      expect(utf8.decode(await first.open(bobSession)), 'same post');
      expect(utf8.decode(await second.open(bobSession)), 'same post');
    });
  });

  group('integrity', () {
    Future<Envelope> sealed() => Envelope.sealChain(
          session: aliceSession,
          type: 'chat',
          plaintext: utf8.encode('original'),
          myIdentitySecretHex: alice.identitySecretHex,
        );

    test('flipping a ciphertext bit is rejected', () async {
      final envelope = await sealed();
      final json = envelope.toJson();
      final ct = Uint8List.fromList(base64Decode(json['ct'] as String));
      ct[0] ^= 0x01;
      json['ct'] = base64Encode(ct);

      await expectLater(
        Envelope.fromJson(json).open(bobSession),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('changing the declared sender is rejected', () async {
      final envelope = await sealed();
      final json = envelope.toJson();
      json['from'] = bob.identityPublicHex;

      // Bob's session with Alice will not accept an envelope claiming Bob.
      await expectLater(
        Envelope.fromJson(json).open(bobSession),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('changing the payload type is rejected', () async {
      final envelope = await sealed();
      final json = envelope.toJson();
      json['type'] = 'call';

      await expectLater(
        Envelope.fromJson(json).open(bobSession),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('changing the timestamp is rejected', () async {
      final envelope = await sealed();
      final json = envelope.toJson();
      json['ts'] = (json['ts'] as int) + 1000;

      await expectLater(
        Envelope.fromJson(json).open(bobSession),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('an envelope signed by the wrong identity is rejected', () async {
      final mallory = await _Party.create();
      // Mallory has a session with Bob and signs with her own key, but claims
      // to be Alice.
      final malloryToBob = await _sessionFor(mallory, bob);
      final envelope = await Envelope.sealChain(
        session: malloryToBob,
        type: 'chat',
        plaintext: utf8.encode('you can trust me'),
        myIdentitySecretHex: mallory.identitySecretHex,
      );

      final json = envelope.toJson();
      json['from'] = alice.identityPublicHex;

      await expectLater(
        Envelope.fromJson(json).open(bobSession),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('an envelope for a different peer is refused', () async {
      final carol = await _Party.create();
      final aliceToCarol = await _sessionFor(alice, carol);
      final envelope = await Envelope.sealChain(
        session: aliceToCarol,
        type: 'chat',
        plaintext: utf8.encode('for carol only'),
        myIdentitySecretHex: alice.identitySecretHex,
      );

      final carolWithBob = await _sessionFor(carol, bob);
      await expectLater(
        envelope.open(carolWithBob),
        throwsA(isA<EnvelopeException>()),
      );
    });
  });

  group('decoding', () {
    test('rejects malformed JSON', () {
      expect(() => Envelope.decode('{not json'),
          throwsA(isA<EnvelopeException>()));
    });

    test('rejects an unknown version', () async {
      final envelope = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('hi'),
        myIdentitySecretHex: alice.identitySecretHex,
      );
      final json = envelope.toJson()..['v'] = 99;
      expect(() => Envelope.fromJson(json), throwsA(isA<EnvelopeException>()));
    });

    test('rejects an unknown seal mode', () async {
      final envelope = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('hi'),
        myIdentitySecretHex: alice.identitySecretHex,
      );
      final json = envelope.toJson()..['mode'] = 'plaintext';
      expect(() => Envelope.fromJson(json), throwsA(isA<EnvelopeException>()));
    });

    test('rejects a missing field', () async {
      final envelope = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('hi'),
        myIdentitySecretHex: alice.identitySecretHex,
      );
      final json = envelope.toJson()..remove('sig');
      expect(() => Envelope.fromJson(json), throwsA(isA<EnvelopeException>()));
    });
  });

  group('session persistence', () {
    test('a restored session continues the conversation', () async {
      final first = await Envelope.sealChain(
        session: aliceSession,
        type: 'chat',
        plaintext: utf8.encode('before restart'),
        myIdentitySecretHex: alice.identitySecretHex,
      );
      expect(utf8.decode(await first.open(bobSession)), 'before restart');

      // Simulate both devices restarting.
      final aliceRestored =
          PairwiseSession.fromJson(jsonDecode(jsonEncode(aliceSession.toJson())));
      final bobRestored =
          PairwiseSession.fromJson(jsonDecode(jsonEncode(bobSession.toJson())));

      final second = await Envelope.sealChain(
        session: aliceRestored,
        type: 'chat',
        plaintext: utf8.encode('after restart'),
        myIdentitySecretHex: alice.identitySecretHex,
      );
      expect(utf8.decode(await second.open(bobRestored)), 'after restart');
      expect(second.sequence, 1);
    });
  });
}
