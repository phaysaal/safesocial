import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Cryptographic primitives for Spheres.
///
/// This is the only place in the app that talks to a cipher directly. It
/// implements the primitive set specified in `docs/privacy_protocol.md`:
/// X25519 for key agreement, HKDF-SHA256 for derivation, and
/// XChaCha20-Poly1305 for authenticated encryption.
///
/// It replaces `crypto_service.dart`, which XOR'd plaintext against a key
/// derived from the two parties' *public* keys — reversible by anyone who knew
/// both public keys, including the relay operator.
///
/// Domain separation: every derivation passes a distinct `info` string so that
/// keys for different purposes can never collide. Do not reuse an info string
/// for a new purpose; add one.
class SpheresCrypto {
  const SpheresCrypto._();

  static final X25519 _x25519 = X25519();
  static final Cipher _aead = Xchacha20.poly1305Aead();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final Random _random = Random.secure();

  /// XChaCha20 nonce length, in bytes.
  static const int nonceLength = 24;

  /// Symmetric key length, in bytes.
  static const int keyLength = 32;

  /// Poly1305 tag length, in bytes.
  static const int macLength = 16;

  // ── Random ────────────────────────────────────────────────────────────────

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  static Uint8List randomKey() => randomBytes(keyLength);

  static Uint8List randomNonce() => randomBytes(nonceLength);

  // ── X25519 key agreement ──────────────────────────────────────────────────

  /// Generate a fresh X25519 key pair.
  static Future<SimpleKeyPair> newKeyExchangeKeyPair() => _x25519.newKeyPair();

  /// Rebuild an X25519 key pair from its stored 32-byte private key.
  static Future<SimpleKeyPair> keyExchangeKeyPairFromPrivateBytes(
    List<int> privateKeyBytes,
  ) {
    if (privateKeyBytes.length != keyLength) {
      throw ArgumentError('X25519 private key must be $keyLength bytes');
    }
    return _x25519.newKeyPairFromSeed(privateKeyBytes);
  }

  /// Compute the raw X25519 shared secret between us and a peer.
  ///
  /// The result is never used as a key directly — always run it through
  /// [hkdf] first, which is what binds it to a purpose.
  static Future<Uint8List> sharedSecret({
    required SimpleKeyPair myKeyPair,
    required List<int> peerPublicKeyBytes,
  }) async {
    if (peerPublicKeyBytes.length != keyLength) {
      throw ArgumentError('X25519 public key must be $keyLength bytes');
    }
    final secret = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(
        peerPublicKeyBytes,
        type: KeyPairType.x25519,
      ),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  // ── Key derivation ────────────────────────────────────────────────────────

  /// HKDF-SHA256. [salt] and [info] provide domain separation.
  static Future<Uint8List> hkdf({
    required List<int> secret,
    required String info,
    List<int> salt = const <int>[],
  }) async {
    final derived = await _hkdf.deriveKey(
      secretKey: SecretKey(secret),
      nonce: salt,
      info: info.codeUnits,
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  // ── Authenticated encryption ──────────────────────────────────────────────

  /// Encrypt [plaintext] under [key], binding [aad] to the ciphertext.
  ///
  /// Returns `ciphertext || mac`. The nonce is not included — callers carry it
  /// in the envelope header, which is itself covered by [aad].
  static Future<Uint8List> encrypt({
    required List<int> key,
    required List<int> nonce,
    required List<int> plaintext,
    required List<int> aad,
  }) async {
    _requireKey(key);
    _requireNonce(nonce);

    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );

    final out = Uint8List(box.cipherText.length + macLength);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Decrypt `ciphertext || mac` produced by [encrypt].
  ///
  /// Throws if the tag does not verify — which is the case for any tampering
  /// with the ciphertext, the nonce, or the associated data. Callers must let
  /// this propagate rather than falling back to unauthenticated handling.
  static Future<Uint8List> decrypt({
    required List<int> key,
    required List<int> nonce,
    required List<int> ciphertextWithMac,
    required List<int> aad,
  }) async {
    _requireKey(key);
    _requireNonce(nonce);
    if (ciphertextWithMac.length < macLength) {
      throw ArgumentError('Ciphertext is too short to contain a MAC');
    }

    final split = ciphertextWithMac.length - macLength;
    final box = SecretBox(
      ciphertextWithMac.sublist(0, split),
      nonce: nonce,
      mac: Mac(ciphertextWithMac.sublist(split)),
    );

    final clear = await _aead.decrypt(box, secretKey: SecretKey(key), aad: aad);
    return Uint8List.fromList(clear);
  }

  static void _requireKey(List<int> key) {
    if (key.length != keyLength) {
      throw ArgumentError('Key must be $keyLength bytes, got ${key.length}');
    }
  }

  static void _requireNonce(List<int> nonce) {
    if (nonce.length != nonceLength) {
      throw ArgumentError(
        'Nonce must be $nonceLength bytes, got ${nonce.length}',
      );
    }
  }
}
