import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veilid/veilid.dart';

import '../models/user_profile.dart';
import 'veilid_service.dart';

/// Manages the user's cryptographic identity and profile.
///
/// Uses Veilid's crypto system for real Ed25519 keypair generation.
/// Falls back to SharedPreferences when TableStore is unavailable.
class IdentityService extends ChangeNotifier {
  static const _prefsProfileKey = 'spheres_identity_profile';
  static const _prefsKeypairKey = 'spheres_identity_keypair';
  static const _prefsDhtKeyKey = 'spheres_identity_dht_key';

  final VeilidService veilidService;

  UserProfile? _currentIdentity;
  KeyPair? _keypair;
  RecordKey? _profileDhtKey;

  IdentityService({required this.veilidService});

  UserProfile? get currentIdentity => _currentIdentity;
  String? get publicKey => _keypair?.key.toString();
  KeyPair? get keypair => _keypair;
  RecordKey? get profileDhtKey => _profileDhtKey;
  bool get isOnboarded => _currentIdentity != null;

  /// Create a new identity with real Ed25519 keypair via Veilid crypto.
  Future<void> createIdentity(String displayName, String bio) async {
    final rc = veilidService.routingContext;

    if (rc != null) {
      try {
        final crypto = await Veilid.instance.getCryptoSystem(bestCryptoKind);
        _keypair = await crypto.generateKeyPair();

        final schema = DHTSchema.dflt(oCnt: 3);
        final record = await rc.createDHTRecord(bestCryptoKind, schema);
        _profileDhtKey = record.key;

        final profileData = {
          'display_name': displayName,
          'bio': bio,
          'avatar_ref': null,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        };
        await rc.setDHTValue(
          record.key, 0,
          Uint8List.fromList(utf8.encode(jsonEncode(profileData))),
        );
        await rc.closeDHTRecord(record.key);
        debugPrint('[IdentityService] Real keypair: ${_keypair!.key}');
      } catch (e) {
        debugPrint('[IdentityService] Veilid crypto failed: $e');
        // Keypair stays null — profile will use publicKey from SharedPrefs
      }
    }

    final pubKey = _keypair?.key.toString() ?? 'offline-${DateTime.now().millisecondsSinceEpoch}';

    _currentIdentity = UserProfile(
      publicKey: pubKey,
      displayName: displayName,
      bio: bio,
      updatedAt: DateTime.now(),
    );

    await _persistIdentity();
    notifyListeners();
  }

  /// Load identity from TableStore or SharedPreferences.
  Future<void> loadIdentity() async {
    try {
      if (veilidService.isInitialized) {
        try {
          final db = await Veilid.instance.openTableDB('spheres_identity', 1);
          try {
            final kpJson = await db.loadStringJson(0, 'keypair');
            if (kpJson != null) _keypair = KeyPair.fromJson(kpJson);

            final dhtJson = await db.loadStringJson(0, 'profile_dht_key');
            if (dhtJson != null) _profileDhtKey = RecordKey.fromJson(dhtJson);

            final profJson = await db.loadStringJson(0, 'profile');
            if (profJson != null) {
              _currentIdentity = UserProfile.fromJson(profJson as Map<String, dynamic>);
            }
          } finally {
            db.close();
          }
          if (_currentIdentity != null) {
            notifyListeners();
            return;
          }
        } catch (e) {
          debugPrint('[IdentityService] TableStore load failed: $e');
        }
      }

      // Fallback: SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final keypairJson = prefs.getString(_prefsKeypairKey);
      if (keypairJson != null) {
        try {
          _keypair = KeyPair.fromJson(jsonDecode(keypairJson));
        } catch (_) {}
      }
      final dhtKeyStr = prefs.getString(_prefsDhtKeyKey);
      if (dhtKeyStr != null) {
        try { _profileDhtKey = RecordKey.fromString(dhtKeyStr); } catch (_) {}
      }
      final profileJson = prefs.getString(_prefsProfileKey);
      if (profileJson != null) {
        _currentIdentity = UserProfile.fromJson(
          jsonDecode(profileJson) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      debugPrint('[IdentityService] Failed to load identity: $e');
    }
    notifyListeners();
  }

  Future<void> updateProfile(String displayName, String bio) async {
    if (_currentIdentity == null) return;
    _currentIdentity = _currentIdentity!.copyWith(
      displayName: displayName, bio: bio, updatedAt: DateTime.now(),
    );

    final rc = veilidService.routingContext;
    if (rc != null && _profileDhtKey != null && _keypair != null) {
      try {
        await rc.openDHTRecord(_profileDhtKey!, writer: _keypair!);
        await rc.setDHTValue(_profileDhtKey!, 0,
          Uint8List.fromList(utf8.encode(jsonEncode({
            'display_name': displayName, 'bio': bio,
            'avatar_ref': _currentIdentity!.avatarRef,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          }))),
        );
        await rc.closeDHTRecord(_profileDhtKey!);
      } catch (e) {
        debugPrint('[IdentityService] DHT update failed: $e');
      }
    }
    await _persistIdentity();
    notifyListeners();
  }

  Future<void> updateAvatar(String filePath) async {
    if (_currentIdentity == null) return;
    _currentIdentity = _currentIdentity!.copyWith(
      avatarRef: filePath, updatedAt: DateTime.now(),
    );
    await _persistIdentity();
    notifyListeners();
  }

  Future<bool> importIdentity(String keypairJson, {String? displayName, String? bio}) async {
    try {
      _keypair = KeyPair.fromJson(jsonDecode(keypairJson));
      _currentIdentity = UserProfile(
        publicKey: _keypair!.key.toString(),
        displayName: displayName ?? 'Restored User',
        bio: bio ?? '',
        updatedAt: DateTime.now(),
      );
      await _persistIdentity();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[IdentityService] Import failed: $e');
      return false;
    }
  }

  Future<String> exportIdentity() async {
    if (_keypair == null) return '';
    return jsonEncode(_keypair!.toJson());
  }

  String generateExchangePayload() {
    if (_keypair == null) return '';
    final payload = {
      'public_key': _keypair!.key.toString(),
      'profile_dht_key': _profileDhtKey?.toString() ?? '',
    };
    return base64Encode(utf8.encode(jsonEncode(payload)));
  }

  Future<void> _persistIdentity() async {
    if (veilidService.isInitialized) {
      try {
        final db = await Veilid.instance.openTableDB('spheres_identity', 1);
        try {
          if (_keypair != null) await db.storeStringJson(0, 'keypair', _keypair!.toJson());
          if (_profileDhtKey != null) await db.storeStringJson(0, 'profile_dht_key', _profileDhtKey!.toJson());
          if (_currentIdentity != null) await db.storeStringJson(0, 'profile', _currentIdentity!.toJson());
        } finally { db.close(); }
      } catch (e) {
        debugPrint('[IdentityService] TableStore persist failed: $e');
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_keypair != null) await prefs.setString(_prefsKeypairKey, jsonEncode(_keypair!.toJson()));
      if (_profileDhtKey != null) await prefs.setString(_prefsDhtKeyKey, _profileDhtKey.toString());
      if (_currentIdentity != null) await prefs.setString(_prefsProfileKey, jsonEncode(_currentIdentity!.toJson()));
    } catch (e) {
      debugPrint('[IdentityService] SharedPreferences persist failed: $e');
    }
  }
}
