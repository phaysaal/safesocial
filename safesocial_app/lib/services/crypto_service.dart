import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Simple content encryption service.
///
/// Placeholder implementation using XOR + random nonce.
/// When Veilid is fully active, this will be replaced with
/// XChaCha20-Poly1305 from the Veilid crypto system.
class CryptoService {
  static const _roomSalt = 'spheres-relay-v2-salt-secret-';

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

  /// Derive a deterministic room ID from two public keys.
  /// Uses a secret salt to prevent pre-calculation by observers.
  static String deriveRelayRoomId(String keyA, String keyB) {
    final sorted = [keyA, keyB]..sort();
    final combined = '$_roomSalt${sorted[0]}:${sorted[1]}';
    
    // Use SHA256 for the room ID
    final digest = sha256.convert(utf8.encode(combined));
    
    // Return a base36-like representation of a portion of the hash for the URL
    // (similar to the previous implementation but salted and hashed)
    final hashStr = digest.toString();
    var hashVal = 0;
    for (var i = 0; i < hashStr.length; i++) {
      hashVal = ((hashVal << 5) - hashVal + hashStr.codeUnitAt(i)) & 0xFFFFFFFF;
    }
    return hashVal.toRadixString(36).padLeft(12, '0');
  }
}
