import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// DEPRECATED placeholder cipher. Do not use for new code.
///
/// [encrypt]/[decrypt] are XOR against a repeating key, and [deriveSharedKey]
/// returns SHA-256 of the two *public* keys — derivable by anyone who knows
/// both, including the relay operator. This is not encryption.
///
/// Real cryptography lives in `lib/crypto/`: use `SessionManager.seal` and
/// `SessionManager.open`, which give authenticated encryption with X25519 key
/// agreement and per-message ratcheted keys.
///
/// Chat has been migrated. Still on this placeholder, tracked as the remainder
/// of Phase 1 in `docs/rebuild_plan.md`:
///   * `group_service` — needs a per-sphere key, which arrives with the sphere
///     model in Phase 3
///   * `call_service` — signalling payloads
///   * `feed_service`/`album_service` — currently send plaintext, so they need
///     sealing rather than migrating
///
/// The room-id derivation that used to live here is gone: relay addressing is
/// now secret-derived (`lib/crypto/mailbox.dart`), so the operator can no
/// longer precompute who is talking to whom.
@Deprecated('Use SessionManager (lib/crypto/) — this is a placeholder cipher')
class CryptoService {
  /// Encrypt a plaintext message with a shared key.
  /// Returns base64-encoded ciphertext with embedded nonce.
  static String encrypt(String plaintext, String sharedKey) {
    final keyBytes = utf8.encode(sharedKey);
    final plainBytes = utf8.encode(plaintext);

    // Generate 16-byte random nonce
    final random = Random.secure();
    final nonce = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      nonce[i] = random.nextInt(256);
    }

    // XOR encrypt with key + nonce
    final encrypted = Uint8List(plainBytes.length);
    for (var i = 0; i < plainBytes.length; i++) {
      encrypted[i] = plainBytes[i] ^
          keyBytes[i % keyBytes.length] ^
          nonce[i % nonce.length];
    }

    // Prepend nonce to ciphertext
    final result = Uint8List(16 + encrypted.length);
    result.setRange(0, 16, nonce);
    result.setRange(16, result.length, encrypted);

    return base64Encode(result);
  }

  /// Decrypt a base64-encoded ciphertext with a shared key.
  static String decrypt(String ciphertext, String sharedKey) {
    final keyBytes = utf8.encode(sharedKey);
    final allBytes = base64Decode(ciphertext);

    // Extract nonce (first 16 bytes)
    final nonce = allBytes.sublist(0, 16);
    final encrypted = allBytes.sublist(16);

    // XOR decrypt
    final decrypted = Uint8List(encrypted.length);
    for (var i = 0; i < encrypted.length; i++) {
      decrypted[i] = encrypted[i] ^
          keyBytes[i % keyBytes.length] ^
          nonce[i % nonce.length];
    }

    return utf8.decode(decrypted);
  }

  /// Derive a shared key from two public keys (deterministic).
  /// Both parties compute the same key regardless of order.
  static String deriveSharedKey(String keyA, String keyB) {
    final sorted = [keyA, keyB]..sort();
    final combined = '${sorted[0]}:${sorted[1]}';
    // Use a hash to make it non-obvious
    return sha256.convert(utf8.encode(combined)).toString();
  }

}
