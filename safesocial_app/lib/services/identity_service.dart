import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:convert/convert.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/user_profile.dart';
import 'debug_log_service.dart';
import 'relay_service.dart';
import 'rust_core_service.dart';

class IdentityKeyPair {
  final String publicKey;
  final String secretKey;

  IdentityKeyPair({required this.publicKey, required this.secretKey});
}

/// Manages the user's cryptographic identity and profile.
class IdentityService extends ChangeNotifier {
  static const _prefsProfileKey = 'spheres_identity_profile';
  static const _prefsPubKeyKey = 'spheres_identity_pubkey';
  static const _secureSecretKey = 'spheres_identity_secret';

  final RustCoreService _rustCore = RustCoreService();
  final _secureStorage = const FlutterSecureStorage();
  
  UserProfile? _currentIdentity;
  IdentityKeyPair? _keypair;

  IdentityService();

  UserProfile? get currentIdentity => _currentIdentity;
  String? get publicKey => _keypair?.publicKey;
  String? get secretKey => _keypair?.secretKey;
  bool get isOnboarded => _currentIdentity != null && _keypair != null;

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
      
      _currentIdentity = UserProfile(
        publicKey: pubKeyHex,
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

  /// Export the current identity keypair as a secure encrypted vault.
  Future<String> exportIdentity(String passphrase) async {
    if (_keypair == null) throw Exception('No identity to export');
    
    final payload = jsonEncode({
      'key': _keypair!.publicKey,
      'secret': _keypair!.secretKey,
      'profile': _currentIdentity?.toJson(),
    });

    final vault = _rustCore.createVault(payload, passphrase);
    if (vault == null) throw Exception('Failed to encrypt identity vault');
    
    return vault;
  }

  /// Import an identity from a secure vault.
  Future<bool> importIdentity(String blob, {String? passphrase}) async {
    try {
      String decrypted;
      if (passphrase != null && passphrase.isNotEmpty) {
        final result = _rustCore.unlockVault(blob, passphrase);
        if (result == null) return false;
        decrypted = result;
      } else {
        decrypted = blob;
      }

      final data = jsonDecode(decrypted);
      _keypair = IdentityKeyPair(
        publicKey: data['key'],
        secretKey: data['secret'],
      );

      if (data['profile'] != null) {
        _currentIdentity = UserProfile.fromJson(data['profile']);
      }

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
        DebugLogService().success('Identity', 'Secure identity restored');
      } else {
        // Migration from old SharedPreferences keypair if exists
        final legacyJson = prefs.getString('spheres_identity_keypair');
        if (legacyJson != null) {
          final data = jsonDecode(legacyJson);
          _keypair = IdentityKeyPair(publicKey: data['key'], secretKey: data['secret']);
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
