import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'spheres_crypto.dart';

/// Raised when a vault cannot be opened.
class VaultException implements Exception {
  final String message;
  const VaultException(this.message);
  @override
  String toString() => 'VaultException: $message';
}

/// Passphrase-encrypted container for identity and backup data.
///
/// This replaces `spheres_create_vault`, a Rust stub that returned the literal
/// string `placeholder_vault_blob` regardless of input — so "encrypted"
/// backups contained no key material and restoring one silently produced an
/// empty identity. That is why backup and identity export were disabled in
/// Phase 0; this is what re-enables them.
///
/// A passphrase is low-entropy, so the work factor is the whole defence:
/// Argon2id at OWASP's recommended mobile parameters, with the parameters
/// stored in the vault so they can be raised later without breaking old files.
class Vault {
  static const int version = 1;

  // OWASP baseline for Argon2id: 19 MiB, 2 iterations, 1 lane.
  static const int _memoryKib = 19456;
  static const int _iterations = 2;
  static const int _parallelism = 1;

  static const int _saltLength = 16;

  const Vault._();

  static Future<Uint8List> _deriveKey({
    required String passphrase,
    required List<int> salt,
    required int memoryKib,
    required int iterations,
    required int parallelism,
  }) async {
    final argon2 = Argon2id(
      memory: memoryKib,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: SpheresCrypto.keyLength,
    );
    final key = await argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Encrypt [plaintext] under [passphrase].
  static Future<String> seal({
    required String plaintext,
    required String passphrase,
  }) async {
    if (passphrase.isEmpty) {
      throw const VaultException('A passphrase is required');
    }

    final salt = SpheresCrypto.randomBytes(_saltLength);
    final nonce = SpheresCrypto.randomNonce();
    final key = await _deriveKey(
      passphrase: passphrase,
      salt: salt,
      memoryKib: _memoryKib,
      iterations: _iterations,
      parallelism: _parallelism,
    );

    // The header is bound as associated data, so the stored KDF parameters
    // cannot be edited down to make a brute-force cheaper without the vault
    // failing to open.
    final header = {
      'v': version,
      'kdf': 'argon2id',
      'm': _memoryKib,
      't': _iterations,
      'p': _parallelism,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
    };

    final ciphertext = await SpheresCrypto.encrypt(
      key: key,
      nonce: nonce,
      plaintext: utf8.encode(plaintext),
      aad: utf8.encode(jsonEncode(header)),
    );

    return jsonEncode({...header, 'ct': base64Encode(ciphertext)});
  }

  /// Decrypt a vault. Throws [VaultException] on a wrong passphrase or on any
  /// tampering — never returns partial or unauthenticated data.
  static Future<String> open({
    required String vault,
    required String passphrase,
  }) async {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(vault) as Map<String, dynamic>;
    } catch (_) {
      throw const VaultException('Not a Spheres vault');
    }

    if (json['v'] != version) {
      throw VaultException('Unsupported vault version ${json['v']}');
    }
    if (json['kdf'] != 'argon2id') {
      throw VaultException('Unsupported key derivation "${json['kdf']}"');
    }

    final memoryKib = json['m'];
    final iterations = json['t'];
    final parallelism = json['p'];
    if (memoryKib is! int || iterations is! int || parallelism is! int) {
      throw const VaultException('Vault header is malformed');
    }
    // Refuse absurd work factors rather than trying to honour them: a hostile
    // file should not be able to make opening it exhaust memory.
    if (memoryKib > 1024 * 1024 || iterations > 16 || parallelism > 16) {
      throw const VaultException('Vault demands implausible work factors');
    }

    final Uint8List salt;
    final Uint8List nonce;
    final Uint8List ciphertext;
    try {
      salt = Uint8List.fromList(base64Decode(json['salt'] as String));
      nonce = Uint8List.fromList(base64Decode(json['nonce'] as String));
      ciphertext = Uint8List.fromList(base64Decode(json['ct'] as String));
    } catch (_) {
      throw const VaultException('Vault body is malformed');
    }

    final key = await _deriveKey(
      passphrase: passphrase,
      salt: salt,
      memoryKib: memoryKib,
      iterations: iterations,
      parallelism: parallelism,
    );

    final header = Map<String, dynamic>.from(json)..remove('ct');

    try {
      final plaintext = await SpheresCrypto.decrypt(
        key: key,
        nonce: nonce,
        ciphertextWithMac: ciphertext,
        aad: utf8.encode(jsonEncode(header)),
      );
      return utf8.decode(plaintext);
    } catch (_) {
      // Indistinguishable by design: a wrong passphrase and a corrupted file
      // both fail the same authentication check.
      throw const VaultException(
        'Could not open the vault — wrong passphrase, or the file is damaged',
      );
    }
  }

  /// Whether [value] looks like a vault, so callers can tell an encrypted
  /// backup from a plaintext one without trying a passphrase.
  static bool looksLikeVault(String value) {
    try {
      final json = jsonDecode(value);
      return json is Map && json['kdf'] == 'argon2id' && json['ct'] is String;
    } catch (_) {
      return false;
    }
  }
}
