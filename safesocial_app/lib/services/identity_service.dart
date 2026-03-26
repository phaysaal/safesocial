// Real implementation uses package:veilid/veilid.dart for:
// - Ed25519 keypair generation via Veilid's crypto system
// - DHT record creation for profile sharing (3 subkeys: info, avatar, status)
// - ProtectedStore / TableStore for secure local persistence
// Stubbed out until Android NDK + Rust toolchain issues are resolved.
// See pubspec.yaml for the veilid dependency (currently commented out).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/user_profile.dart';
import 'veilid_service.dart';

/// Manages the user's cryptographic identity and profile.
///
/// Stub implementation that generates UUID-based mock keypairs and
/// persists to SharedPreferences instead of Veilid's TableStore.
class IdentityService extends ChangeNotifier {
  static const _prefsProfileKey = 'safesocial_identity_profile';
  static const _prefsKeypairKey = 'safesocial_identity_keypair';
  static const _prefsDhtKeyKey = 'safesocial_identity_dht_key';

  final VeilidService veilidService;

  UserProfile? _currentIdentity;

  // In the real implementation these are veilid KeyPair and RecordKey types.
  Map<String, String>? _keypair; // {'public': ..., 'secret': ...}
  String? _profileDhtKey;

  IdentityService({required this.veilidService});

  UserProfile? get currentIdentity => _currentIdentity;
  String? get publicKey => _keypair?['public'];
  bool get isOnboarded => _currentIdentity != null;

  /// Create a new identity with the given display name and bio.
  ///
  /// Stub: generates UUID-based mock keys instead of Ed25519 via Veilid.
  Future<void> createIdentity(String displayName, String bio) async {
    // Real implementation:
    // final crypto = await Veilid.instance.getCryptoSystem(bestCryptoKind);
    // _keypair = await crypto.generateKeyPair();
    // final schema = DHTSchema.dflt(oCnt: 3);
    // final record = await rc.createDHTRecord(bestCryptoKind, schema);
    // ... write profile to DHT subkey 0 ...

    final mockPublic = const Uuid().v4().replaceAll('-', '');
    final mockSecret = const Uuid().v4().replaceAll('-', '');
    _keypair = {'public': mockPublic, 'secret': mockSecret};
    _profileDhtKey = const Uuid().v4();

    debugPrint('[IdentityService] Generated mock keypair: $mockPublic');

    _currentIdentity = UserProfile(
      publicKey: mockPublic,
      displayName: displayName,
      bio: bio,
      updatedAt: DateTime.now(),
    );

    await _persistIdentity();
    notifyListeners();
  }

  /// Load identity from SharedPreferences.
  Future<void> loadIdentity() async {
    // Real implementation loads from Veilid's TableStore:
    // final db = await Veilid.instance.openTableDB(_tableDbName, 1);
    // _keypair = KeyPair.fromJson(await db.loadStringJson(0, _keypairKey));
    // _profileDhtKey = RecordKey.fromJson(await db.loadStringJson(0, _profileDhtKeyKey));
    // _currentIdentity = UserProfile.fromJson(await db.loadStringJson(0, _profileKey));

    try {
      final prefs = await SharedPreferences.getInstance();

      final keypairJson = prefs.getString(_prefsKeypairKey);
      if (keypairJson != null) {
        final kpMap = jsonDecode(keypairJson) as Map<String, dynamic>;
        _keypair = {
          'public': kpMap['public'] as String,
          'secret': kpMap['secret'] as String,
        };
      }

      _profileDhtKey = prefs.getString(_prefsDhtKeyKey);

      final profileJson = prefs.getString(_prefsProfileKey);
      if (profileJson != null) {
        final profileMap = jsonDecode(profileJson) as Map<String, dynamic>;
        _currentIdentity = UserProfile.fromJson(profileMap);
      }
    } catch (e) {
      debugPrint('[IdentityService] Failed to load identity: $e');
    }
    notifyListeners();
  }

  /// Update the display name and bio of the current profile.
  Future<void> updateProfile(String displayName, String bio) async {
    if (_currentIdentity == null) return;

    _currentIdentity = _currentIdentity!.copyWith(
      displayName: displayName,
      bio: bio,
      updatedAt: DateTime.now(),
    );

    // Real implementation also writes to DHT:
    // await rc.openDHTRecord(_profileDhtKey!, writer: _keypair!);
    // await rc.setDHTValue(_profileDhtKey!, 0, ...);
    // await rc.closeDHTRecord(_profileDhtKey!);

    await _persistIdentity();
    notifyListeners();
  }

  /// Update the avatar to a local file path.
  Future<void> updateAvatar(String filePath) async {
    if (_currentIdentity == null) return;

    _currentIdentity = _currentIdentity!.copyWith(
      avatarRef: filePath,
      updatedAt: DateTime.now(),
    );

    await _persistIdentity();
    notifyListeners();
  }

  /// Import an existing identity from a keypair JSON string.
  /// Used for multi-device restore or migration from backup.
  Future<bool> importIdentity(String keypairJson, {String? displayName, String? bio}) async {
    try {
      final data = jsonDecode(keypairJson);

      // Support both formats: raw keypair or full backup
      Map<String, String> kp;
      if (data is Map<String, dynamic>) {
        kp = {
          'public': data['public'] as String,
          'secret': data['secret'] as String,
        };
      } else {
        return false;
      }

      _keypair = kp;
      _profileDhtKey = const Uuid().v4();

      _currentIdentity = UserProfile(
        publicKey: kp['public']!,
        displayName: displayName ?? 'Restored User',
        bio: bio ?? '',
        updatedAt: DateTime.now(),
      );

      await _persistIdentity();
      notifyListeners();
      debugPrint('[IdentityService] Identity imported: ${kp['public']}');
      return true;
    } catch (e) {
      debugPrint('[IdentityService] Import failed: $e');
      return false;
    }
  }

  /// Export the keypair as a shareable string for backup.
  Future<String> exportIdentity() async {
    if (_keypair == null) return '';
    return jsonEncode(_keypair);
  }

  /// Generate a contact exchange payload containing public key + profile DHT key.
  String generateExchangePayload() {
    if (_keypair == null || _profileDhtKey == null) return '';
    final payload = {
      'public_key': _keypair!['public'],
      'profile_dht_key': _profileDhtKey,
    };
    return base64Encode(utf8.encode(jsonEncode(payload)));
  }

  /// Persist identity data to SharedPreferences.
  Future<void> _persistIdentity() async {
    // Real implementation persists to Veilid's TableStore:
    // final db = await Veilid.instance.openTableDB(_tableDbName, 1);
    // await db.storeStringJson(0, _keypairKey, _keypair!.toJson());
    // ...

    try {
      final prefs = await SharedPreferences.getInstance();

      if (_keypair != null) {
        await prefs.setString(_prefsKeypairKey, jsonEncode(_keypair));
      }
      if (_profileDhtKey != null) {
        await prefs.setString(_prefsDhtKeyKey, _profileDhtKey!);
      }
      if (_currentIdentity != null) {
        await prefs.setString(
          _prefsProfileKey,
          jsonEncode(_currentIdentity!.toJson()),
        );
      }
    } catch (e) {
      debugPrint('[IdentityService] Failed to persist identity: $e');
    }
  }
}
