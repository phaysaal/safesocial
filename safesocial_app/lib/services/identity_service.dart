import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:convert/convert.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:cryptography/cryptography.dart';

import '../crypto/spheres_crypto.dart';
import '../models/user_profile.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';

class IdentityKeyPair {
  final String publicKey;
  final String secretKey;

  IdentityKeyPair({required this.publicKey, required this.secretKey});
}

/// Manages the user's cryptographic identity and profile.
///
/// An identity is two key pairs with separate jobs:
///
/// * **Ed25519** — signs everything. This is the public key others know you by,
///   the one in your QR code, and the one that has to stay stable.
/// * **X25519** — key agreement only, for deriving pairwise secrets.
///
/// They are separate rather than one converted into the other: the Ed25519 →
/// X25519 birational map is easy to get subtly wrong (the previous Rust
/// implementation returned 32 zero bytes), and publishing a distinct key costs
/// nothing since profiles are signed anyway.
class IdentityService extends ChangeNotifier {
  static const _prefsProfileKey = 'spheres_identity_profile';
  static const _prefsPubKeyKey = 'spheres_identity_pubkey';
  static const _secureSecretKey = 'spheres_identity_secret';
  static const _secureExchangeSecretKey = 'spheres_identity_x25519_secret';

  final _secureStorage = const FlutterSecureStorage();

  UserProfile? _currentIdentity;
  IdentityKeyPair? _keypair;
  SimpleKeyPair? _exchangeKeyPair;
  String? _exchangePublicKeyHex;

  IdentityService();

  UserProfile? get currentIdentity => _currentIdentity;
  String? get publicKey => _keypair?.publicKey;
  String? get secretKey => _keypair?.secretKey;
  bool get isOnboarded => _currentIdentity != null && _keypair != null;

  /// Our X25519 key pair, used to derive pairwise secrets with contacts.
  SimpleKeyPair? get exchangeKeyPair => _exchangeKeyPair;

  /// Our X25519 public key as hex, as published in the profile.
  String? get exchangePublicKey => _exchangePublicKeyHex;

  /// Create the X25519 key pair if this identity does not have one yet.
  ///
  /// Identities created before Phase 1 have only an Ed25519 key, so this runs
  /// on load as a migration. The Ed25519 key is never regenerated — that would
  /// change the user's identity and break every existing contact.
  Future<void> _ensureExchangeKeyPair() async {
    if (_exchangeKeyPair != null) return;

    final stored = await _secureStorage.read(key: _secureExchangeSecretKey);
    if (stored != null) {
      try {
        _exchangeKeyPair = await SpheresCrypto.keyExchangeKeyPairFromPrivateBytes(
          hex.decode(stored),
        );
        _exchangePublicKeyHex =
            hex.encode((await _exchangeKeyPair!.extractPublicKey()).bytes);
        return;
      } catch (e) {
        DebugLogService()
            .error('Identity', 'Stored exchange key unreadable, regenerating: $e');
      }
    }

    final pair = await SpheresCrypto.newKeyExchangeKeyPair();
    final privateBytes = await pair.extractPrivateKeyBytes();
    await _secureStorage.write(
      key: _secureExchangeSecretKey,
      value: hex.encode(privateBytes),
    );

    _exchangeKeyPair = pair;
    _exchangePublicKeyHex = hex.encode((await pair.extractPublicKey()).bytes);
    DebugLogService().info('Identity', 'Key exchange keypair ready');

    // Publish it so contacts can start encrypting to us.
    if (_currentIdentity != null &&
        _currentIdentity!.keyExchangePublicKey != _exchangePublicKeyHex) {
      _currentIdentity = _currentIdentity!.copyWith(
        keyExchangePublicKey: _exchangePublicKeyHex,
        updatedAt: DateTime.now(),
      );
      await _persistIdentity();
    }
  }

  /// Generate a new identity keypair and profile.
  Future<void> createIdentity(String displayName, {String? bio}) async {
    try {
      final keyPair = ed.generateKey();
      final pubKeyHex = hex.encode(keyPair.publicKey.bytes);
      final privKeyHex = hex.encode(keyPair.privateKey.bytes);

      _keypair = IdentityKeyPair(
        publicKey: pubKeyHex,
        secretKey: privKeyHex,
      );

      // Must exist before the profile is built, so the profile carries it.
      _exchangeKeyPair = null;
      await _ensureExchangeKeyPair();

      _currentIdentity = UserProfile(
        publicKey: pubKeyHex,
        keyExchangePublicKey: _exchangePublicKeyHex,
        displayName: displayName,
        bio: bio ?? '',
        updatedAt: DateTime.now(),
      );

      await _persistIdentity();
      notifyListeners();
    } catch (e) {
      DebugLogService().error('Identity', 'Failed to create identity: $e');
      rethrow;
    }
  }

  /// Update the user's profile information.
  Future<void> updateProfile({String? displayName, String? bio}) async {
    if (_currentIdentity == null) return;
    _currentIdentity = _currentIdentity!.copyWith(
      displayName: displayName ?? _currentIdentity!.displayName,
      bio: bio ?? _currentIdentity!.bio,
      updatedAt: DateTime.now(),
    );
    await _persistIdentity();
    notifyListeners();
  }

  /// Update the user's avatar.
  Future<void> updateAvatar(String mediaRef) async {
    if (_currentIdentity == null) return;
    _currentIdentity = _currentIdentity!.copyWith(
      avatarRef: mediaRef,
      updatedAt: DateTime.now(),
    );
    await _persistIdentity();
    notifyListeners();
  }

