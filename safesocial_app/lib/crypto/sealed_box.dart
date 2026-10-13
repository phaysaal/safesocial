import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';

import 'spheres_crypto.dart';

/// A small secret sealed to one person's X25519 exchange key, with nothing
/// shared beforehand: an ephemeral key pair, a shared secret, HKDF and
/// XChaCha20-Poly1305. The box is `ephemeral public key || nonce ||
/// ciphertext+mac`, base64. Only the holder of the exchange private key can
/// open it, which is how a media key reaches the people tagged in a picture
/// and nobody else in the sphere.
class SealedBox {
  static const _info = 'spheres-sealed-box-v1';

  static Future<String> seal({
    required String peerExchangeKeyHex,
    required List<int> plaintext,
  }) async {
    final peer = hex.decode(peerExchangeKeyHex);
    final ephemeral = await SpheresCrypto.newKeyExchangeKeyPair();
    final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
    final shared = await SpheresCrypto.sharedSecret(
        myKeyPair: ephemeral, peerPublicKeyBytes: peer);
    final key = await SpheresCrypto.hkdf(secret: shared, info: _info, salt: ephemeralPublic);
    final nonce = SpheresCrypto.randomNonce();
    final sealed = await SpheresCrypto.encrypt(
        key: key, nonce: nonce, plaintext: plaintext, aad: ephemeralPublic);
    return base64Encode([...ephemeralPublic, ...nonce, ...sealed]);
  }

  /// Null when the box is not for [myKeyPair] or has been tampered with.
  static Future<Uint8List?> open({
    required SimpleKeyPair myKeyPair,
    required String box,
  }) async {
    try {
      final bytes = base64Decode(box);
      const pk = SpheresCrypto.keyLength;
      const nl = SpheresCrypto.nonceLength;
      if (bytes.length < pk + nl + SpheresCrypto.macLength) return null;
      final ephemeralPublic = bytes.sublist(0, pk);
      final nonce = bytes.sublist(pk, pk + nl);
      final sealed = bytes.sublist(pk + nl);
      final shared = await SpheresCrypto.sharedSecret(
          myKeyPair: myKeyPair, peerPublicKeyBytes: ephemeralPublic);
      final key = await SpheresCrypto.hkdf(secret: shared, info: _info, salt: ephemeralPublic);
      return await SpheresCrypto.decrypt(
          key: key, nonce: nonce, ciphertextWithMac: sealed, aad: ephemeralPublic);
    } catch (_) {
      return null;
    }
  }
}
