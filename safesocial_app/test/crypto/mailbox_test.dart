import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/mailbox.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';

/// The relay's blindness rests entirely on these properties:
/// an address is unguessable without the shared secret, and using it requires
/// a signature the relay checks against the address itself.
void main() {
  final secretA = Uint8List.fromList(List.generate(32, (i) => i));
  final secretB = Uint8List.fromList(List.generate(32, (i) => 255 - i));

  test('both participants derive the same address from the shared secret', () async {
    final mine = await Mailbox.fromSharedSecret(secret: secretA, purpose: 'chat');
    final theirs = await Mailbox.fromSharedSecret(secret: secretA, purpose: 'chat');

    expect(mine.id, theirs.id);
  });

  test('a different secret gives a different address', () async {
    final a = await Mailbox.fromSharedSecret(secret: secretA, purpose: 'chat');
    final b = await Mailbox.fromSharedSecret(secret: secretB, purpose: 'chat');

    expect(a.id, isNot(b.id));
  });

  test('purposes are unlinkable to each other', () async {
    // Chat, feed and call between the same pair must not share an address, or
    // the operator could group them and infer a relationship.
    final chat = await Mailbox.fromSharedSecret(secret: secretA, purpose: 'chat');
    final feed = await Mailbox.fromSharedSecret(secret: secretA, purpose: 'feed');
    final call = await Mailbox.fromSharedSecret(secret: secretA, purpose: 'call');

    expect({chat.id, feed.id, call.id}.length, 3);
  });

  test('the address is a full 32-byte key, not a truncated hash', () async {
    final mailbox =
        await Mailbox.fromSharedSecret(secret: secretA, purpose: 'chat');

    // v1 folded SHA-256 down to 32 bits and rendered base36, which was
    // enumerable. Anything derived here must be a real Ed25519 public key.
    expect(base64Url.decode(mailbox.id).length, 32);
  });

  test('a signature verifies against the address itself', () async {
    final mailbox =
        await Mailbox.fromSharedSecret(secret: secretA, purpose: 'chat');

    const method = 'GET';
    const path = '/mbx/whatever/sync';
    const body = '';
    const timestamp = '1750000000000';
    final signature = mailbox.sign(method, path, body, timestamp);

    // This is exactly what the worker does: parse the address as a public key
    // and verify. No stored membership list is involved.
    final verified = ed.verify(
      ed.PublicKey(base64Url.decode(mailbox.id)),
      utf8.encode('$method$path$body$timestamp'),
      Uint8List.fromList(hex.decode(signature)),
    );

    expect(verified, isTrue);
  });

  test('a signature from a different mailbox does not verify', () async {
    final mine = await Mailbox.fromSharedSecret(secret: secretA, purpose: 'chat');
    final other = await Mailbox.fromSharedSecret(secret: secretB, purpose: 'chat');

    const message = 'GET/mbx/x/sync1750000000000';
    final foreign = other.sign('GET', '/mbx/x/sync', '', '1750000000000');

    // The core v1 hole: any valid Ed25519 signature was accepted, without
    // checking it against the room being accessed.
    final verified = ed.verify(
      ed.PublicKey(base64Url.decode(mine.id)),
      utf8.encode(message),
      Uint8List.fromList(hex.decode(foreign)),
    );

    expect(verified, isFalse);
  });

  test('a signature is bound to its method, path, body and timestamp', () async {
    final mailbox =
        await Mailbox.fromSharedSecret(secret: secretA, purpose: 'chat');
    final signature = mailbox.sign('GET', '/mbx/x/sync', '', '1750000000000');
    final key = ed.PublicKey(base64Url.decode(mailbox.id));
    final sigBytes = Uint8List.fromList(hex.decode(signature));

    // Replaying the same signature onto a destructive endpoint must fail.
    expect(
      ed.verify(key, utf8.encode('POST/mbx/x/ack1750000000000'), sigBytes),
      isFalse,
    );
    // Or onto a different mailbox.
    expect(
      ed.verify(key, utf8.encode('GET/mbx/y/sync1750000000000'), sigBytes),
      isFalse,
    );
    // Or at a different time.
    expect(
      ed.verify(key, utf8.encode('GET/mbx/x/sync1750000009999'), sigBytes),
      isFalse,
    );
  });

  test('the inbox address is the identity key, so senders can find it', () {
    final key = ed.generateKey();
    final identityHex = hex.encode(key.publicKey.bytes);

    final inboxId = Mailbox.inboxIdFor(identityHex);

    expect(base64Url.decode(inboxId), key.publicKey.bytes);
  });

  test('local-secret mailboxes are deterministic and purpose-separated', () async {
    final group = await Mailbox.fromLocalSecret(secret: 'uuid-1', purpose: 'group');
    final same = await Mailbox.fromLocalSecret(secret: 'uuid-1', purpose: 'group');
    final album = await Mailbox.fromLocalSecret(secret: 'uuid-1', purpose: 'album');
    final other = await Mailbox.fromLocalSecret(secret: 'uuid-2', purpose: 'group');

    expect(group.id, same.id);
    expect(group.id, isNot(album.id));
    expect(group.id, isNot(other.id));
  });

  test('a shared-secret address is not derivable from public data', () async {
    // The v1 room id was SHA256 over a hardcoded salt and the two public keys,
    // so the operator could precompute every pair. Here the input is a secret,
    // so an attacker with only public material derives something unrelated.
    final realSecret = await SpheresCrypto.hkdf(
      secret: secretA,
      info: 'spheres-mailbox-root-v1',
    );
    final guessFromPublicData = await SpheresCrypto.hkdf(
      secret: utf8.encode('alice-public-key:bob-public-key'),
      info: 'spheres-mailbox-root-v1',
    );

    final real = await Mailbox.fromSharedSecret(secret: realSecret, purpose: 'chat');
    final guess =
        await Mailbox.fromSharedSecret(secret: guessFromPublicData, purpose: 'chat');

    expect(real.id, isNot(guess.id));
  });
}
