import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'spheres_crypto.dart';

/// Holds the symmetric keys for every sphere we belong to, one per epoch.
///
/// Old epochs are retained deliberately: content published under epoch 3 stays
/// readable after the sphere moves to epoch 4, so a membership change does not
/// erase history for the people who were already there.
///
/// The security property that matters runs the other way. Removing someone
/// bumps the epoch and generates a fresh random key that is never wrapped for
/// them, so everything published afterwards is closed to them. This is a real
/// cryptographic removal rather than a local `blocked` boolean, which is what
/// group membership amounted to before.
class SphereKeyring {
  static const _prefsKey = 'spheres_keyring_v1';

  /// sphereId -> epoch -> key
  final Map<String, Map<int, Uint8List>> _keys = {};

  /// Record a key we generated or were given.
  void store(String sphereId, int epoch, Uint8List key) {
    if (key.length != SpheresCrypto.keyLength) {
      throw ArgumentError('Sphere key must be ${SpheresCrypto.keyLength} bytes');
    }
    _keys.putIfAbsent(sphereId, () => {})[epoch] = key;
  }

  Uint8List? keyFor(String sphereId, int epoch) => _keys[sphereId]?[epoch];

  /// The newest epoch we hold a key for, or null if we hold none.
  ///
  /// Not necessarily the sphere's current epoch: if we were removed, the
  /// sphere has moved on and we simply never received the new key.
  int? latestEpoch(String sphereId) {
    final epochs = _keys[sphereId]?.keys;
    if (epochs == null || epochs.isEmpty) return null;
    return epochs.reduce((a, b) => a > b ? a : b);
  }

  bool hasKey(String sphereId, int epoch) => keyFor(sphereId, epoch) != null;

  /// Mint a fresh key for an epoch. Used on creation and on every rotation.
  Uint8List rotate(String sphereId, int epoch) {
    final key = SpheresCrypto.randomKey();
    store(sphereId, epoch, key);
    return key;
  }

  /// Forget a sphere entirely, e.g. after leaving it.
  void forget(String sphereId) => _keys.remove(sphereId);

  Set<String> get sphereIds => _keys.keys.toSet();

  // ── Persistence ───────────────────────────────────────────────────────────
  //
  // Plaintext in SharedPreferences for now, like the rest of local state. That
  // means these keys are exposed to anyone who can read the app sandbox; moving
  // to SQLCipher is Phase 2's remaining storage item.

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _keys.map((sphereId, epochs) => MapEntry(
          sphereId,
          epochs.map((epoch, key) => MapEntry('$epoch', base64Encode(key))),
        ));
    await prefs.setString(_prefsKey, jsonEncode(encoded));
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;

    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      decoded.forEach((sphereId, epochs) {
        if (epochs is! Map) return;
        epochs.forEach((epoch, key) {
          final parsedEpoch = int.tryParse('$epoch');
          if (parsedEpoch == null || key is! String) return;
          try {
            store(sphereId, parsedEpoch, Uint8List.fromList(base64Decode(key)));
          } catch (_) {
            // Skip an unreadable key rather than dropping the whole keyring.
          }
        });
      });
    } catch (_) {
      // Never wipe on a parse failure; losing keys loses access to content.
    }
  }
}