  /// Export the current identity keypair as a passphrase-encrypted vault.
  ///
  /// Unavailable: the vault primitives it depended on
  /// (`spheres_create_vault` / `spheres_unlock_vault`) are placeholders that
  /// return a fixed string regardless of input, so an "encrypted" export
  /// contained no key material. Exporting the key unencrypted instead is not
  /// an acceptable substitute here — it would put the secret key on the system
  /// clipboard, readable by other apps. Use [BackupService] until real vault
  /// encryption lands.
  Future<String> exportIdentity(String passphrase) async {
    throw UnsupportedError(
      'Encrypted identity export is not available in this build.',
    );
  }

  /// Import an identity from an unencrypted export blob.
  ///
  /// Passphrase-protected blobs cannot be opened — see [exportIdentity].
  Future<bool> importIdentity(String blob, {String? passphrase}) async {
    if (passphrase != null && passphrase.isNotEmpty) {
      throw UnsupportedError(
        'Passphrase-protected identity import is not available in this build.',
      );
    }
    try {
      final data = jsonDecode(blob);
      if (data is! Map ||
          data['key'] is! String ||
          data['secret'] is! String ||
          (data['key'] as String).isEmpty ||
          (data['secret'] as String).isEmpty) {
        debugPrint('[IdentityService] Import rejected: no valid keypair in blob');
        return false;
      }

      _keypair = IdentityKeyPair(
        publicKey: data['key'] as String,
        secretKey: data['secret'] as String,
      );

      if (data['profile'] != null) {
        _currentIdentity = UserProfile.fromJson(data['profile']);
      }

      // A restored identity may predate key exchange, or its X25519 secret may
      // not have travelled with it. Either way, establish one now.
      _exchangeKeyPair = null;
      _exchangePublicKeyHex = null;
      await _ensureExchangeKeyPair();

      await _persistIdentity();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[IdentityService] Import failed: $e');
      return false;
    }
  }

  /// Load identity from local storage (hybrid Secure + SharedPrefs).
  Future<void> loadIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final profileJson = prefs.getString(_prefsProfileKey);
      if (profileJson != null) {
        _currentIdentity = UserProfile.fromJson(jsonDecode(profileJson));
      }
      
      final pubKey = prefs.getString(_prefsPubKeyKey);
      final secretKey = await _secureStorage.read(key: _secureSecretKey);

      if (pubKey != null && secretKey != null) {
        _keypair = IdentityKeyPair(publicKey: pubKey, secretKey: secretKey);
        await _ensureExchangeKeyPair();
        DebugLogService().success('Identity', 'Secure identity restored');
      } else {
        // Migration from old SharedPreferences keypair if exists
        final legacyJson = prefs.getString('spheres_identity_keypair');
        if (legacyJson != null) {
          final data = jsonDecode(legacyJson);
          _keypair = IdentityKeyPair(publicKey: data['key'], secretKey: data['secret']);
          await _ensureExchangeKeyPair();
          await _persistIdentity(); // This will move it to secure storage
          await prefs.remove('spheres_identity_keypair');
          DebugLogService().info('Identity', 'Migrated identity to secure storage');
        }
      }
      
      notifyListeners();
    } catch (e) {
      debugPrint('[IdentityService] Load failed: $e');
    }
  }

  /// PERSISTENT MEMORY: Reset everything.
  Future<void> resetEverything() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await _secureStorage.deleteAll();
    
    _currentIdentity = null;
    _keypair = null;
    _exchangeKeyPair = null;
    _exchangePublicKeyHex = null;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      if (appDir.existsSync()) {
        final items = appDir.listSync();
        for (var item in items) {
          try { await item.delete(recursive: true); } catch (_) {}
        }
      }

      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        final items = tempDir.listSync();
        for (var item in items) {
          try { await item.delete(recursive: true); } catch (_) {}
        }
      }
      DebugLogService().warn('Identity', 'HARD WIPE COMPLETE.');
    } catch (e) {
      DebugLogService().error('Identity', 'FileSystem wipe errors: $e');
    }
    
    notifyListeners();
  }

  Future<void> publishProfileToRelay(RelayService relay) async {
    if (_keypair == null || _currentIdentity == null) return;
    
    // Sign the profile to prove ownership (Issue #2 Fix)
    final profileJson = jsonEncode(_currentIdentity!.toJson());
    final privKey = ed.PrivateKey(hex.decode(_keypair!.secretKey));
    final signature = ed.sign(privKey, utf8.encode(profileJson));
    
    final payload = jsonEncode({
      'profile': _currentIdentity!.toJson(),
      'signature': hex.encode(signature),
    });

    final success = await relay.pushState(publicKey!, secretKey!, 'profile', payload);
    
    if (success) {
      DebugLogService().success('Identity', 'Signed profile published to Relay');
    } else {
      DebugLogService().error('Identity', 'Failed to publish signed profile');
    }
  }

  Future<void> _persistIdentity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_keypair != null) {
        await prefs.setString(_prefsPubKeyKey, _keypair!.publicKey);
        await _secureStorage.write(key: _secureSecretKey, value: _keypair!.secretKey);
      }
      if (_currentIdentity != null) {
        await prefs.setString(_prefsProfileKey, jsonEncode(_currentIdentity!.toJson()));
      }
    } catch (e) {
      debugPrint('[IdentityService] Persist failed: $e');
    }
  }
}
