import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

import 'debug_log_service.dart';

/// Biometric or device-credential checks, for the app lock and locked chats.
///
/// Thin on purpose: the platform owns the prompt and the policy. What this adds
/// is a replaceable seam so screens can be tested without a fingerprint
/// reader, and one honest answer when the device has nothing to check with.
class AppLockService extends ChangeNotifier {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Replaceable for tests: returns whether the user passed.
  Future<bool> Function(String reason)? authenticator;

  /// Whether the app is currently locked and waiting for the user.
  bool _locked = false;
  bool get locked => _locked;

  Future<bool> get isAvailable async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// Ask the device to confirm it is the owner. False on failure or cancel.
  Future<bool> authenticate(String reason) async {
    final override = authenticator;
    if (override != null) return override(reason);
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      DebugLogService().warn('Lock', 'Authentication unavailable: $e');
      return false;
    }
  }

  /// The app went to the background with the lock on: require unlocking next.
  void lock() {
    if (_locked) return;
    _locked = true;
    notifyListeners();
  }

  Future<bool> unlock() async {
    final ok = await authenticate('Unlock Spheres');
    if (ok) {
      _locked = false;
      notifyListeners();
    }
    return ok;
  }
}
