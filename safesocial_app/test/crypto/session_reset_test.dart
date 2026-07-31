import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:spheres_app/crypto/envelope.dart';
import 'package:spheres_app/crypto/pairwise_session.dart';
import 'package:spheres_app/crypto/spheres_crypto.dart';

/// Chains can only be advanced in lockstep, and until now nothing repaired
/// them if the two sides ever disagreed. Every later message failed to
/// authenticate, the conversation was over, and the only sign was that
/// messages quietly stopped arriving.
///
/// Restarting is the way back: the root comes from a static agreement, so it
/// survives whatever broke the chains, and both sides can re-derive from it.
void main() {
  late SimpleKeyPair aliceX, bobX;
  late List<int> alicePub, bobPub;
  late ed.KeyPair aliceEd, bobEd;
  late String aliceId, bobId, aliceSecret;

  setUp(() async {
    aliceX = await SpheresCrypto.newKeyExchangeKeyPair();
    bobX = await SpheresCrypto.newKeyExchangeKeyPair();
    alicePub = (await aliceX.extractPublicKey()).bytes;
    bobPub = (await bobX.extractPublicKey()).bytes;
    aliceEd = ed.generateKey();
    bobEd = ed.generateKey();
    aliceId = hex.encode(aliceEd.publicKey.bytes);
    bobId = hex.encode(bobEd.publicKey.bytes);
    aliceSecret = hex.encode(aliceEd.privateKey.bytes);
  });

  Future<PairwiseSession> alicesView() => PairwiseSession.establish(
        myKeyExchangeKeyPair: aliceX,
        peerKeyExchangePublicKey: bobPub,
        myIdentityKey: aliceId,
        peerIdentityKey: bobId,
      );

  Future<PairwiseSession> bobsView() => PairwiseSession.establish(
        myKeyExchangeKeyPair: bobX,
        peerKeyExchangePublicKey: alicePub,
        myIdentityKey: bobId,
        peerIdentityKey: aliceId,
      );

  /// Alice sends; returns what Bob decrypts, or throws as his device would.
  Future<String> deliver(
    PairwiseSession from,
    PairwiseSession to,
    String text,
  ) async {
    final envelope = await Envelope.sealChain(
      session: from,
      type: 'chat',
      plaintext: utf8.encode(text),
      myIdentitySecretHex: aliceSecret,
    );
    final decoded = Envelope.decode(envelope.encode());
    return utf8.decode(await decoded.open(to));
  }

  test('a healthy session carries messages', () async {
    final alice = await alicesView();
    final bob = await bobsView();

    expect(await deliver(alice, bob, 'hello'), 'hello');
  });

  test('a diverged session cannot be talked through', () async {
    // The starting condition: Alice's sending chain has moved and Bob's
    // receiving chain has not, in a way skipped keys cannot bridge.
    final alice = await alicesView();
    final bob = await bobsView();

    await bob.receiving.next(); // Bob is ahead; Alice's next is behind him.

    await expectLater(deliver(alice, bob, 'lost'), throwsA(anything));
  });

  test('restarting at the same epoch brings both sides back', () async {
    final alice = await alicesView();
    final bob = await bobsView();
    await bob.receiving.next();

    await alice.resetTo(1);
    await bob.resetTo(1);

    expect(await deliver(alice, bob, 'we are back'), 'we are back');
  });

  test('a restart produces different chains, not the old ones again', () async {
    // Otherwise an old ciphertext an attacker kept would become valid again.
    final alice = await alicesView();
    final before = (await alice.sending.next()).key;

    await alice.resetTo(1);
    final after = (await alice.sending.next()).key;

    expect(after, isNot(before));
  });

  test('each epoch gives its own chains', () async {
    final a1 = await alicesView();
    final a2 = await alicesView();

    await a1.resetTo(1);
    await a2.resetTo(2);

    expect((await a1.sending.next()).key, isNot((await a2.sending.next()).key));
  });

  test('only one side restarting leaves them still broken', () async {
    // The reason a restart has to be announced rather than done quietly.
    final alice = await alicesView();
    final bob = await bobsView();

    await alice.resetTo(1);

    await expectLater(deliver(alice, bob, 'unheard'), throwsA(anything));
  });

  test('a repeated request for the same epoch changes nothing', () async {
    // Both sides may ask at once, and an old request may be replayed. Neither
    // may throw the chains away a second time.
    final alice = await alicesView();
    expect(await alice.resetTo(1), isTrue);

    final key = (await alice.sending.next()).key;
    expect(await alice.resetTo(1), isFalse);

    // Still on the same chain: the next key follows the last, rather than
    // restarting from the seed.
    expect((await alice.sending.next()).key, isNot(key));
    expect(alice.sending.index, 2);
  });

  test('an older epoch cannot drag a session backwards', () async {
    final alice = await alicesView();
    await alice.resetTo(5);

    expect(await alice.resetTo(3), isFalse);
    expect(alice.resetEpoch, 5);
  });

  test('the epoch survives being written out and read back', () async {
    final alice = await alicesView();
    await alice.resetTo(4);

    final restored = PairwiseSession.fromJson(
        jsonDecode(jsonEncode(alice.toJson())) as Map<String, dynamic>);

    expect(restored.resetEpoch, 4);

    // And it is genuinely the same chain, not a fresh one at the same number.
    final independent = await alicesView();
    await independent.resetTo(4);
    expect((await restored.sending.next()).key,
        (await independent.sending.next()).key);
  });

  test('a session written before resets existed still reads', () async {
    final alice = await alicesView();
    final json = jsonDecode(jsonEncode(alice.toJson())) as Map<String, dynamic>;
    json.remove('resetEpoch');

    final restored = PairwiseSession.fromJson(json);

    expect(restored.resetEpoch, 0);
    final bob = await bobsView();
    expect(await deliver(restored, bob, 'still fine'), 'still fine');
  });

  test('the wrapping key is unaffected, so a restart can be announced',
      () async {
    // The announcement cannot travel on the chain it is trying to fix.
    final alice = await alicesView();
    final bob = await bobsView();
    final before = await alice.wrappingKey();

    await alice.resetTo(1);

    expect(await alice.wrappingKey(), before);
    expect(await bob.wrappingKey(), before);
  });

  test('the mailbox address is unaffected, so delivery still works', () async {
    final alice = await alicesView();
    final before = await alice.mailboxSecret();

    await alice.resetTo(2);

    expect(await alice.mailboxSecret(), before);
  });
}
