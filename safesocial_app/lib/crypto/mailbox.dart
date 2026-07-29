import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import 'spheres_crypto.dart';

/// A relay mailbox address and the key that proves the right to use it.
///
/// The address *is* an Ed25519 public key, so the relay verifies access by
/// checking a signature against the address itself. It stores no membership
/// list, learns no identity, and cannot be tricked by a throwaway keypair —
/// which is what let anyone read or delete any conversation's mail before.
class Mailbox {
  /// Base64url of the 32-byte Ed25519 public key. The relay path segment.
  final String id;

  final ed.PrivateKey _privateKey;

  Mailbox._(this.id, this._privateKey);

  /// Derive a mailbox from a secret both participants share.
  ///
  /// Because the address comes from a *secret*, the relay operator cannot
  /// compute it from public keys and therefore cannot map traffic onto the
  /// social graph. The previous scheme was
  /// `base36(SHA256(salt + sortedPublicKeys) & 0xFFFFFFFF)`: publicly
  /// precomputable, permanently stable, and only 32 bits wide.
  static Future<Mailbox> fromSharedSecret({
    required Uint8List secret,
    required String purpose,
  }) async {
    final seed = await SpheresCrypto.hkdf(
      secret: secret,
      info: 'spheres-mailbox-v1:$purpose',
    );
    return Mailbox._fromSeed(seed);
  }

  /// Derive the open inbox that belongs to an identity.
  ///
  /// Used only for contact handshakes, which by nature must be reachable by
  /// someone we have no shared secret with. Anyone who knows the identity key
  /// can compute this address and *write* to it; only the holder of the
  /// identity secret can read it, because reads are signed with the identity
  /// key itself.
  static String inboxIdFor(String identityPublicKeyHex) =>
      base64Url.encode(hex.decode(identityPublicKeyHex));

  /// Derive a mailbox from a value only this device knows.
  ///
  /// Used by groups and albums, which have no negotiated group key yet — their
  /// ids are locally generated UUIDs that never leave the device, so these
  /// channels are effectively single-device. That matches how they already
  /// behaved; a real per-sphere key arrives with the sphere model in Phase 3.
  static Future<Mailbox> fromLocalSecret({
    required String secret,
    required String purpose,
  }) async {
    final seed = await SpheresCrypto.hkdf(
      secret: utf8.encode(secret),
      info: 'spheres-mailbox-local-v1:$purpose',
    );
    return _fromSeed(seed);
  }

  static Mailbox _fromSeed(Uint8List seed) {
    final privateKey = ed.newKeyFromSeed(seed);
    final publicKey = ed.public(privateKey);
    return Mailbox._(base64Url.encode(publicKey.bytes), privateKey);
  }

  /// Sign a relay request. The relay verifies this against [id].
  ///
  /// The signed string covers the method, the full path, the body and a
  /// timestamp, so a captured signature cannot be replayed onto a different
  /// endpoint or a different body.
  String sign(String method, String path, String body, String timestamp) {
    final message = '$method$path$body$timestamp';
    return hex.encode(ed.sign(_privateKey, utf8.encode(message)));
  }
}
